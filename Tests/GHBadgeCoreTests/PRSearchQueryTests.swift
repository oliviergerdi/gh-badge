import XCTest

@testable import GHBadgeCore

final class PRSearchQueryBuildTests: XCTestCase {
    func testCoversAllThreeSectionsInOneDocument() {
        let query = PRSearchQuery.build(login: "alice", teams: [])
        XCTAssertTrue(query.contains("needsReview: search("))
        XCTAssertTrue(query.contains("reviewedBy: search("))
        XCTAssertTrue(query.contains("authored: search("))
        XCTAssertTrue(query.contains("review-requested:alice"))
        XCTAssertTrue(query.contains("reviewed-by:alice"))
        XCTAssertTrue(query.contains("author:alice"))
    }

    /// The point of the whole change: one request, whatever the configuration.
    /// Each `search(` is a field in the *same* document, not a separate call.
    func testTeamsBecomeExtraAliasesNotExtraRequests() {
        let query = PRSearchQuery.build(login: "alice", teams: ["acme/platform", "acme/web"])
        XCTAssertTrue(query.contains("team0: search("))
        XCTAssertTrue(query.contains("team1: search("))
        XCTAssertTrue(query.contains("review-requested:acme/platform"))
        XCTAssertTrue(query.contains("review-requested:acme/web"))
        XCTAssertEqual(query.components(separatedBy: "query {").count - 1, 1)
    }

    /// Revision data rides along on nodes the search already returns, which is
    /// what removes the separate revision round-trip and the per-PR fallback
    /// storm behind it.
    func testRequestsRevisionFieldsInline() {
        let query = PRSearchQuery.build(login: "alice", teams: [])
        XCTAssertTrue(query.contains("headRefOid"))
        XCTAssertTrue(query.contains("headRefName"))
        XCTAssertTrue(query.contains("viewerLatestReview { commit { oid } }"))
    }

    /// No `repo:` qualifiers: whitelist filtering stays local, so adding repos
    /// can never grow the query or the request count. That coupling is what
    /// produced the "breaks past four repos" behaviour.
    func testQueryIsIndependentOfTheRepoWhitelist() {
        let query = PRSearchQuery.build(login: "alice", teams: [])
        XCTAssertFalse(query.contains("repo:"))
    }

    func testAsksOnlyForOpenPullRequests() {
        let query = PRSearchQuery.build(login: "alice", teams: [])
        XCTAssertFalse(query.contains("search(query: \"review-requested"))
        XCTAssertEqual(query.components(separatedBy: "is:pr is:open").count - 1, 3)
    }

    func testPageSizeIsClampedToGitHubsCeiling() {
        let query = PRSearchQuery.build(login: "alice", teams: [], pageSize: 5_000)
        XCTAssertTrue(query.contains("first: \(PRSearchQuery.maxPageSize)"))
        XCTAssertFalse(query.contains("first: 5000"))
    }

