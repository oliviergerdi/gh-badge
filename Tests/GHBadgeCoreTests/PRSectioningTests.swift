import XCTest
@testable import GHBadgeCore

final class PRSectioningTests: XCTestCase {

    private func pr(
        _ repo: String,
        _ number: Int,
        updated: TimeInterval? = nil
    ) -> PullRequest {
        PullRequest(
            repo: repo,
            number: number,
            title: "PR \(number)",
            url: "https://github.com/\(repo)/pull/\(number)",
            updatedAt: updated.map { Date(timeIntervalSince1970: $0) },
            state: "open"
        )
    }

    // MARK: - Whitelist filtering

    func testEmptyWhitelistYieldsEmptyReviewSections() {
        let sections = PRSectioning.sections(
            needsReviewRaw: [pr("a/b", 1)],
            reviewedByRaw: [pr("a/b", 2)],
            authoredRaw: [pr("a/b", 3)],
            whitelist: [],
            ignoreWhitelistForOwnPRs: false
        )
        XCTAssertTrue(sections.needsReview.isEmpty)
        XCTAssertTrue(sections.alreadyReviewed.isEmpty)
        XCTAssertTrue(sections.myOpenPRs.isEmpty)
        XCTAssertEqual(sections.badgeCount, 0)
    }

    func testWhitelistFiltersByRepo() {
        let sections = PRSectioning.sections(
            needsReviewRaw: [pr("watched/repo", 1), pr("other/repo", 2)],
            reviewedByRaw: [],
            authoredRaw: [],
            whitelist: ["watched/repo"],
            ignoreWhitelistForOwnPRs: false
        )
        XCTAssertEqual(sections.needsReview.map(\.repo), ["watched/repo"])
    }

    func testWhitelistMatchingIsCaseInsensitive() {
        let sections = PRSectioning.sections(
            needsReviewRaw: [pr("TestOrg/Platform", 1)],
            reviewedByRaw: [],
            authoredRaw: [],
            whitelist: ["testorg/platform"],
            ignoreWhitelistForOwnPRs: false
        )
        XCTAssertEqual(sections.needsReview.count, 1)
    }

    func testOwnPRsCanIgnoreWhitelist() {
        let sections = PRSectioning.sections(
            needsReviewRaw: [],
            reviewedByRaw: [],
            authoredRaw: [pr("anywhere/else", 9), pr("watched/repo", 10)],
            whitelist: ["watched/repo"],
            ignoreWhitelistForOwnPRs: true
        )
        XCTAssertEqual(sections.myOpenPRs.count, 2)
    }

    func testOwnPRsRespectWhitelistWhenToggleOff() {
        let sections = PRSectioning.sections(
            needsReviewRaw: [],
            reviewedByRaw: [],
            authoredRaw: [pr("anywhere/else", 9), pr("watched/repo", 10)],
            whitelist: ["watched/repo"],
            ignoreWhitelistForOwnPRs: false
        )
        XCTAssertEqual(sections.myOpenPRs.map(\.repo), ["watched/repo"])
    }

    // MARK: - Section 1 / 2 overlap

    func testReRequestedReviewAppearsOnlyInNeedsReview() {
        let contested = pr("watched/repo", 1)
        let sections = PRSectioning.sections(
            needsReviewRaw: [contested],
            reviewedByRaw: [contested, pr("watched/repo", 2)],
            authoredRaw: [],
            whitelist: ["watched/repo"],
            ignoreWhitelistForOwnPRs: false
        )
        XCTAssertEqual(sections.needsReview.map(\.number), [1])
        XCTAssertEqual(sections.alreadyReviewed.map(\.number), [2])
    }

    /// A PR filtered out of section 1 by the whitelist must not be treated as
    /// "already in section 1" and thereby vanish from section 2 as well.
    func testExclusionUsesFilteredNeedsReviewNotRawInput() {
        let unwatched = pr("other/repo", 1)
        let sections = PRSectioning.sections(
            needsReviewRaw: [unwatched],
            reviewedByRaw: [unwatched],
            authoredRaw: [],
            whitelist: ["watched/repo"],
            ignoreWhitelistForOwnPRs: false
        )
        XCTAssertTrue(sections.needsReview.isEmpty)
        XCTAssertTrue(sections.alreadyReviewed.isEmpty)
    }

