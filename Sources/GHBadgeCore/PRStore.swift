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
                let seconds = self.settings.refreshIntervalSeconds
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
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
        // per keystroke.
        let whitelistChanged = settings.$repoWhitelist.map { _ in () }
        let teamsChanged = settings.$teams.map { _ in () }
        let teamToggleChanged = settings.$teamReviewEnabled.map { _ in () }
        let ownPRsToggleChanged = settings.$ignoreWhitelistForOwnPRs.map { _ in () }

        whitelistChanged
            .merge(with: teamsChanged, teamToggleChanged, ownPRsToggleChanged)
            // Each @Published publisher replays its current value on subscribe,
            // so the four merged sources emit four times before any real change.
            .dropFirst(4)
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
            }
            log.error("refresh completed with error: \(firstError.errorDescription ?? "?", privacy: .public)")
        } else {
            ghError = nil
            needsUserAction = false
            lastUpdated = Date()
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
            ignoreOlderThan: settings.ignoreOlderThanCutoff
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
                    do {
                        return .success(try await client.searchPRs(filters: filters))
                    } catch let error as GHError {
                        return .failure(error)
                    } catch {
                        return .failure(.commandFailed(detail: error.localizedDescription))
                    }
                }
            }
            var out: [Result<[PullRequest], GHError>] = []
            for await result in group { out.append(result) }
            return out
        }
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
