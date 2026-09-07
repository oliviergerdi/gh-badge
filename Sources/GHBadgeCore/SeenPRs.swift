import Foundation

/// Whether a PR you've opened has changed since. Purely local, client-side
/// bookkeeping: GitHub has no notion of "glanced at, nothing new since" — this
/// only ever lives in `gh-badge`'s own state, never synced or written back.
///
/// The decision logic is a pure, standalone function (same reasoning as
/// `PRSectioning`/`RetryBackoff`) so it's testable without a main actor or
/// `UserDefaults`; `SeenPRStore` below owns the persisted half.
public enum SeenPRs {
    /// A PR is dimmed once it's been opened and nothing has changed since.
    ///
    /// - Parameters:
    ///   - pr: the PR as most recently fetched.
    ///   - lastSeenUpdatedAt: the PR's own `updatedAt` at the moment it was
    ///     last opened, or `nil` if it's never been opened. Comparing against
    ///     the PR's own timestamp — rather than the wall-clock time of the
    ///     click — keeps both sides of the comparison on GitHub's clock, with
    ///     no risk of local clock skew.
    ///
    /// Missing data on either side means "can't prove nothing changed", so it
    /// stays undimmed — the same "can't prove it, don't act on it" rule used
    /// throughout `PRSectioning` for staleness and ignored authors.
    public static func isDimmed(pr: PullRequest, lastSeenUpdatedAt: Date?) -> Bool {
        guard let lastSeenUpdatedAt, let updatedAt = pr.updatedAt else { return false }
        return updatedAt <= lastSeenUpdatedAt
    }
}

/// Persists which PRs have been opened, and as of what revision.
///
/// Persisted rather than in-memory-only: `gh-badge` is meant to run for days
/// at a time via launch-at-login, so an in-memory map would forget every PR
/// you've looked at on every relaunch.
@MainActor
public final class SeenPRStore: ObservableObject {
    private enum Key {
        static let seenPRs = "seenPRs"
    }

    private let defaults: UserDefaults
    private var isLoading = false

    /// PR URL -> the PR's own `updatedAt` at the moment it was last opened.
    @Published public private(set) var seen: [String: Date] = [:] {
        didSet { persist() }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private func load() {
        isLoading = true
        if let data = defaults.data(forKey: Key.seenPRs),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            seen = decoded
        }
        isLoading = false
    }

    private func persist() {
        guard !isLoading else { return }
        guard let data = try? JSONEncoder().encode(seen) else { return }
        defaults.set(data, forKey: Key.seenPRs)
    }

    /// Records that `pr` was just opened. A PR with no `updatedAt` (a decode
    /// edge case) can't establish a baseline that could ever be compared
    /// back against, so it's skipped rather than stored with a value that
    /// would never let the PR un-dim.
    public func markOpened(_ pr: PullRequest) {
        guard let updatedAt = pr.updatedAt else { return }
        seen[pr.url] = updatedAt
    }

    /// Drops any entry whose PR is no longer among `urls` (closed, merged, or
    /// filtered out for good), so the persisted map doesn't grow without
    /// bound over the life of a long-running app.
    public func prune(keeping urls: Set<String>) {
        let pruned = seen.filter { urls.contains($0.key) }
        guard pruned.count != seen.count else { return }
        seen = pruned
    }
}
