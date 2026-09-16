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
    /// GitHub refused for rate limiting. `retryAt` is when requests may resume
    /// — always concrete by the time this reaches a caller, because `GHClient`
    /// resolves GitHub's (optional) reset hint through
    /// `RetryBackoff.rateLimitCooldownEnd` before throwing.
    case rateLimited(retryAt: Date, isSecondary: Bool)

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
        case .rateLimited:
            // No countdown baked in: the banner renders a live one from
            // `PRStore.rateLimitedUntil`, and a string frozen at throw time
            // would be wrong within seconds.
            return "GitHub rate limit reached."
        }
    }

    /// True when retrying is pointless until the user does something.
    public var isFatalConfiguration: Bool {
        switch self {
        case .notInstalled, .notAuthenticated: return true
        case .commandFailed, .timedOut, .decodingFailed, .rateLimited: return false
        }
    }

    /// Rate limiting is transient like a network blip, but the remedy is the
    /// opposite: *stop* sending requests. Callers use this to skip the
    /// in-cycle retry loop, which would otherwise spend three more requests
    /// making the limit worse.
    public var isRateLimited: Bool {
        if case .rateLimited = self { return true }
        return false
    }

    public var rateLimitRetryAt: Date? {
        if case .rateLimited(let retryAt, _) = self { return retryAt }
        return nil
    }
}

/// Result of a `PRRevisionQuery`: per-PR data `gh search prs` can't provide,
/// fetched together in one call so a caller that wants either piece doesn't
/// pay for a second round-trip to get the other. `public` because it's part
/// of `GHClient.fetchRevisionInfo`'s public signature, same as `PullRequest`.
public struct PRRevisionInfo: Equatable, Sendable {
    /// URLs of PRs whose head commit has moved past the viewer's last review
    /// on them.
    public var staleReviewURLs: Set<String> = []
    /// PR URL -> head branch name, for whichever PRs were included in the
    /// query and had one.
    public var branchNames: [String: String] = [:]
}