    // MARK: - Own PRs

    /// A PR you authored can't be "needing your review", even when a team you're
    /// in was requested (which is how the per-team query pulls it in).
    func testAuthoredPRIsExcludedFromNeedsReview() {
        let own = pr("watched/repo", 54)
        let sections = PRSectioning.sections(
            needsReviewRaw: [own, pr("watched/repo", 56)],
            reviewedByRaw: [],
            authoredRaw: [own],
            whitelist: ["watched/repo"],
            ignoreWhitelistForOwnPRs: false
        )
        XCTAssertEqual(sections.needsReview.map(\.number), [56])
        XCTAssertEqual(sections.myOpenPRs.map(\.number), [54])
        XCTAssertEqual(sections.badgeCount, 1)
    }

    // MARK: - De-duplication

    func testDedupeKeepsFirstOccurrence() {
        let duplicate = pr("watched/repo", 1)
        let sections = PRSectioning.sections(
            needsReviewRaw: [duplicate, duplicate, pr("watched/repo", 2)],
            reviewedByRaw: [],
            authoredRaw: [],
            whitelist: ["watched/repo"],
            ignoreWhitelistForOwnPRs: false
        )
        XCTAssertEqual(sections.needsReview.count, 2)
    }

    /// The personal and per-team review-requested queries overlap whenever both
    /// the user and their team are asked to review.
    func testUserAndTeamResultsAreMerged() {
        let shared = pr("watched/repo", 5)
        let teamOnly = pr("watched/repo", 6)
        let sections = PRSectioning.sections(
            needsReviewRaw: [shared] + [shared, teamOnly],
            reviewedByRaw: [],
            authoredRaw: [],
            whitelist: ["watched/repo"],
            ignoreWhitelistForOwnPRs: false
        )
        XCTAssertEqual(sections.needsReview.map(\.number).sorted(), [5, 6])
        XCTAssertEqual(sections.badgeCount, 2)
    }

    // MARK: - Ordering

    func testSortsNewestFirst() {
        let sections = PRSectioning.sections(
            needsReviewRaw: [
                pr("watched/repo", 1, updated: 1_000),
                pr("watched/repo", 2, updated: 3_000),
                pr("watched/repo", 3, updated: 2_000),
            ],
            reviewedByRaw: [],
            authoredRaw: [],
            whitelist: ["watched/repo"],
            ignoreWhitelistForOwnPRs: false
        )
        XCTAssertEqual(sections.needsReview.map(\.number), [2, 3, 1])
    }

    func testUndatedEntriesSortLast() {
        let sections = PRSectioning.sections(
            needsReviewRaw: [
                pr("watched/repo", 1),
                pr("watched/repo", 2, updated: 1_000),
            ],
            reviewedByRaw: [],
            authoredRaw: [],
            whitelist: ["watched/repo"],
            ignoreWhitelistForOwnPRs: false
        )
        XCTAssertEqual(sections.needsReview.map(\.number), [2, 1])
    }

    // MARK: - Staleness

    func testIgnoreOlderThanFiltersOldPRs() {
        let now = Date(timeIntervalSince1970: 100_000)
        let cutoff = SettingsStore.cutoff(now: now, amount: 1, unit: .days)
        let fresh = pr("watched/repo", 1, updated: 90_000)
        let stale = pr("watched/repo", 2, updated: 1_000)
        let sections = PRSectioning.sections(
            needsReviewRaw: [fresh, stale],
            reviewedByRaw: [],
            authoredRaw: [],
            whitelist: ["watched/repo"],
            ignoreWhitelistForOwnPRs: false,
            ignoreOlderThan: cutoff
        )
        XCTAssertEqual(sections.needsReview.map(\.number), [1])
    }

