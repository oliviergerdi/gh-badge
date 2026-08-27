import Foundation

public struct ProcessOutput: Sendable {
    public let stdout: Data
    public let stderr: String
    public let exitCode: Int32

    public var stdoutText: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }
}

public enum ProcessRunnerError: LocalizedError {
    case launchFailed(String)
    case timedOut(seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "Could not launch process: \(message)"
        case .timedOut(let seconds):
            return "Command timed out after \(Int(seconds))s"
        }
    }
}

/// Thin async wrapper over `Process`.
///
/// Two details matter here and are easy to get wrong:
///
/// 1. **Pipe draining.** stdout and stderr are read on separate threads that are
///    started *before* waiting on the process. Reading them after
///    `waitUntilExit()` deadlocks as soon as output exceeds the ~64KB pipe
///    buffer, which a wide `gh search prs` result set can do.
///
/// 2. **Timeouts.** A hung network call must not wedge the poll loop. This is
///    not hypothetical for this app: corporate VPNs happily leave connections to
///    api.github.com half-open. Every call gets a hard deadline and a SIGTERM.
public enum ProcessRunner {
    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval = 20
    ) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            // Blocking implementation, moved off the caller's thread.
            DispatchQueue.global(qos: .utility).async {
                do {
                    let output = try runBlocking(
                        executable: executable,
                        arguments: arguments,
                        environment: environment,
                        timeout: timeout
                    )
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runBlocking(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()

        let readQueue = DispatchQueue.global(qos: .utility)
        readQueue.async(group: group) {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
        }
        readQueue.async(group: group) {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
        }

        do {
            try process.run()
        } catch {
            // Unblock the readers so their threads do not leak.
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        let didTimeOut = FlagBox()
        let pid = process.processIdentifier

        let terminator = DispatchWorkItem {
            if process.isRunning {
                didTimeOut.set()
                process.terminate()  // SIGTERM
            }
        }
        // SIGTERM is a request. A child that blocks or ignores it would leave
        // waitUntilExit() below blocking forever, so escalate.
        let killer = DispatchWorkItem {
            if process.isRunning {
                didTimeOut.set()
                kill(pid, SIGKILL)
            }
        }

        let queue = DispatchQueue.global(qos: .utility)
        queue.asyncAfter(deadline: .now() + timeout, execute: terminator)
        queue.asyncAfter(deadline: .now() + timeout + 3, execute: killer)

        process.waitUntilExit()
        terminator.cancel()
        killer.cancel()

        // Bounded, not open-ended. The direct child is gone, but a grandchild
        // (gh shells out to git and credential helpers) can inherit the pipe's
        // write end and outlive it — an unbounded wait here would hang the
        // continuation forever and defeat the timeout entirely. Partial output
        // beats a permanent hang.
        _ = group.wait(timeout: .now() + 2)

        // Only trust the flag if the process actually died by signal: it can be
        // set moments before the child exits cleanly on its own.
        if didTimeOut.value, process.terminationReason == .uncaughtSignal {
            throw ProcessRunnerError.timedOut(seconds: timeout)
        }

        let stderrText = String(data: errBox.value, encoding: .utf8) ?? ""
        return ProcessOutput(
            stdout: outBox.value,
            stderr: stderrText.trimmingCharacters(in: .whitespacesAndNewlines),
            exitCode: process.terminationStatus
        )
    }
}

// MARK: - Tiny thread-safe boxes

/// `Process` hands work to arbitrary queues, so the accumulators it feeds have
/// to be lock-guarded. Small enough not to justify a dependency or an actor
/// (which would force these synchronous read paths to become async).
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
