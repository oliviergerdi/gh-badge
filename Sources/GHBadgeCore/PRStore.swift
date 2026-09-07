import Combine
import Foundation
import OSLog

@MainActor
public final class PRStore: ObservableObject {
    private let log = Logger(subsystem: "com.gerdi.gh-badge", category: "PRStore")

    @Published public private(set) var sections = PRSections()
    @Published public private(set) var ghError: String?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastUpdated: Date?

    /// PR URL -> head branch name, populated only while `settings.showBranchName`
    /// is on (see `refresh()`). Empty otherwise, including right after the
    /// setting is turned off, so stale data can't linger in the dropdown.
    @Published public private(set) var branchNames: [String: String] = [:]

    /// True while `gh` is missing or unauthenticated: the icon shows a warning
    /// and polling keeps retrying, but nothing useful will happen until the user
    /// acts.
    @Published public private(set) var needsUserAction = false

    public var badgeCount: Int { sections.badgeCount }

    private let client: GHClient
    private let settings: SettingsStore

    private var pollTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var didPreflight = false
    private var isStopped = true

    /// Last successful raw results per query, kept so that a failure in one
    /// section does not blank out the others.
    private var lastRawNeedsReview: [PullRequest] = []
    private var lastRawReviewedBy: [PullRequest] = []
    private var lastRawAuthored: [PullRequest] = []

    /// URLs of already-reviewed PRs with new commits pushed since the
    /// viewer's last review. Refreshed each `refresh()` cycle (it needs
    /// network I/O); local-only recomputes reuse whatever was last fetched.
    private var lastStaleReviewURLs: Set<String> = []

    /// Consecutive *transient* failures (network blip, timeout, a `gh`
    /// command erroring) — never incremented for fatal configuration errors,
    /// which need user action, not a faster retry. Reset to 0 by any
    /// successful refresh or fatal error. Drives `RetryBackoff.delay`, so the
    /// poll loop retries sooner than the normal interval after a failure
    /// instead of leaving a stale badge up to the user to manually refresh.
    private var consecutiveFailureCount = 0

    public init(client: GHClient, settings: SettingsStore) {
        self.client = client
        self.settings = settings
        observeSettings()
    }

    // MARK: - Lifecycle

    public func start() {
        isStopped = false
        startPolling()
    }

    public func stop() {
        isStopped = true
        pollTask?.cancel()
        pollTask = nil
    }

