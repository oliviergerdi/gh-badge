import XCTest
@testable import GHBadgeCore

final class SeenPRsTests: XCTestCase {

    private func pr(updated: TimeInterval? = nil) -> PullRequest {
        PullRequest(
            repo: "watched/repo",
            number: 1,
            title: "PR",
            url: "https://github.com/watched/repo/pull/1",
            updatedAt: updated.map { Date(timeIntervalSince1970: $0) }
        )
    }

    // MARK: - isDimmed

    func testNeverOpenedIsNotDimmed() {
        XCTAssertFalse(SeenPRs.isDimmed(pr: pr(updated: 1_000), lastSeenUpdatedAt: nil))
    }

    func testDimmedWhenUnchangedSinceLastSeen() {
        let seenAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(SeenPRs.isDimmed(pr: pr(updated: 1_000), lastSeenUpdatedAt: seenAt))
    }

    /// Someone pushed a change (or a comment landed) after you looked: it
    /// should light back up, not stay dimmed.
    func testNotDimmedWhenUpdatedAfterLastSeen() {
        let seenAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(SeenPRs.isDimmed(pr: pr(updated: 2_000), lastSeenUpdatedAt: seenAt))
    }

    /// Can't prove nothing changed without the PR's own timestamp, so it
    /// stays undimmed — the same "can't prove it, don't act on it" rule used
    /// throughout `PRSectioning`.
    func testMissingUpdatedAtIsNotDimmed() {
        let seenAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(SeenPRs.isDimmed(pr: pr(updated: nil), lastSeenUpdatedAt: seenAt))
    }
}

/// Exercises `SeenPRStore` instance behaviour against an isolated
/// `UserDefaults` suite, same approach as `SettingsStoreIgnoredAuthorsTests`.
@MainActor
final class SeenPRStoreTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suiteName = "gh-badge-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func pr(url: String = "https://github.com/watched/repo/pull/1", updated: TimeInterval) -> PullRequest {
        PullRequest(
            repo: "watched/repo",
            number: 1,
            title: "PR",
            url: url,
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }

    func testStartsEmpty() {
        let store = SeenPRStore(defaults: freshDefaults())
        XCTAssertTrue(store.seen.isEmpty)
    }

    func testMarkOpenedRecordsThePRsOwnUpdatedAt() {
        let store = SeenPRStore(defaults: freshDefaults())
        let opened = pr(updated: 1_000)
        store.markOpened(opened)
        XCTAssertEqual(store.seen[opened.url], Date(timeIntervalSince1970: 1_000))
    }

    /// A PR with no `updatedAt` can't establish a baseline that could ever be
    /// compared back against, so it's skipped rather than stuck dimmed forever.
    func testMarkOpenedSkipsPRsWithoutUpdatedAt() {
        let store = SeenPRStore(defaults: freshDefaults())
        let undated = PullRequest(repo: "a/b", number: 1, title: "x", url: "https://github.com/a/b/pull/1")
        store.markOpened(undated)
        XCTAssertNil(store.seen[undated.url])
    }

    func testPersistsAcrossReload() {
        let defaults = freshDefaults()
        let store = SeenPRStore(defaults: defaults)
        let opened = pr(updated: 1_000)
        store.markOpened(opened)

        let reloaded = SeenPRStore(defaults: defaults)
        XCTAssertEqual(reloaded.seen[opened.url], Date(timeIntervalSince1970: 1_000))
    }

    func testPruneDropsEntriesNotInKeepSet() {
        let store = SeenPRStore(defaults: freshDefaults())
        let kept = pr(url: "https://github.com/a/b/pull/1", updated: 1_000)
        let dropped = pr(url: "https://github.com/a/b/pull/2", updated: 1_000)
        store.markOpened(kept)
        store.markOpened(dropped)

        store.prune(keeping: [kept.url])

        XCTAssertEqual(store.seen.keys.sorted(), [kept.url])
    }

    func testPruneIsANoOpWhenNothingToDrop() {
        let store = SeenPRStore(defaults: freshDefaults())
        let opened = pr(updated: 1_000)
        store.markOpened(opened)

        store.prune(keeping: [opened.url])

        XCTAssertEqual(store.seen.count, 1)
    }
}
