import Foundation
import OSLog

/// `Sendable` matters: these travel out of `TaskGroup` child tasks in `PRStore`,
/// and `Result` is only conditionally `Sendable`.
public enum GHError: LocalizedError, Equatable, Sendable {
    case notInstalled
    case notAuthenticated(detail: String)
    case commandFailed(detail: String)
    case timedOut
    case decodingFailed(detail: String)

    /// Short, actionable text for the dropdown banner.
    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "gh CLI not found. Install: brew install gh"
        case .notAuthenticated:
            return "gh not authenticated. Run: gh auth login"
        case .timedOut:
            return "GitHub request timed out. Check your VPN or network."
        case .commandFailed(let detail):
            return detail.isEmpty ? "gh command failed." : "gh: \(detail)"
        case .decodingFailed:
            return "Could not read gh output. See Console.app for details."
        }
    }

    /// True when retrying is pointless until the user does something.
    public var isFatalConfiguration: Bool {
        switch self {
        case .notInstalled, .notAuthenticated: return true
        case .commandFailed, .timedOut, .decodingFailed: return false
        }
    }
}

/// Pure query-building and response-parsing for the stale-review check,
/// deliberately separated from `GHClient` so it's testable without spawning a
/// process. "Stale" here means: the viewer reviewed this PR, and its head
/// commit has since moved past the commit that review was submitted against.
enum StaleReviewQuery {
    /// One aliased `repository` block per PR, so an arbitrary-length list of
    /// checks batches into a single GraphQL request instead of N round-trips.
    /// `viewerLatestReview` is a GraphQL convenience field scoped to the
    /// authenticated caller — no need to know or match the viewer's login.
    static func build(for prs: [PullRequest]) -> String {
        let blocks = prs.enumerated().compactMap { index, pr -> String? in
            let parts = pr.repo.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return """
            r\(index): repository(owner: "\(escape(parts[0]))", name: "\(escape(parts[1]))") {
              pullRequest(number: \(pr.number)) {
                headRefOid
                viewerLatestReview { commit { oid } }
              }
            }
            """
        }
        return "query {\n" + blocks.joined(separator: "\n") + "\n}"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// `prs` must be in the same order passed to `build(for:)`: the alias index
    /// (`r0`, `r1`, …) is positional, not carried in the response.
    ///
    /// Any node that's missing, malformed, or lacks a review from the viewer is
    /// treated as "not stale" — same "can't prove it, don't move it" rule used
    /// elsewhere: a parsing gap should never wrongly yank a PR out of the
    /// reviewed list.
    static func parse(_ responseData: Data, prs: [PullRequest]) -> Set<String> {
        guard
            let root = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let data = root["data"] as? [String: Any]
        else { return [] }

        var stale = Set<String>()
        for (index, pr) in prs.enumerated() {
            guard
                let repoNode = data["r\(index)"] as? [String: Any],
                let prNode = repoNode["pullRequest"] as? [String: Any],
                let headRefOid = prNode["headRefOid"] as? String,
                let review = prNode["viewerLatestReview"] as? [String: Any],
                let commit = review["commit"] as? [String: Any],
                let reviewedOid = commit["oid"] as? String
            else { continue }

            if reviewedOid != headRefOid {
                stale.insert(pr.url)
            }
        }
        return stale
    }

    /// Fallback parser for `gh pr view <n> --json headRefOid,reviews`: same
    /// "stale = reviewed commit differs from current head" rule, but the
    /// viewer's review has to be picked out by login (no `viewerLatestReview`
    /// convenience field on this shape) — the most recent one by `submittedAt`.
    static func parsePerPRView(_ data: Data, pr: PullRequest, viewerLogin: String) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let headRefOid = root["headRefOid"] as? String,
            let reviews = root["reviews"] as? [[String: Any]]
        else { return nil }

        let mine = reviews.filter { ($0["author"] as? [String: Any])?["login"] as? String == viewerLogin }
        guard let latest = mine.max(by: { submittedDate($0) < submittedDate($1) }) else { return nil }

        guard
            let commit = latest["commit"] as? [String: Any],
            let reviewedOid = commit["oid"] as? String
        else { return nil }

        return reviewedOid != headRefOid ? pr.url : nil
    }