    func testIgnoreOlderThanKeepsUndatedPRs() {
        let now = Date(timeIntervalSince1970: 100_000)
        let cutoff = SettingsStore.cutoff(now: now, amount: 1, unit: .days)
        let undated = pr("watched/repo", 1)
        let stale = pr("watched/repo", 2, updated: 1_000)
        let sections = PRSectioning.sections(
            needsReviewRaw: [undated, stale],
            reviewedByRaw: [],
            authoredRaw: [],
            whitelist: ["watched/repo"],
            ignoreWhitelistForOwnPRs: false,
            ignoreOlderThan: cutoff
        )
        XCTAssertEqual(sections.needsReview.map(\.number), [1])
    }

    func testIgnoreOlderThanAppliesToAllSections() {
        let now = Date(timeIntervalSince1970: 100_000)
        let cutoff = SettingsStore.cutoff(now: now, amount: 1, unit: .days)
        let stale = pr("watched/repo", 1, updated: 1_000)
        let sections = PRSectioning.sections(
            needsReviewRaw: [stale],
            reviewedByRaw: [stale],
            authoredRaw: [stale],
            whitelist: ["watched/repo"],
            ignoreWhitelistForOwnPRs: true,
            ignoreOlderThan: cutoff
        )
        XCTAssertTrue(sections.isEmpty)
        XCTAssertEqual(sections.badgeCount, 0)
    }

    // MARK: - Badge

    func testBadgeCountsOnlyNeedsReview() {
        let sections = PRSectioning.sections(
            needsReviewRaw: [pr("watched/repo", 1)],
            reviewedByRaw: [pr("watched/repo", 2)],
            authoredRaw: [pr("watched/repo", 3)],
            whitelist: ["watched/repo"],
            ignoreWhitelistForOwnPRs: false
        )
        XCTAssertEqual(sections.badgeCount, 1)
    }
}

final class SettingsNormalizationTests: XCTestCase {

    func testAcceptsPlainOwnerRepo() {
        XCTAssertEqual(SettingsStore.normalizeRepo("testorg/platform"), "testorg/platform")
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(SettingsStore.normalizeRepo("  testorg/platform \n"), "testorg/platform")
    }

    func testAcceptsFullHTTPSURL() {
        XCTAssertEqual(
            SettingsStore.normalizeRepo("https://github.com/testorg/platform"),
            "testorg/platform"
        )
    }

    func testAcceptsURLWithTrailingSlash() {
        XCTAssertEqual(
            SettingsStore.normalizeRepo("https://github.com/testorg/platform/"),
            "testorg/platform"
        )
    }

    func testAcceptsSSHRemote() {
        XCTAssertEqual(
            SettingsStore.normalizeRepo("git@github.com:testorg/platform.git"),
            "testorg/platform"
        )
    }

    func testRejectsBareName() {
        XCTAssertNil(SettingsStore.normalizeRepo("platform"))
    }

    func testRejectsTooManySegments() {
        XCTAssertNil(SettingsStore.normalizeRepo("testorg/platform/tree/main"))
    }

    func testRejectsEmpty() {
        XCTAssertNil(SettingsStore.normalizeRepo("   "))
    }

    func testRejectsIllegalCharacters() {
        XCTAssertNil(SettingsStore.normalizeRepo("testorg/plat form"))
        XCTAssertNil(SettingsStore.normalizeRepo("testorg/plat$form"))
    }

    func testIntervalLabels() {
        XCTAssertEqual(SettingsStore.intervalLabel(60), "1 minute")
        XCTAssertEqual(SettingsStore.intervalLabel(300), "5 minutes")
    }

    func testStalenessUnitSeconds() {
        XCTAssertEqual(StalenessUnit.hours.seconds, 3_600)
        XCTAssertEqual(StalenessUnit.days.seconds, 86_400)
        XCTAssertEqual(StalenessUnit.weeks.seconds, 604_800)
    }

    func testCutoffComputation() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cutoff = SettingsStore.cutoff(now: now, amount: 2, unit: .days)
        XCTAssertEqual(cutoff.timeIntervalSince1970, 1_000_000 - 2 * 86_400, accuracy: 0.001)
    }

    func testCutoffFloorsAmountAtOne() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cutoff = SettingsStore.cutoff(now: now, amount: 0, unit: .days)
        XCTAssertEqual(cutoff.timeIntervalSince1970, 1_000_000 - 86_400, accuracy: 0.001)
    }
}