    private func startPolling() {
        // Without this guard, a settings change after stop() would resurrect the
        // poll loop on a terminating app.
        guard !isStopped else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let normalInterval = TimeInterval(self.settings.refreshIntervalSeconds)
                let delay = RetryBackoff.delay(
                    failureCount: self.consecutiveFailureCount,
                    normalInterval: normalInterval
                )
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return  // cancelled
                }
            }
        }
    }

    private func observeSettings() {
        // A new interval means the current sleep is stale; restart the loop.
        settings.$refreshIntervalSeconds
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.startPolling()
            }
            .store(in: &cancellables)

        // Anything that changes *what* we query should take effect promptly,
        // debounced so that typing in the whitelist editor is not one API call
        // per keystroke. `showBranchName` belongs here, not with the local
        // display filters below: flipping it changes how wide the revision-info
        // query is (see `refresh()`), so it needs a real re-fetch.
        let whitelistChanged = settings.$repoWhitelist.map { _ in () }
        let teamsChanged = settings.$teams.map { _ in () }
        let teamToggleChanged = settings.$teamReviewEnabled.map { _ in () }
        let ownPRsToggleChanged = settings.$ignoreWhitelistForOwnPRs.map { _ in () }
        let branchNameToggleChanged = settings.$showBranchName.map { _ in () }

        whitelistChanged
            .merge(with: teamsChanged, teamToggleChanged, ownPRsToggleChanged, branchNameToggleChanged)
            // Each @Published publisher replays its current value on subscribe,
            // so the five merged sources emit five times before any real change.
            .dropFirst(5)
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { await self?.refresh() }
            }
            .store(in: &cancellables)

        // Staleness filtering is a pure display filter over already-fetched
        // results, so it recomputes sections locally instead of re-hitting the
        // API on every keystroke in the amount field.
        settings.$ignoreOlderThanEnabled.map { _ in () }
            .merge(
                with: settings.$ignoreOlderThanValue.map { _ in () },
                settings.$ignoreOlderThanUnitRaw.map { _ in () }
            )
            .dropFirst(3)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.recomputeSections()
            }
            .store(in: &cancellables)

        // Same reasoning as staleness: a pure display filter over already-
        // fetched raw results (author is decoded alongside the rest), so it
        // recomputes locally instead of re-hitting the API.
        settings.$ignoredAuthors
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.recomputeSections()
            }
            .store(in: &cancellables)

        // Same reasoning again: `isDraft` is decoded alongside the rest of
        // each PR, so toggling this is a pure display filter with no need to
        // re-hit the API.
        settings.$showDraftPRs
            .dropFirst()
            .sink { [weak self] _ in
                self?.recomputeSections()
            }
            .store(in: &cancellables)
    }

    // MARK: - Refresh

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if !didPreflight {
            do {
                try await client.preflight()
                didPreflight = true
                needsUserAction = false
                ghError = nil
            } catch let error as GHError {
                apply(fatal: error)
                return
            } catch {
                apply(fatal: .commandFailed(detail: error.localizedDescription))
                return
            }
        }

        // Prefer the resolved login over "@me": `@me` is documented for
        // --review-requested and --assignee, but not for --author.
        let ghClient = self.client
        let login = await ghClient.currentLogin() ?? "@me"
        let whitelistEmpty = settings.repoWhitelist.isEmpty

        // Section 1 + 2 are whitelist-gated, so with an empty whitelist their
        // results are discarded regardless. Skip the calls instead of spending
        // rate limit on them.
        var needsRaw: [PullRequest]? = whitelistEmpty ? [] : nil
        var reviewedRaw: [PullRequest]? = whitelistEmpty ? [] : nil
        var authoredRaw: [PullRequest]? =
            (whitelistEmpty && !settings.ignoreWhitelistForOwnPRs) ? [] : nil

        var firstError: GHError?

        if needsRaw == nil {
            var jobs: [[String]] = [["--review-requested=\(login)"]]
            for team in settings.activeTeams {
                jobs.append(["--review-requested=\(team)"])
            }
            let results = await Self.runQueries(client: ghClient, jobs: jobs)
            let merged = Self.merge(results)
            needsRaw = merged.values
            firstError = firstError ?? merged.error
        }

        if reviewedRaw == nil {
            let results = await Self.runQueries(client: ghClient, jobs: [["--reviewed-by=\(login)"]])
            let merged = Self.merge(results)
            reviewedRaw = merged.values
            firstError = firstError ?? merged.error
        }

        if authoredRaw == nil {
            let results = await Self.runQueries(client: ghClient, jobs: [["--author=\(login)"]])
            let merged = Self.merge(results)
            authoredRaw = merged.values
            firstError = firstError ?? merged.error
        }

        // Fall back to the previous good result for any section that failed.
        let resolvedNeeds = needsRaw ?? lastRawNeedsReview
        let resolvedReviewed = reviewedRaw ?? lastRawReviewedBy
        let resolvedAuthored = authoredRaw ?? lastRawAuthored

        lastRawNeedsReview = resolvedNeeds
        lastRawReviewedBy = resolvedReviewed
        lastRawAuthored = resolvedAuthored

        // Extra signal `gh search prs` can't provide: for the PRs that would
        // land in "Already Reviewed", check whether new commits have landed
        // since the viewer's last review. Non-fatal by design (see
        // `GHClient.fetchRevisionInfo`) — a failure here just skips this
        // cycle's promotion/branch names, it never surfaces an error or
        // blocks the rest of refresh.
        let reviewedCandidates = PRSectioning.reviewedCandidates(
            needsReviewRaw: resolvedNeeds,
            reviewedByRaw: resolvedReviewed,
            authoredRaw: resolvedAuthored,
            whitelist: settings.repoWhitelist,
            ignoreOlderThan: settings.ignoreOlderThanCutoff,
            ignoredAuthors: settings.ignoredAuthors,
            showDraftPRs: settings.showDraftPRs
        )

        // Branch names cost one extra `gh api graphql` call, so only when the
        // setting is on do we widen the query from "Already Reviewed"
        // candidates to every PR that will actually be visible — the same set
        // `recomputeSections()` below will land on, computed here purely
        // in-memory (no I/O) just to know what to ask for.
        let revisionCandidates: [PullRequest]
        if settings.showBranchName {
            let preliminary = PRSectioning.sections(
                needsReviewRaw: resolvedNeeds,
                reviewedByRaw: resolvedReviewed,
                authoredRaw: resolvedAuthored,
                whitelist: settings.repoWhitelist,
                ignoreWhitelistForOwnPRs: settings.ignoreWhitelistForOwnPRs,
                ignoreOlderThan: settings.ignoreOlderThanCutoff,
                ignoredAuthors: settings.ignoredAuthors,
                showDraftPRs: settings.showDraftPRs
            )
            revisionCandidates = PRSectioning.dedupe(
                preliminary.needsReview + preliminary.alreadyReviewed + preliminary.myOpenPRs
            )
        } else {
            revisionCandidates = reviewedCandidates
        }

        let revisionInfo = await ghClient.fetchRevisionInfo(for: revisionCandidates)
        lastStaleReviewURLs = revisionInfo.staleReviewURLs
        branchNames = settings.showBranchName ? revisionInfo.branchNames : [:]

        recomputeSections()

        if let firstError {
            if firstError.isFatalConfiguration {
                // gh disappeared or credentials went away mid-session. Force a
                // fresh preflight next tick so recovery is automatic once the
                // user fixes it.
                didPreflight = false
                apply(fatal: firstError)
            } else {
                ghError = firstError.errorDescription
                needsUserAction = false
                // Transient: back off and retry sooner than the normal
                // interval instead of leaving stale data up until the next
                // scheduled poll or a manual click. See `RetryBackoff`.
                consecutiveFailureCount += 1
            }
            log.error("refresh completed with error: \(firstError.errorDescription ?? "?", privacy: .public)")
        } else {
            ghError = nil
            needsUserAction = false
            lastUpdated = Date()
            consecutiveFailureCount = 0
        }
    }

    /// Rebuilds `sections` from the last good raw results and current settings.
    /// Used both by `refresh()` and by local-only setting changes (staleness
    /// filter) that don't require re-querying GitHub.
    private func recomputeSections() {
        sections = PRSectioning.sections(
            needsReviewRaw: lastRawNeedsReview,
            reviewedByRaw: lastRawReviewedBy,
            authoredRaw: lastRawAuthored,
            whitelist: settings.repoWhitelist,
            ignoreWhitelistForOwnPRs: settings.ignoreWhitelistForOwnPRs,
            ignoreOlderThan: settings.ignoreOlderThanCutoff,
            ignoredAuthors: settings.ignoredAuthors,
            showDraftPRs: settings.showDraftPRs,
            staleReviewURLs: lastStaleReviewURLs
        )
    }

    /// Clears the sticky error state and forces a full re-check.
    public func retryFromScratch() async {
        didPreflight = false
        await refresh()
    }

    private func apply(fatal error: GHError) {
        ghError = error.errorDescription
        needsUserAction = error.isFatalConfiguration
        // Fatal configuration errors (gh missing, not authenticated) need the
        // user to act; retrying faster won't help, so this doesn't feed
        // `RetryBackoff` — the poll loop just keeps its normal cadence.
        consecutiveFailureCount = 0
        log.error("fatal: \(error.errorDescription ?? "?", privacy: .public)")
    }

    // MARK: - Query plumbing

    /// Runs jobs concurrently. `GHClient` is an actor, but each job suspends on
    /// its subprocess, so the actor interleaves them rather than serialising.
    private static func runQueries(
        client: GHClient,
        jobs: [[String]]
    ) async -> [Result<[PullRequest], GHError>] {
        await withTaskGroup(of: Result<[PullRequest], GHError>.self) { group in
            for filters in jobs {
                group.addTask {
                    await Self.searchPRsWithRetry(client: client, filters: filters)
                }
            }
            var out: [Result<[PullRequest], GHError>] = []
            for await result in group { out.append(result) }
            return out
        }
    }

    /// A single flaky `gh` invocation (e.g. "connection closed by peer" on one
    /// concurrent subprocess call) shouldn't need an entire extra poll cycle —
    /// and the error banner that comes with it — just because sibling jobs in
    /// the same batch happened to succeed. Retries in place, a few times, with
    /// a short backoff, before giving up and letting the caller treat it as a
    /// failed job. See `RetryBackoff.jobRetryDelay`.
    ///
    /// Fatal configuration errors (`gh` missing, not authenticated) are not
    /// retried here: every attempt would fail identically, and that class of
    /// error needs user action, not persistence.
    private static func searchPRsWithRetry(
        client: GHClient,
        filters: [String]
    ) async -> Result<[PullRequest], GHError> {
        var lastError = GHError.commandFailed(detail: "")
        for attempt in 1...RetryBackoff.maxJobAttempts {
            do {
                return .success(try await client.searchPRs(filters: filters))
            } catch let error as GHError {
                lastError = error
                if error.isFatalConfiguration { break }
            } catch {
                lastError = .commandFailed(detail: error.localizedDescription)
            }
            if attempt < RetryBackoff.maxJobAttempts {
                let delay = RetryBackoff.jobRetryDelay(attempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        return .failure(lastError)
    }

    /// Partial success is still useful: if the personal review query works and a
    /// team query fails, show what we have and report the error.
    /// `values == nil` means every job failed, so the caller should keep its cache.
    private static func merge(
        _ results: [Result<[PullRequest], GHError>]
    ) -> (values: [PullRequest]?, error: GHError?) {
        var collected: [PullRequest] = []
        var anySuccess = false
        var firstError: GHError?

        for result in results {
            switch result {
            case .success(let prs):
                anySuccess = true
                collected.append(contentsOf: prs)
            case .failure(let error):
                firstError = firstError ?? error
            }
        }

        return (anySuccess ? collected : nil, firstError)
    }
}