    func testQuotesInALoginCannotBreakOutOfTheQueryString() {
        let query = PRSearchQuery.build(login: "ali\"ce", teams: [])
        XCTAssertTrue(query.contains(#"review-requested:ali\"ce"#))
    }
}

final class PRSearchQueryParseTests: XCTestCase {
    private func node(
        number: Int,
        repo: String = "acme/api",
        title: String = "Title",
        author: String = "bob",
        isDraft: Bool = false,
        headRefName: String? = "feature",
        headRefOid: String? = "aaa",
        reviewedOid: String? = nil
    ) -> String {
        var fields: [String] = [
            "\"number\": \(number)",
            "\"title\": \"\(title)\"",
            "\"url\": \"https://github.com/\(repo)/pull/\(number)\"",
            "\"updatedAt\": \"2024-01-01T00:00:00Z\"",
            "\"state\": \"OPEN\"",
            "\"isDraft\": \(isDraft)",
            "\"author\": {\"login\": \"\(author)\"}",
            "\"repository\": {\"nameWithOwner\": \"\(repo)\"}",
        ]
        if let headRefName { fields.append("\"headRefName\": \"\(headRefName)\"") }
        if let headRefOid { fields.append("\"headRefOid\": \"\(headRefOid)\"") }
        fields.append(
            reviewedOid.map { "\"viewerLatestReview\": {\"commit\": {\"oid\": \"\($0)\"}}" }
                ?? "\"viewerLatestReview\": null"
        )
        return "{\(fields.joined(separator: ","))}"
    }

    private func response(
        needsReview: [String] = [],
        reviewedBy: [String] = [],
        authored: [String] = [],
        teams: [[String]] = [],
        counts: [String: Int] = [:]
    ) -> Data {
        func bucket(_ alias: String, _ nodes: [String]) -> String {
            "\"\(alias)\": {\"issueCount\": \(counts[alias] ?? nodes.count), \"nodes\": [\(nodes.joined(separator: ","))]}"
        }
        var buckets = [
            bucket("needsReview", needsReview),
            bucket("reviewedBy", reviewedBy),
            bucket("authored", authored),
        ]
        for (index, nodes) in teams.enumerated() {
            buckets.append(bucket("team\(index)", nodes))
        }
        return Data("{\"data\":{\(buckets.joined(separator: ","))}}".utf8)
    }

    func testSplitsBucketsIntoTheThreeSections() {
        let parsed = PRSearchQuery.parse(
            response(
                needsReview: [node(number: 1)],
                reviewedBy: [node(number: 2)],
                authored: [node(number: 3)]
            )
        )
        XCTAssertEqual(parsed?.needsReview.map(\.number), [1])
        XCTAssertEqual(parsed?.reviewedBy.map(\.number), [2])
        XCTAssertEqual(parsed?.authored.map(\.number), [3])
    }

    func testDecodesTheGraphQLNodeShapeIntoPullRequest() {
        let parsed = PRSearchQuery.parse(response(needsReview: [node(number: 7, author: "carol")]))
        let pr = parsed?.needsReview.first
        XCTAssertEqual(pr?.repo, "acme/api")
        XCTAssertEqual(pr?.number, 7)
        XCTAssertEqual(pr?.authorLogin, "carol")
        // GraphQL sends `OPEN`; the shared decoder lowercases it, so sectioning
        // sees the same value it always did from `gh search prs`.
        XCTAssertEqual(pr?.state, "open")
        XCTAssertNotNil(pr?.updatedAt)
    }

    func testTeamBucketsMergeIntoNeedsReviewAndDeduplicate() {
        let shared = node(number: 10)
        let parsed = PRSearchQuery.parse(
            response(needsReview: [shared, node(number: 11)], teams: [[shared, node(number: 12)]])
        )
        XCTAssertEqual(parsed?.needsReview.map(\.number).sorted(), [10, 11, 12])
    }

    func testStaleReviewDetectedWhenHeadMovedPastTheReview() {
        let parsed = PRSearchQuery.parse(
            response(reviewedBy: [node(number: 1, headRefOid: "new", reviewedOid: "old")])
        )
        XCTAssertEqual(
            parsed?.revisionInfo.staleReviewURLs,
            ["https://github.com/acme/api/pull/1"]
        )
    }

    func testReviewAtTheCurrentHeadIsNotStale() {
        let parsed = PRSearchQuery.parse(
            response(reviewedBy: [node(number: 1, headRefOid: "same", reviewedOid: "same")])
        )
        XCTAssertTrue(parsed?.revisionInfo.staleReviewURLs.isEmpty ?? false)
    }

    /// "Can't prove it, don't move it": an absent review must not promote a PR
    /// back into Needs My Review.
    func testMissingReviewIsNotStale() {
        let parsed = PRSearchQuery.parse(response(reviewedBy: [node(number: 1, reviewedOid: nil)]))
        XCTAssertTrue(parsed?.revisionInfo.staleReviewURLs.isEmpty ?? false)
    }

    func testBranchNamesAreCollectedPerURL() {
        let parsed = PRSearchQuery.parse(
            response(needsReview: [node(number: 1, headRefName: "fix/thing")])
        )
        XCTAssertEqual(
            parsed?.revisionInfo.branchNames["https://github.com/acme/api/pull/1"],
            "fix/thing"
        )
    }

    /// Regression guard: revision fields are harvested in the same pass that
    /// decodes each node. Zipping a filtered array of decoded PRs back against
    /// the raw nodes would attach this branch name to the wrong PR as soon as
    /// an earlier node failed to decode.
    func testUndecodableNodeDoesNotShiftLaterBranchNames() {
        let broken = "{\"notAPullRequest\": true}"
        let good = node(number: 5, headRefName: "correct-branch")
        let parsed = PRSearchQuery.parse(
            Data("{\"data\":{\"needsReview\":{\"issueCount\":2,\"nodes\":[\(broken),\(good)]}}}".utf8)
        )
        XCTAssertEqual(parsed?.needsReview.map(\.number), [5])
        XCTAssertEqual(
            parsed?.revisionInfo.branchNames["https://github.com/acme/api/pull/5"],
            "correct-branch"
        )
        XCTAssertEqual(parsed?.revisionInfo.branchNames.count, 1)
    }

    func testTruncationIsReportedWhenIssueCountExceedsThePage() {
        let parsed = PRSearchQuery.parse(
            response(needsReview: [node(number: 1)], counts: ["needsReview": 250]),
            pageSize: 100
        )
        XCTAssertEqual(parsed?.truncatedBuckets, ["needsReview"])
    }

    func testNoTruncationReportedForASmallResultSet() {
        let parsed = PRSearchQuery.parse(response(needsReview: [node(number: 1)]))
        XCTAssertTrue(parsed?.truncatedBuckets.isEmpty ?? false)
    }

    /// A missing bucket is partial success, not failure: the caller keeps its
    /// cached value for that section rather than falling back to the REST path.
    func testMissingBucketYieldsEmptyRatherThanNil() {
        let parsed = PRSearchQuery.parse(Data("{\"data\":{\"authored\":{\"nodes\":[]}}}".utf8))
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.needsReview.count, 0)
    }

    /// nil is reserved for "unusable response", which is the signal to fall
    /// back to `gh search prs`.
    func testGarbageResponseReturnsNil() {
        XCTAssertNil(PRSearchQuery.parse(Data("not json".utf8)))
        XCTAssertNil(PRSearchQuery.parse(Data(#"{"errors":[{"message":"boom"}]}"#.utf8)))
    }
}
