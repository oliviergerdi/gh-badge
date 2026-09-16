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

    /// When the current GitHub rate-limit cooldown ends, or nil when there is
    /// none. Published so the dropdown can count down against it; also the flag
    /// that suppresses manual refresh, so a user clicking Refresh during a
    /// cooldown can't deepen the very limit they are waiting out.
    @Published public private(set) var rateLimitedUntil: Date?

    /// True while the last refusal was GitHub's *secondary* (concurrency) limit
    /// rather than the hourly budget. Only affects wording.
    @Published public private(set) var rateLimitIsSecondary = false

    /// Deliberately "a cooldown is recorded", not "the clock says it's still
    /// running". The two differ for the gap between a cooldown elapsing and the
    /// next refresh clearing it — and during that gap `ghError` still holds the
    /// rate-limit message, so a time-based test would swap the countdown banner
    /// for the generic one *with its Retry button*, the single affordance this
    /// whole change exists to withhold. `refresh()` clears the flag the moment
    /// the client's gate expires.
    public var isRateLimited: Bool { rateLimitedUntil != nil }

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
                // A rate-limit cooldown outranks both the normal cadence and
                // the transient-failure backoff: it is the only one of the
                // three where polling sooner actively prolongs the problem.
                let base: TimeInterval
                if let until = self.rateLimitedUntil, until > Date() {
                    base = RetryBackoff.delayUntilCooldownEnd(until)
                } else {
                    base = RetryBackoff.delay(
                        failureCount: self.consecutiveFailureCount,
                        normalInterval: normalInterval
                    )
                }
                let delay = RetryBackoff.jittered(base)
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
        // display filters below: branch names are only kept in memory while it
        // is on, so switching it on needs a real fetch to populate them. On the
        // consolidated path that fetch is the same single request as always —
        // the toggle no longer widens anything.
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
        // Claimed before the first `await`. Any suspension point between the
        // guard and this line lets a manual Refresh click and a poll tick both
        // slip through and run a full refresh concurrently — doubling the
        // request count, which is the very thing being fixed here.
        isRefreshing = true
        defer { isRefreshing = false }

        // Refuse outright while a cooldown is running — including for a manual
        // Refresh click. Every request made during a rate limit counts against
        // it, so the one thing that must not happen is more traffic.
        if let cooldown = await client.rateLimitState() {
            applyRateLimit(until: cooldown.until, isSecondary: cooldown.isSecondary)
            return
        }
        clearRateLimitState()

        if !didPreflight {
            do {
                try await client.preflight()
                didPreflight = true
                needsUserAction = false
                ghError = nil
            } catch let error as GHError where error.isRateLimited {
                applyRateLimit(error)
                return
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
        // Set when the consolidated GraphQL fetch supplied staleness and branch
        // names inline, which makes the separate revision round-trip below
        // unnecessary.
        var inlineRevisionInfo: PRRevisionInfo?

        let wantsAnySection = needsRaw == nil || reviewedRaw == nil || authoredRaw == nil

        // Preferred path: one request for everything (see `PRSearchQuery`).
        // Buckets this cycle doesn't need are still returned — they cost
        // nothing extra, since the expense is the request, not the fields — and
        // are simply discarded below.
        if wantsAnySection {
            do {
                if let all = try await ghClient.fetchAll(login: login, teams: settings.activeTeams) {
                    if needsRaw == nil { needsRaw = all.needsReview }
                    if reviewedRaw == nil { reviewedRaw = all.reviewedBy }
                    if authoredRaw == nil { authoredRaw = all.authored }
                    inlineRevisionInfo = all.revisionInfo
                }
            } catch let error as GHError where error.isRateLimited {
                applyRateLimit(error)
                return
            } catch let error as GHError {
                firstError = error
            } catch {
                firstError = .commandFailed(detail: error.localizedDescription)
            }
        }

        // Fallback: the old per-section REST searches, used only when the
        // consolidated fetch could not be parsed or the `gh` in play doesn't
        // support it.
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

        if let firstError, firstError.isRateLimited {
            applyRateLimit(firstError)
            return
        }

        // Fall back to the previous good result for any section that failed.
        let resolvedNeeds = needsRaw ?? lastRawNeedsReview
        let resolvedReviewed = reviewedRaw ?? lastRawReviewedBy
        let resolvedAuthored = authoredRaw ?? lastRawAuthored

        lastRawNeedsReview = resolvedNeeds
        lastRawReviewedBy = resolvedReviewed
        lastRawAuthored = resolvedAuthored

        // Extra signal plain search can't provide: for the PRs that would land
        // in "Already Reviewed", whether new commits have arrived since the
        // viewer's last review. Non-fatal by design — a failure here skips this
        // cycle's promotions and branch names without surfacing an error or
        // blocking the rest of refresh.
        //
        // nil means "couldn't look" (a cooldown, or every batch failing), which
        // is *not* the same as "nothing is stale and no PR has a branch name".
        // Overwriting the cache with an empty result would demote stale PRs out
        // of Needs My Review and blank every branch name — the opposite of the
        // "last-good data stays on screen" promise the cooldown banner makes.
        let revisionInfo: PRRevisionInfo?
        if let inlineRevisionInfo {
            // Free: the consolidated query returned `headRefOid`,
            // `headRefName` and `viewerLatestReview` on nodes it was already
            // fetching, so there is nothing left to ask for. Note this makes
            // `showBranchName` cost-free too — it no longer widens any query.
            revisionInfo = inlineRevisionInfo
        } else {
            let reviewedCandidates = PRSectioning.reviewedCandidates(
                needsReviewRaw: resolvedNeeds,
                reviewedByRaw: resolvedReviewed,
                authoredRaw: resolvedAuthored,
                whitelist: settings.repoWhitelist,
                ignoreOlderThan: settings.ignoreOlderThanCutoff,
                ignoredAuthors: settings.ignoredAuthors,
                showDraftPRs: settings.showDraftPRs
            )

            // Only on the fallback path does breadth still cost requests, so
            // only here does `showBranchName` widen the candidate set from
            // "Already Reviewed" to every PR that will actually be visible —
            // computed purely in-memory (no I/O) just to know what to ask for.
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

            revisionInfo = await ghClient.fetchRevisionInfo(for: revisionCandidates)
        }

        // Turning the setting off must clear the cache immediately, so this
        // runs whether or not fresh data arrived.
        if !settings.showBranchName { branchNames = [:] }
        if let revisionInfo {
            lastStaleReviewURLs = revisionInfo.staleReviewURLs
            if settings.showBranchName { branchNames = revisionInfo.branchNames }
        }

        recomputeSections()

        // `fetchRevisionInfo` never throws, so a limit tripped inside it only
        // shows up as client state. Pick it up before reporting success.
        if let state = await ghClient.rateLimitState() {
            applyRateLimit(until: state.until, isSecondary: state.isSecondary)
            return
        }

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
            clearRateLimitState()
            lastUpdated = Date()
            consecutiveFailureCount = 0
        }
    }

    /// Leaves no trace of a finished cooldown.
    ///
    /// `rateLimitIsSecondary` is reset alongside the date so a later *primary*
    /// limit can't be described with the leftover secondary-limit wording.
    ///
    /// `ghError` is cleared too, but only when it is still the rate-limit
    /// message. Otherwise the refresh that follows — which can take a 20s
    /// subprocess timeout — would run with `rateLimitedUntil == nil` and a
    /// stale "GitHub rate limit reached." in `ghError`, so the dropdown would
    /// fall through to the generic banner *with its Retry button* and the menu
    /// bar would show the warning glyph. A genuine non-rate-limit error from an
    /// earlier cycle is left alone to be overwritten or cleared as usual.
    private func clearRateLimitState() {
        if rateLimitedUntil != nil, ghError == Self.rateLimitMessage {
            ghError = nil
        }
        rateLimitedUntil = nil
        rateLimitIsSecondary = false
    }

    /// Single source for the banner text, so `applyRateLimit` and
    /// `clearRateLimitState` can't drift apart on the comparison above.
    private static let rateLimitMessage =
        GHError.rateLimited(retryAt: .distantFuture, isSecondary: false).errorDescription

    /// Enters the cooldown state: last-good data stays on screen, the banner
    /// explains why nothing is updating, and the poll loop waits it out.
    private func applyRateLimit(_ error: GHError) {
        guard case .rateLimited(let retryAt, let isSecondary) = error else { return }
        applyRateLimit(until: retryAt, isSecondary: isSecondary)
    }

    private func applyRateLimit(until: Date, isSecondary: Bool) {
        rateLimitedUntil = until
        rateLimitIsSecondary = isSecondary
        ghError = Self.rateLimitMessage
        // Not a configuration problem: there is nothing for the user to fix, so
        // the fatal presentation (with its "install gh" affordance) is wrong.
        needsUserAction = false
        // Deliberately not fed into `consecutiveFailureCount`: that drives
        // *faster* retries, which is the exact opposite of what a rate limit
        // calls for. The cooldown end is the schedule now.
        consecutiveFailureCount = 0
        log.error("rate limited until \(until.description, privacy: .public)")
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
    ///
    /// Neither is a rate limit, for the opposite reason — the retries would
    /// *succeed* at reaching GitHub and each one would extend the block. Three
    /// jobs × three attempts is nine extra requests aimed at a server that has
    /// just said stop; bailing on the first refusal is the whole point.
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
                if error.isFatalConfiguration || error.isRateLimited { break }
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
                // A rate limit outranks whatever else came back: it changes
                // what the caller does next (stop and wait) rather than just
                // what the banner says, so it must not be hidden behind a
                // sibling job's ordinary failure.
                if error.isRateLimited {
                    firstError = error
                } else {
                    firstError = firstError ?? error
                }
            }
        }

        return (anySuccess ? collected : nil, firstError)
    }
}
