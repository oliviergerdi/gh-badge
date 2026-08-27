import XCTest
@testable import GHBadgeCore

/// The `repository` value from `gh search prs --json repository` is confirmed
/// (live `gh` 2.97/2.98) to be an object with `name` and `nameWithOwner`. The
/// decoder matches that shape exactly and fails loudly on anything else.
final class PullRequestDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> [PullRequest] {
        try JSONDecoder().decode([PullRequest].self, from: Data(json.utf8))
    }

    // MARK: - repository shape

    func testDecodesConfirmedRepositoryShape() throws {
        let json = """
        [{
          "number": 42,
          "repository": { "name": "cli", "nameWithOwner": "cli/cli" },
          "state": "open",
          "title": "Fix the thing",
          "updatedAt": "2026-08-20T09:14:03Z",
          "url": "https://github.com/cli/cli/pull/42"
        }]
        """
        let prs = try decode(json)
        XCTAssertEqual(prs.count, 1)
        XCTAssertEqual(prs[0].repo, "cli/cli")
        XCTAssertEqual(prs[0].number, 42)
        XCTAssertEqual(prs[0].title, "Fix the thing")
        XCTAssertEqual(prs[0].state, "open")
        XCTAssertEqual(prs[0].repoShortName, "cli")
        XCTAssertEqual(prs[0].owner, "cli")
        XCTAssertNotNil(prs[0].updatedAt)
    }

    /// A missing `repository` must fail loudly, not silently render "unknown".
    func testMissingRepositoryThrows() {
        let json = """
        [{ "number": 1, "title": "No repo", "url": "https://github.com/a/b/pull/1" }]
        """
        XCTAssertThrowsError(try decode(json))
    }

    /// A flattened `repository` string is the realistic "gh changed shape" case;
    /// it must fail rather than degrade to garbage.
    func testFlattenedRepositoryThrows() {
        let json = """
        [{ "number": 1, "repository": "a/b", "url": "https://github.com/a/b/pull/1" }]
        """
        XCTAssertThrowsError(try decode(json))
    }

    // MARK: - misc

    func testEmptyArrayDecodes() throws {
        XCTAssertTrue(try decode("[]").isEmpty)
    }

    func testMissingTitleDoesNotThrow() throws {
        let json = """
        [{
          "number": 1,
          "repository": { "nameWithOwner": "a/b" },
          "url": "https://github.com/a/b/pull/1"
        }]
        """
        XCTAssertEqual(try decode(json)[0].title, "(untitled)")
    }

    func testStateIsLowercased() throws {
        let json = """
        [{
          "number": 1,
          "repository": { "nameWithOwner": "a/b" },
          "state": "OPEN",
          "url": "https://github.com/a/b/pull/1"
        }]
        """
        XCTAssertEqual(try decode(json)[0].state, "open")
    }

    func testParsesFractionalSecondTimestamps() {
        XCTAssertNotNil(PullRequest.parseTimestamp("2026-08-20T09:14:03Z"))
        XCTAssertNotNil(PullRequest.parseTimestamp("2026-08-20T09:14:03.123Z"))
        XCTAssertNil(PullRequest.parseTimestamp("not a date"))
    }

    func testIdentityIsTheURL() throws {
        let json = """
        [{
          "number": 1,
          "repository": { "nameWithOwner": "a/b" },
          "url": "https://github.com/a/b/pull/1"
        }]
        """
        XCTAssertEqual(try decode(json)[0].id, "https://github.com/a/b/pull/1")
    }

    func testRoundTripsThroughEncoding() throws {
        let original = PullRequest(
            repo: "a/b",
            number: 5,
            title: "Round trip",
            url: "https://github.com/a/b/pull/5",
            updatedAt: Date(timeIntervalSince1970: 1_756_000_000),
            state: "open"
        )
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([PullRequest].self, from: data)
        XCTAssertEqual(decoded.first, original)
    }

    // MARK: - author

    /// Confirmed live (`gh search prs --json author`, gh 2.98.0): an object
    /// with `login`, `id`, `is_bot`, `type`, `url`. Only `login` is consumed.
    func testDecodesAuthorLogin() throws {
        let json = """
        [{
          "number": 1,
          "repository": { "nameWithOwner": "a/b" },
          "url": "https://github.com/a/b/pull/1",
          "author": { "login": "dependabot[bot]", "is_bot": true }
        }]
        """
        XCTAssertEqual(try decode(json)[0].authorLogin, "dependabot[bot]")
    }

    /// Fixtures (and any real payload predating this field) omit `author`
    /// entirely; decoding must not throw or fabricate a value.
    func testMissingAuthorDecodesToNil() throws {
        let json = """
        [{
          "number": 1,
          "repository": { "nameWithOwner": "a/b" },
          "url": "https://github.com/a/b/pull/1"
        }]
        """
        XCTAssertNil(try decode(json)[0].authorLogin)
    }

    func testAuthorRoundTripsThroughEncoding() throws {
        let original = PullRequest(
            repo: "a/b",
            number: 5,
            title: "Round trip",
            url: "https://github.com/a/b/pull/5",
            authorLogin: "dependabot[bot]"
        )
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([PullRequest].self, from: data)
        XCTAssertEqual(decoded.first?.authorLogin, "dependabot[bot]")
    }

    // MARK: - stderr condensing

    func testCondenseDropsUpdateNotifierNoise() {
        let stderr = """
        A new release of gh is available: 2.97.0 → 2.98.0
        To upgrade, run: brew upgrade gh
        https://github.com/cli/cli/releases/tag/v2.98.0
        """
        XCTAssertEqual(GHClient.condense(stderr), "")
    }

    func testCondenseKeepsTheRealError() {
        let stderr = """
        error connecting to api.github.com
        A new release of gh is available: 2.97.0 → 2.98.0
        """
        XCTAssertEqual(GHClient.condense(stderr), "error connecting to api.github.com")
    }

    // MARK: - StaleReviewQuery.build

    func testBuildOneAliasPerPR() {
        let prs = [
            PullRequest(repo: "a/b", number: 1, title: "x", url: "u1"),
            PullRequest(repo: "c/d", number: 2, title: "y", url: "u2"),
        ]
        let query = StaleReviewQuery.build(for: prs)
        XCTAssertTrue(query.contains(#"r0: repository(owner: "a", name: "b")"#))
        XCTAssertTrue(query.contains("pullRequest(number: 1)"))
        XCTAssertTrue(query.contains(#"r1: repository(owner: "c", name: "d")"#))
        XCTAssertTrue(query.contains("pullRequest(number: 2)"))
    }

    func testBuildEscapesQuotesInRepoName() {
        let prs = [PullRequest(repo: #"a"b/c"#, number: 1, title: "x", url: "u1")]
        let query = StaleReviewQuery.build(for: prs)
        XCTAssertTrue(query.contains(#"owner: "a\"b""#))
    }

    // MARK: - StaleReviewQuery.parse (batched GraphQL)

    func testParseFlagsPRWhoseHeadMovedPastTheReview() throws {
        let pr = PullRequest(repo: "a/b", number: 1, title: "x", url: "https://github.com/a/b/pull/1")
        let json = """
        {"data":{"r0":{"pullRequest":{
          "headRefOid": "new-commit",
          "viewerLatestReview": { "commit": { "oid": "old-commit" } }
        }}}}
        """
        let stale = StaleReviewQuery.parse(Data(json.utf8), prs: [pr])
        XCTAssertEqual(stale, [pr.url])
    }

    func testParseDoesNotFlagPRAtTheReviewedCommit() throws {
        let pr = PullRequest(repo: "a/b", number: 1, title: "x", url: "https://github.com/a/b/pull/1")
        let json = """
        {"data":{"r0":{"pullRequest":{
          "headRefOid": "same-commit",
          "viewerLatestReview": { "commit": { "oid": "same-commit" } }
        }}}}
        """
        XCTAssertTrue(StaleReviewQuery.parse(Data(json.utf8), prs: [pr]).isEmpty)
    }

    /// No review from the viewer at all (e.g. a token/viewer mismatch) can't be
    /// proven stale, so it must not be flagged.
    func testParseTreatsMissingViewerReviewAsNotStale() throws {
        let pr = PullRequest(repo: "a/b", number: 1, title: "x", url: "https://github.com/a/b/pull/1")
        let json = """
        {"data":{"r0":{"pullRequest":{
          "headRefOid": "new-commit",
          "viewerLatestReview": null
        }}}}
        """
        XCTAssertTrue(StaleReviewQuery.parse(Data(json.utf8), prs: [pr]).isEmpty)
    }

    func testParseIsPositionalAcrossMultiplePRs() throws {
        let staleOne = PullRequest(repo: "a/b", number: 1, title: "x", url: "https://github.com/a/b/pull/1")
        let freshOne = PullRequest(repo: "c/d", number: 2, title: "y", url: "https://github.com/c/d/pull/2")
        let json = """
        {"data":{
          "r0":{"pullRequest":{"headRefOid":"new","viewerLatestReview":{"commit":{"oid":"old"}}}},
          "r1":{"pullRequest":{"headRefOid":"same","viewerLatestReview":{"commit":{"oid":"same"}}}}
        }}
        """
        let stale = StaleReviewQuery.parse(Data(json.utf8), prs: [staleOne, freshOne])
        XCTAssertEqual(stale, [staleOne.url])
    }

    func testParseToleratesTotallyMalformedResponse() {
        let pr = PullRequest(repo: "a/b", number: 1, title: "x", url: "https://github.com/a/b/pull/1")
        XCTAssertTrue(StaleReviewQuery.parse(Data("not json".utf8), prs: [pr]).isEmpty)
    }

    // MARK: - StaleReviewQuery.parsePerPRView (fallback path)

    func testParsePerPRViewFlagsHeadPastMyLatestReview() {
        let pr = PullRequest(repo: "a/b", number: 1, title: "x", url: "https://github.com/a/b/pull/1")
        let json = """
        {
          "headRefOid": "new-commit",
          "reviews": [
            { "author": { "login": "me" }, "submittedAt": "2026-01-01T00:00:00Z", "commit": { "oid": "old-commit" } }
          ]
        }
        """
        XCTAssertEqual(StaleReviewQuery.parsePerPRView(Data(json.utf8), pr: pr, viewerLogin: "me"), pr.url)
    }

    func testParsePerPRViewPicksTheLatestOfMyMultipleReviews() {
        let pr = PullRequest(repo: "a/b", number: 1, title: "x", url: "https://github.com/a/b/pull/1")
        let json = """
        {
          "headRefOid": "commit-2",
          "reviews": [
            { "author": { "login": "me" }, "submittedAt": "2026-01-01T00:00:00Z", "commit": { "oid": "commit-1" } },
            { "author": { "login": "me" }, "submittedAt": "2026-01-02T00:00:00Z", "commit": { "oid": "commit-2" } }
          ]
        }
        """
        XCTAssertNil(StaleReviewQuery.parsePerPRView(Data(json.utf8), pr: pr, viewerLogin: "me"))
    }

    func testParsePerPRViewIgnoresOtherReviewers() {
        let pr = PullRequest(repo: "a/b", number: 1, title: "x", url: "https://github.com/a/b/pull/1")
        let json = """
        {
          "headRefOid": "new-commit",
          "reviews": [
            { "author": { "login": "someone-else" }, "submittedAt": "2026-01-02T00:00:00Z", "commit": { "oid": "new-commit" } }
          ]
        }
        """
        XCTAssertNil(StaleReviewQuery.parsePerPRView(Data(json.utf8), pr: pr, viewerLogin: "me"))
    }
}