/// Pure query-building and response-parsing for per-PR data not available
/// from `gh search prs`, deliberately separated from `GHClient` so it's
/// testable without spawning a process. Covers two things in one query:
///   - staleness: the viewer reviewed this PR, and its head commit has since
///     moved past the commit that review was submitted against.
///   - the PR's head branch name, for `showBranchName`.
enum PRRevisionQuery {
    /// One aliased `repository` block per PR, so an arbitrary-length list of
    /// checks batches into a single GraphQL request instead of N round-trips.
    /// `viewerLatestReview` is a GraphQL convenience field scoped to the
    /// authenticated caller — no need to know or match the viewer's login.
    /// `headRefName` is fetched unconditionally: it's one more scalar field on
    /// a node this query already visits, so it costs nothing extra even on a
    /// call whose caller only cares about staleness.
    static func build(for prs: [PullRequest]) -> String {
        let blocks = prs.enumerated().compactMap { index, pr -> String? in
            let parts = pr.repo.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return """
            r\(index): repository(owner: "\(escape(parts[0]))", name: "\(escape(parts[1]))") {
              pullRequest(number: \(pr.number)) {
                headRefOid
                headRefName
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
    /// A node that's missing or malformed simply contributes nothing for that
    /// PR to either piece of data — same "can't prove it, don't move it" rule
    /// used elsewhere: a parsing gap should never wrongly yank a PR out of the
    /// reviewed list, and a missing branch name just means the row shows none.
    static func parse(_ responseData: Data, prs: [PullRequest]) -> PRRevisionInfo {
        guard
            let root = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let data = root["data"] as? [String: Any]
        else { return PRRevisionInfo() }

        var info = PRRevisionInfo()
        for (index, pr) in prs.enumerated() {
            guard
                let repoNode = data["r\(index)"] as? [String: Any],
                let prNode = repoNode["pullRequest"] as? [String: Any]
            else { continue }

            if let branchName = prNode["headRefName"] as? String {
                info.branchNames[pr.url] = branchName
            }

            if
                let headRefOid = prNode["headRefOid"] as? String,
                let review = prNode["viewerLatestReview"] as? [String: Any],
                let commit = review["commit"] as? [String: Any],
                let reviewedOid = commit["oid"] as? String,
                reviewedOid != headRefOid
            {
                info.staleReviewURLs.insert(pr.url)
            }
        }
        return info
    }

    /// Fallback parser for `gh pr view <n> --json headRefOid,headRefName,reviews`:
    /// same rules as `parse`, but the viewer's review has to be picked out by
    /// login (no `viewerLatestReview` convenience field on this shape) — the
    /// most recent one by `submittedAt`.
    static func parsePerPRView(
        _ data: Data,
        pr: PullRequest,
        viewerLogin: String
    ) -> (isStale: Bool, branchName: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, nil)
        }

        let branchName = root["headRefName"] as? String

        guard
            let headRefOid = root["headRefOid"] as? String,
            let reviews = root["reviews"] as? [[String: Any]]
        else { return (false, branchName) }

        let mine = reviews.filter { ($0["author"] as? [String: Any])?["login"] as? String == viewerLogin }
        guard
            let latest = mine.max(by: { submittedDate($0) < submittedDate($1) }),
            let commit = latest["commit"] as? [String: Any],
            let reviewedOid = commit["oid"] as? String
        else { return (false, branchName) }

        return (reviewedOid != headRefOid, branchName)
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

    // MARK: Rate-limit state

    /// While set and in the future, every `gh` call short-circuits. This is the
    /// single most important part of the fix: without it, a rate limit produces
    /// *more* traffic, not less — the poll loop keeps firing, each cycle's jobs
    /// each retry three times, and every one of those requests extends the
    /// block it is trying to wait out.
    private var rateLimitedUntil: Date?
    private var rateLimitIsSecondary = false
    /// Drives the blind-wait escalation in `RetryBackoff.rateLimitCooldownEnd`
    /// for refusals that carry no reset time. Cleared by any successful call.
    private var consecutiveRateLimits = 0

    /// `gh api -i` prints response headers, which is the only way to see
    /// `retry-after` / `x-ratelimit-reset` through the CLI. Flipped off
    /// permanently if a `gh` old enough to reject the flag is in play, so one
    /// unlucky version degrades the reset precision rather than every call.
    private var supportsIncludeFlag = true

    public init(requestTimeout: TimeInterval = 20) {
        self.requestTimeout = requestTimeout
    }

    /// When the current cooldown ends, or nil if requests may proceed.
    /// Self-expiring: a cooldown in the past is cleared rather than reported.
    public func rateLimitState() -> (until: Date, isSecondary: Bool)? {
        guard let until = rateLimitedUntil else { return nil }
        guard until > Date() else {
            rateLimitedUntil = nil
            return nil
        }
        return (until, rateLimitIsSecondary)
    }

    /// Records a refusal and returns the error to throw for it.
    private func noteRateLimit(_ info: RateLimitInfo) -> GHError {
        consecutiveRateLimits += 1
        let end = RetryBackoff.rateLimitCooldownEnd(
            resetAt: info.resetAt,
            consecutiveRateLimits: consecutiveRateLimits
        )
        // Never shorten an active cooldown: a second refusal arriving mid-wait
        // (from a call already in flight) must not let requests resume early.
        rateLimitedUntil = max(end, rateLimitedUntil ?? end)
        rateLimitIsSecondary = info.isSecondary
        let kind = info.isSecondary ? "secondary" : "primary"
        let until = rateLimitedUntil ?? end
        log.error("rate limited (\(kind, privacy: .public)); holding off until \(until.description, privacy: .public)")
        return .rateLimited(retryAt: until, isSecondary: info.isSecondary)
    }

    private func clearRateLimit() {
        rateLimitedUntil = nil
        consecutiveRateLimits = 0
    }

    // MARK: - Invocation

    /// Every `gh` call goes through here, so the cooldown gate and rate-limit
    /// detection can't be forgotten at a call site.
    ///
    /// - Parameter includeHeaders: adds `-i` for `gh api` calls, whose response
    ///   head carries the reset timing. Meaningless for `gh search`/`gh pr`.
    private func runGH(
        arguments: [String],
        includeHeaders: Bool = false,
        timeout: TimeInterval? = nil
    ) async throws -> (output: ProcessOutput, body: Data) {
        if let state = rateLimitState() {
            throw GHError.rateLimited(retryAt: state.until, isSecondary: state.isSecondary)
        }

        let path = try await ghPath()
        var args = arguments
        if includeHeaders, supportsIncludeFlag {
            // After the subcommand, before the flags gh itself parses.
            args.insert("-i", at: min(2, args.count))
        }

        log.debug("gh \(args.joined(separator: " "), privacy: .public)")

        let result: ProcessOutput
        do {
            result = try await ProcessRunner.run(
                executable: path,
                arguments: args,
                environment: environment(),
                timeout: timeout ?? requestTimeout
            )
        } catch let error as ProcessRunnerError {
            if case .timedOut = error { throw GHError.timedOut }
            throw GHError.commandFailed(detail: error.localizedDescription)
        }

        if includeHeaders, supportsIncludeFlag, Self.rejectedUnknownFlag(result.stderr) {
            log.info("this gh does not accept `-i`; retrying without response headers")
            supportsIncludeFlag = false
            return try await runGH(arguments: arguments, includeHeaders: false, timeout: timeout)
        }

        if let info = RateLimitDetector.detect(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode
        ) {
            throw noteRateLimit(info)
        }

        let body = RateLimitDetector.splitHTTPResponse(result.stdout)?.body ?? result.stdout

        if result.exitCode == 0 {
            clearRateLimit()
        }
        return (result, body)
    }

    private static func rejectedUnknownFlag(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("unknown flag") || lowered.contains("unknown shorthand flag")
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

        // `gh auth status` and `gh api user` both hit the network. Running them
        // during a cooldown would fail for rate-limit reasons and be reported
        // as "not authenticated" — a fatal-looking error that would tell the
        // user to re-run `gh auth login` for no reason.
        if let state = rateLimitState() {
            throw GHError.rateLimited(retryAt: state.until, isSecondary: state.isSecondary)
        }

        tokenPolicy = .useStoredCredential
        var lastDetail = ""

        if let detail = try await authFailureDetail(path: path) {
            lastDetail = detail
            // Some setups only ever had a PAT in the environment. Try that
            // before declaring the user unauthenticated.
            tokenPolicy = .inheritEnvironmentToken
            if let secondDetail = try await authFailureDetail(path: path) {
                tokenPolicy = .useStoredCredential
                log.error("gh auth failed both ways: \(lastDetail, privacy: .public) / \(secondDetail, privacy: .public)")
                throw GHError.notAuthenticated(detail: lastDetail)
            }
            log.info("gh auth succeeded using an environment token")
        }

        cachedLogin = await fetchLogin(path: path)
    }

    /// Returns nil when authenticated, otherwise a detail string.
    ///
    /// Throws only `GHError.rateLimited`, so a refusal can't be misread as a
    /// credential problem. Everything else still degrades to a detail string.
    private func authFailureDetail(path: String) async throws -> String? {
        do {
            let result = try await ProcessRunner.run(
                executable: path,
                arguments: ["auth", "status"],
                environment: environment(),
                timeout: requestTimeout
            )
            if let info = RateLimitDetector.detect(
                stdout: result.stdout,
                stderr: result.stderr,
                exitCode: result.exitCode
            ) {
                throw noteRateLimit(info)
            }
            return result.exitCode == 0 ? nil : (result.stderr.isEmpty ? "exit \(result.exitCode)" : result.stderr)
        } catch let error as GHError where error.isRateLimited {
            throw error
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
    private static let jsonFields = "repository,number,title,url,updatedAt,state,author,isDraft"

    /// Runs `gh search prs <filters> --state=open --json <fields>`.
    ///
    /// `filters` are passed through verbatim, e.g. `["--review-requested=@me"]`.
    public func searchPRs(filters: [String], limit: Int = 60) async throws -> [PullRequest] {
        var arguments = ["search", "prs"]
        arguments.append(contentsOf: filters)
        arguments.append(contentsOf: [
            "--state=open",
            "--limit", String(limit),
            "--json", Self.jsonFields,
        ])

        let (result, body) = try await runGH(arguments: arguments)

        guard result.exitCode == 0 else {
            let detail = Self.condense(result.stderr)
            if Self.looksUnauthenticated(result.stderr) {
                throw GHError.notAuthenticated(detail: detail)
            }
            log.error("gh exited \(result.exitCode): \(result.stderr, privacy: .public)")
            throw GHError.commandFailed(detail: detail)
        }

        return try decode(body)
    }

    // MARK: - Consolidated fetch

    /// One `gh api graphql` request covering all three sections, every team, and
    /// the per-PR revision data — replacing the `3 + teams` REST searches plus a
    /// revision round-trip plus a possible per-PR storm that the old shape cost.
    /// See `PRSearchQuery` for why this is the fix for the rate limiting.
    ///
    /// Throws only for rate limiting, which the caller must not paper over.
    /// Every other failure returns nil so the caller can fall back to the REST
    /// path — a `gh` too old for some field, or a schema change, should degrade
    /// rather than blank the badge.
    public func fetchAll(login: String, teams: [String]) async throws -> PRSearchResponse? {
        let query = PRSearchQuery.build(login: login, teams: teams)

        let fetched: (output: ProcessOutput, body: Data)
        do {
            fetched = try await runGH(
                arguments: ["api", "graphql", "-f", "query=\(query)"],
                includeHeaders: true
            )
        } catch let error as GHError where error.isRateLimited {
            throw error
        } catch {
            log.info("consolidated GraphQL fetch failed (\(error.localizedDescription, privacy: .public)); falling back to gh search")
            return nil
        }
        let result = fetched.output
        let body = fetched.body

        // Deliberately *not* rethrown as `.notAuthenticated`, unlike
        // `searchPRs`. A token can be fine for `gh search prs` yet lack a scope
        // this GraphQL document needs, and "requires authentication" on stderr
        // is all that distinguishes the two. Throwing here would leave a fatal
        // "run gh auth login" banner sitting on top of a fallback that
        // succeeded. Preflight and the REST path own that classification.
        guard result.exitCode == 0 else {
            log.info("consolidated GraphQL fetch exited \(result.exitCode): \(result.stderr, privacy: .public)")
            return nil
        }

        guard let response = PRSearchQuery.parse(body) else {
            log.error("consolidated GraphQL response unparseable; falling back to gh search")
            return nil
        }

        if !response.truncatedBuckets.isEmpty {
            // Not an error the user can act on, but it does mean a watched
            // repo's PR could be missing, so it belongs in the log.
            log.notice(
                "GraphQL buckets hit the \(PRSearchQuery.maxPageSize) result cap: \(response.truncatedBuckets.joined(separator: ", "), privacy: .public)"
            )
        }
        return response
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

    // MARK: - Revision info (stale reviews + branch names)

    /// Largest number of aliased `repository` blocks to put in one GraphQL
    /// document. GitHub scores a query's cost before running it and rejects
    /// documents that are too large — and a rejection here used to cascade into
    /// the per-PR fan-out below, turning one refused request into dozens of
    /// real ones. Chunking keeps every document comfortably inside the limit.
    static let maxRevisionBatchSize = 25

    /// Most `gh pr view` calls allowed in flight at once in the fallback path.
    /// The secondary rate limit keys off concurrency, not volume, so this is
    /// the number that actually matters. Four is the same order as a browser's
    /// per-host connection budget and has never been the bottleneck: the
    /// fallback is rare and the calls are short.
    static let maxConcurrentPerPRRequests = 4

    /// Above this many PRs, skip the per-PR fallback entirely rather than make
    /// hundreds of requests to decorate rows. Staleness and branch names are a
    /// display enhancement (see below); losing them for one cycle is strictly
    /// better than losing GitHub access for the next hour.
    static let maxPerPRFallbackCandidates = 30

    /// For each PR in `candidates`, checks whether its head commit has moved
    /// past the viewer's last review on it, and reads its head branch name.
    ///
    /// Only reached on the fallback path now: `fetchAll` returns both pieces
    /// inline, so a healthy refresh never calls this at all. It remains for the
    /// case where the consolidated query is unavailable.
    ///
    /// Batches are chunked, and the per-PR fallback is both bounded and
    /// abandoned above `maxPerPRFallbackCandidates` — the unbounded version of
    /// this method is what tripped GitHub's secondary rate limit once more than
    /// a handful of repos were watched.
    ///
    /// Never throws: this is a display enhancement, not core functionality, so
    /// a total failure here should silently skip the enhancement rather than
    /// surface an error banner or block a refresh.
    /// - Returns: nil when nothing could be looked up at all — an active
    ///   cooldown, or every batch failing with no usable fallback. That is
    ///   distinct from an empty `PRRevisionInfo`, which means "looked, and
    ///   nothing is stale". Callers must not overwrite cached staleness with
    ///   the former, or reviewed PRs silently lose their promotion.
    public func fetchRevisionInfo(for candidates: [PullRequest]) async -> PRRevisionInfo? {
        guard !candidates.isEmpty else { return PRRevisionInfo() }

        // Honour an active cooldown here too: this path is "never throws", so
        // without an explicit check it would happily keep hammering while the
        // rest of the app is waiting one out.
        if rateLimitState() != nil { return nil }

        var merged = PRRevisionInfo()
        var anySucceeded = false
        // Only the PRs from batches that actually failed. Re-querying a whole
        // 100-PR candidate list because one 25-PR chunk failed would be three
        // quarters wasted requests, aimed at an API that may already be
        // refusing us.
        var unresolved: [PullRequest] = []

        for start in stride(from: 0, to: candidates.count, by: Self.maxRevisionBatchSize) {
            let chunk = Array(candidates[start..<min(start + Self.maxRevisionBatchSize, candidates.count)])
            guard let info = await revisionInfoViaGraphQL(chunk) else {
                unresolved.append(contentsOf: chunk)
                continue
            }
            anySucceeded = true
            merged.staleReviewURLs.formUnion(info.staleReviewURLs)
            merged.branchNames.merge(info.branchNames) { _, new in new }
        }

        guard !unresolved.isEmpty else { return merged }

        // The chunks above may be *why* we are now rate limited. Re-check
        // before the fallback: `revisionInfoPerPR` spawns processes through a
        // static helper that can't consult the actor's gate itself, so this is
        // the last place the cooldown can be honoured.
        if rateLimitState() != nil { return anySucceeded ? merged : nil }

        guard unresolved.count <= Self.maxPerPRFallbackCandidates else {
            log.notice(
                "revision-info batch failed for \(unresolved.count) PRs; skipping per-PR fallback to stay under the rate limit"
            )
            return anySucceeded ? merged : nil
        }

        log.info("revision-info GraphQL batch failed for \(unresolved.count) PRs; falling back to per-PR gh pr view")
        guard let perPR = await revisionInfoPerPR(unresolved) else {
            return anySucceeded ? merged : nil
        }
        merged.staleReviewURLs.formUnion(perPR.staleReviewURLs)
        merged.branchNames.merge(perPR.branchNames) { existing, _ in existing }
        return merged
    }

    /// nil means the batched call failed outright; the caller falls back to
    /// per-PR calls rather than treating that as "nothing is stale, no branches".
    private func revisionInfoViaGraphQL(_ candidates: [PullRequest]) async -> PRRevisionInfo? {
        let query = PRRevisionQuery.build(for: candidates)
        do {
            let (result, body) = try await runGH(
                arguments: ["api", "graphql", "-f", "query=\(query)"],
                includeHeaders: true
            )
            guard result.exitCode == 0, !body.isEmpty else { return nil }
            return PRRevisionQuery.parse(body, prs: candidates)
        } catch {
            return nil
        }
    }

    /// Bounded fan-out: `maxConcurrentPerPRRequests` tasks are started, and each
    /// one pulls the next PR off the queue as it finishes.
    ///
    /// The unbounded version of this — one child task per PR, all launched at
    /// once — is what made the app trip GitHub's secondary rate limit past
    /// roughly four watched repos. With `showBranchName` on, `candidates` is
    /// *every visible PR*, so a busy user could put 50+ simultaneous requests
    /// on the wire every poll.
    ///
    /// nil, not an empty `PRRevisionInfo`, when it couldn't even start — `gh`
    /// unlocatable, or no cached login to match reviews against. An empty
    /// result here is otherwise indistinguishable from "looked, nothing stale",
    /// and the caller would take it as licence to wipe the cache.
    private func revisionInfoPerPR(_ candidates: [PullRequest]) async -> PRRevisionInfo? {
        guard let path = try? await ghPath(), let login = cachedLogin else { return nil }
        let env = environment()
        let timeout = requestTimeout
        let width = min(Self.maxConcurrentPerPRRequests, candidates.count)

        return await withTaskGroup(of: (String, isStale: Bool, branchName: String?).self) { group in
            var next = 0
            var inFlight = 0
            var info = PRRevisionInfo()

            // Top up to `width` in flight, harvest one, top up again. The
            // window never widens, however many PRs are queued behind it.
            while next < candidates.count || inFlight > 0 {
                while inFlight < width, next < candidates.count {
                    let pr = candidates[next]
                    next += 1
                    inFlight += 1
                    group.addTask {
                        let result = await Self.revisionInfoForOnePR(
                            path: path,
                            pr: pr,
                            login: login,
                            environment: env,
                            timeout: timeout
                        )
                        return (pr.url, result.isStale, result.branchName)
                    }
                }

                guard let finished = await group.next() else { break }
                inFlight -= 1
                if finished.isStale { info.staleReviewURLs.insert(finished.0) }
                if let branchName = finished.branchName { info.branchNames[finished.0] = branchName }
            }
            return info
        }
    }

    private static func revisionInfoForOnePR(
        path: String,
        pr: PullRequest,
        login: String,
        environment: [String: String],
        timeout: TimeInterval
    ) async -> (isStale: Bool, branchName: String?) {
        do {
            let result = try await ProcessRunner.run(
                executable: path,
                arguments: [
                    "pr", "view", String(pr.number),
                    "--repo", pr.repo,
                    "--json", "headRefOid,headRefName,reviews",
                ],
                environment: environment,
                timeout: timeout
            )
            guard result.exitCode == 0 else { return (false, nil) }
            return PRRevisionQuery.parsePerPRView(result.stdout, pr: pr, viewerLogin: login)
        } catch {
            return (false, nil)
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
