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
}