    private static func submittedDate(_ review: [String: Any]) -> Date {
        (review["submittedAt"] as? String).flatMap(PullRequest.parseTimestamp) ?? .distantPast
    }
}

/// Everything that touches the `gh` binary. No GitHub API client, no token
/// handling, no Keychain access of our own — `gh` owns all of that.
public actor GHClient {
    private let log = Logger(subsystem: "com.gerdi.gh-badge", category: "GHClient")

    /// Where `gh` might live. `which gh` is useless from a GUI-launched app: it
    /// inherits a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) rather than the
    /// login shell's, so Homebrew's gh is invisible. Hence explicit candidates,
    /// with a login-shell query as the last resort.
    private static let candidatePaths = [
        "/opt/homebrew/bin/gh",   // Apple Silicon Homebrew
        "/usr/local/bin/gh",      // Intel Homebrew
        "/opt/local/bin/gh",      // MacPorts
        "/usr/bin/gh",
    ]

    private enum TokenPolicy: Equatable {
        /// Ignore GH_TOKEN / GITHUB_TOKEN from the environment and let `gh` use
        /// its stored (keychain) credential. This keeps behaviour identical
        /// whether the app is launched from Finder or from a terminal that
        /// happens to export a PAT.
        case useStoredCredential
        /// Fall back to inheriting env tokens, for setups with no stored login.
        case inheritEnvironmentToken
    }

    private var cachedPath: String?
    private var tokenPolicy: TokenPolicy = .useStoredCredential
    private var cachedLogin: String?

    private let requestTimeout: TimeInterval

    public init(requestTimeout: TimeInterval = 20) {
        self.requestTimeout = requestTimeout
    }

    // MARK: - Discovery

    public func ghPath() async throws -> String {
        if let cachedPath { return cachedPath }

        let fm = FileManager.default
        var candidates = Self.candidatePaths
        candidates.append(NSHomeDirectory() + "/.local/bin/gh")

        for path in candidates where fm.isExecutableFile(atPath: path) {
            log.debug("found gh at \(path, privacy: .public)")
            cachedPath = path
            return path
        }

        // Last resort: ask a login shell, which does source the user's profile.
        if let shellFound = await locateViaLoginShell(), fm.isExecutableFile(atPath: shellFound) {
            log.debug("found gh via login shell at \(shellFound, privacy: .public)")
            cachedPath = shellFound
            return shellFound
        }

        log.error("gh not found in any candidate location")
        throw GHError.notInstalled
    }

    private func locateViaLoginShell() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        do {
            // `-i` as well as `-l`: zsh sources .zshrc only for interactive
            // shells, and .zshrc is where most people actually set PATH.
            let result = try await ProcessRunner.run(
                executable: shell,
                arguments: ["-ilc", "command -v gh"],
                environment: ProcessInfo.processInfo.environment,
                timeout: 10
            )
            guard result.exitCode == 0 else { return nil }
            // Profiles are chatty (version managers, banners), so stdout is not
            // reliably one line. `command -v` output is last.
            let path = result.stdoutText
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }
            return (path?.isEmpty ?? true) ? nil : path
        } catch {
            return nil
        }
    }

    // MARK: - Environment

    private func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        // Ensure git (which gh shells out to) is reachable under a GUI PATH.
        let needed = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var pathParts = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in needed where !pathParts.contains(dir) {
            pathParts.append(dir)
        }
        env["PATH"] = pathParts.joined(separator: ":")

        if tokenPolicy == .useStoredCredential {
            env.removeValue(forKey: "GH_TOKEN")
            env.removeValue(forKey: "GITHUB_TOKEN")
            env.removeValue(forKey: "GH_ENTERPRISE_TOKEN")
            env.removeValue(forKey: "GITHUB_ENTERPRISE_TOKEN")
        }

        // Keep stdout strictly JSON and stderr free of chatter.
        env["GH_PAGER"] = "cat"
        env["PAGER"] = "cat"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        env["CLICOLOR"] = "0"

        return env
    }

    // MARK: - Preflight

    /// Locates `gh`, confirms it is authenticated, and caches the viewer's login.
    /// Call before the first poll and after any fatal configuration error.
    public func preflight() async throws {
        let path = try await ghPath()

        tokenPolicy = .useStoredCredential
        var lastDetail = ""

        if let detail = await authFailureDetail(path: path) {
            lastDetail = detail
            // Some setups only ever had a PAT in the environment. Try that
            // before declaring the user unauthenticated.
            tokenPolicy = .inheritEnvironmentToken
            if let secondDetail = await authFailureDetail(path: path) {
                tokenPolicy = .useStoredCredential
                log.error("gh auth failed both ways: \(lastDetail, privacy: .public) / \(secondDetail, privacy: .public)")
                throw GHError.notAuthenticated(detail: lastDetail)
            }
            log.info("gh auth succeeded using an environment token")
        }

        cachedLogin = await fetchLogin(path: path)
    }

    /// Returns nil when authenticated, otherwise a detail string.
    private func authFailureDetail(path: String) async -> String? {
        do {
            let result = try await ProcessRunner.run(
                executable: path,
                arguments: ["auth", "status"],
                environment: environment(),
                timeout: requestTimeout
            )
            return result.exitCode == 0 ? nil : (result.stderr.isEmpty ? "exit \(result.exitCode)" : result.stderr)
        } catch {
            return error.localizedDescription
        }
    }

    /// The authenticated user's login. Preferred over the `@me` shorthand for
    /// `--author`, whose support is not documented for `gh search prs`; the
    /// login is unambiguous everywhere.
    private func fetchLogin(path: String) async -> String? {
        do {
            let result = try await ProcessRunner.run(
                executable: path,
                arguments: ["api", "user", "--jq", ".login"],
                environment: environment(),
                timeout: requestTimeout
            )
            guard result.exitCode == 0 else { return nil }
            let login = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            return login.isEmpty ? nil : login
        } catch {
            return nil
        }
    }

    public func currentLogin() -> String? { cachedLogin }

    // MARK: - Queries

    /// Fields confirmed available from `gh search prs --help` (JSON FIELDS).
    private static let jsonFields = "repository,number,title,url,updatedAt,state,author"

    /// Runs `gh search prs <filters> --state=open --json <fields>`.
    ///
    /// `filters` are passed through verbatim, e.g. `["--review-requested=@me"]`.
    public func searchPRs(filters: [String], limit: Int = 60) async throws -> [PullRequest] {
        let path = try await ghPath()

        var arguments = ["search", "prs"]
        arguments.append(contentsOf: filters)
        arguments.append(contentsOf: [
            "--state=open",
            "--limit", String(limit),
            "--json", Self.jsonFields,
        ])

        log.debug("gh \(arguments.joined(separator: " "), privacy: .public)")

        let result: ProcessOutput
        do {
            result = try await ProcessRunner.run(
                executable: path,
                arguments: arguments,
                environment: environment(),
                timeout: requestTimeout
            )
        } catch let error as ProcessRunnerError {
            if case .timedOut = error { throw GHError.timedOut }
            throw GHError.commandFailed(detail: error.localizedDescription)
        }

        guard result.exitCode == 0 else {
            let detail = Self.condense(result.stderr)
            if Self.looksUnauthenticated(result.stderr) {
                throw GHError.notAuthenticated(detail: detail)
            }
            log.error("gh exited \(result.exitCode): \(result.stderr, privacy: .public)")
            throw GHError.commandFailed(detail: detail)
        }

        return try decode(result.stdout)
    }

    private func decode(_ data: Data) throws -> [PullRequest] {
        // `gh ... --json` prints a top-level array; empty results print `[]`.
        guard !data.isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([PullRequest].self, from: data)
        } catch {
            // Verbose by design: the raw payload must be recoverable from
            // Console.app if decoding ever fails (e.g. `gh` changes a shape).
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            log.error("decode failed: \(String(describing: error), privacy: .public)\nraw: \(raw, privacy: .public)")
            throw GHError.decodingFailed(detail: String(describing: error))
        }
    }

    // MARK: - Stale reviews (new commits since the viewer's last review)

    /// For each PR in `candidates`, checks whether its head commit has moved
    /// past the viewer's last review on it. Tries one batched GraphQL request
    /// first; if that fails outright (transport error, bad exit, unreadable
    /// response), falls back to one `gh pr view` per PR.
    ///
    /// Never throws: this is a display enhancement, not core functionality, so
    /// a total failure here should silently skip the enhancement rather than
    /// surface an error banner or block a refresh.
    public func staleReviewURLs(for candidates: [PullRequest]) async -> Set<String> {
        guard !candidates.isEmpty else { return [] }
        if let viaGraphQL = await staleReviewURLsViaGraphQL(candidates) {
            return viaGraphQL
        }
        log.info("stale-review GraphQL batch failed; falling back to per-PR gh pr view")
        return await staleReviewURLsPerPR(candidates)
    }

    /// nil means the batched call failed outright; the caller falls back to
    /// per-PR calls rather than treating that as "nothing is stale".
    private func staleReviewURLsViaGraphQL(_ candidates: [PullRequest]) async -> Set<String>? {
        guard let path = try? await ghPath() else { return nil }
        let query = StaleReviewQuery.build(for: candidates)
        do {
            let result = try await ProcessRunner.run(
                executable: path,
                arguments: ["api", "graphql", "-f", "query=\(query)"],
                environment: environment(),
                timeout: requestTimeout
            )
            guard result.exitCode == 0, !result.stdout.isEmpty else { return nil }
            return StaleReviewQuery.parse(result.stdout, prs: candidates)
        } catch {
            return nil
        }
    }

    private func staleReviewURLsPerPR(_ candidates: [PullRequest]) async -> Set<String> {
        guard let path = try? await ghPath(), let login = cachedLogin else { return [] }
        let env = environment()
        let timeout = requestTimeout

        return await withTaskGroup(of: String?.self) { group in
            for pr in candidates {
                group.addTask {
                    await Self.staleReviewURLPerPR(path: path, pr: pr, login: login, environment: env, timeout: timeout)
                }
            }
            var stale = Set<String>()
            for await url in group {
                if let url { stale.insert(url) }
            }
            return stale
        }
    }

    private static func staleReviewURLPerPR(
        path: String,
        pr: PullRequest,
        login: String,
        environment: [String: String],
        timeout: TimeInterval
    ) async -> String? {
        do {
            let result = try await ProcessRunner.run(
                executable: path,
                arguments: ["pr", "view", String(pr.number), "--repo", pr.repo, "--json", "headRefOid,reviews"],
                environment: environment,
                timeout: timeout
            )
            guard result.exitCode == 0 else { return nil }
            return StaleReviewQuery.parsePerPRView(result.stdout, pr: pr, viewerLogin: login)
        } catch {
            return nil
        }
    }

    // MARK: - stderr helpers

    private static func looksUnauthenticated(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("gh auth login")
            || lowered.contains("authentication required")
            || lowered.contains("bad credentials")
            || lowered.contains("requires authentication")
    }

    /// gh is chatty on failure; the banner has one line of room.
    static func condense(_ stderr: String) -> String {
        let interesting = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty
                    && !line.hasPrefix("A new release of gh")
                    && !line.hasPrefix("To upgrade, run:")
                    && !line.hasPrefix("https://github.com/cli/cli/releases")
            }
        return interesting.first ?? ""
    }
}
