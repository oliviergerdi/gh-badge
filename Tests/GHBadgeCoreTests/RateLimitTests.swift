import XCTest

@testable import GHBadgeCore

final class RateLimitDetectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func detect(
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0
    ) -> RateLimitInfo? {
        RateLimitDetector.detect(
            stdout: Data(stdout.utf8),
            stderr: stderr,
            exitCode: exitCode,
            now: now
        )
    }

    // MARK: - Negatives

    func testCleanSuccessIsNotRateLimited() {
        let body = #"{"data":{"needsReview":{"issueCount":2,"nodes":[]}}}"#
        XCTAssertNil(detect(stdout: body))
    }

    /// The regression this guards is embarrassing but real: matching
    /// rate-limit wording anywhere in the response body means a PR *titled*
    /// "handle secondary rate limit" convinces the app it has been throttled,
    /// and the app then refuses to refresh for a minute — every cycle, forever,
    /// as long as that PR is open.
    func testPRTitleMentioningRateLimitIsNotRateLimited() {
        let body = """
        {"data":{"needsReview":{"issueCount":1,"nodes":[
          {"url":"https://github.com/o/r/pull/1","number":1,
           "title":"Handle secondary rate limit and back off",
           "repository":{"nameWithOwner":"o/r"}}
        ]}}}
        """
        XCTAssertNil(detect(stdout: body))
    }

    /// 403 on its own is ordinary "you can't see that repo".
    func testPlainForbiddenIsNotRateLimited() {
        XCTAssertNil(
            detect(stderr: "gh: Must have admin rights to Repository. (HTTP 403)", exitCode: 1)
        )
    }

    func testUnrelatedGraphQLErrorIsNotRateLimited() {
        let body = #"{"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a Repository"}]}"#
        XCTAssertNil(detect(stdout: body, exitCode: 1))
    }

    // MARK: - Positives

    func testRESTPrimaryLimitOnStderr() {
        let info = detect(
            stderr: "gh: API rate limit exceeded for user ID 1234. (HTTP 403)",
            exitCode: 1
        )
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.isSecondary, false)
    }

    func testSecondaryLimitIsFlagged() {
        let info = detect(
            stderr: "gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403)",
            exitCode: 1
        )
        XCTAssertEqual(info?.isSecondary, true)
    }

    /// The trap case: GraphQL reports an exhausted budget with **HTTP 200** and
    /// exit code 0. Read naively this looks like a successful query that
    /// returned no data, which is how a rate limit turns into a silently empty
    /// badge instead of a banner.
    func testGraphQLRateLimitedArrivesAsSuccessfulExit() {
        let body = #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#
        let info = detect(stdout: body, exitCode: 0)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.isSecondary, false)
    }

    func testTooManyRequestsStatusIsEnough() {
        let stdout = "HTTP/2.0 429 Too Many Requests\r\ncontent-type: application/json\r\n\r\n{}"
        let info = detect(stdout: stdout, exitCode: 1)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.isSecondary, true)
    }

    // MARK: - Reset timing

    func testRetryAfterIsTreatedAsADelta() {
        let stdout = """
        HTTP/2.0 403 Forbidden\r
        retry-after: 90\r
        \r
        {"message":"You have exceeded a secondary rate limit"}
        """
        let info = detect(stdout: stdout, exitCode: 1)
        XCTAssertEqual(info?.resetAt, now.addingTimeInterval(90))
    }

    func testRateLimitResetIsTreatedAsAnEpoch() {
        let reset = now.addingTimeInterval(600).timeIntervalSince1970
        let stdout = """
        HTTP/2.0 403 Forbidden\r
        x-ratelimit-remaining: 0\r
        x-ratelimit-reset: \(Int(reset))\r
        \r
        {"message":"API rate limit exceeded"}
        """
        let info = detect(stdout: stdout, exitCode: 1)
        XCTAssertEqual(info?.resetAt, Date(timeIntervalSince1970: reset))
    }

    func testRetryAfterWinsOverRateLimitReset() {
        let stdout = """
        HTTP/2.0 403 Forbidden\r
        retry-after: 30\r
        x-ratelimit-reset: \(Int(now.addingTimeInterval(3600).timeIntervalSince1970))\r
        \r
        {"message":"You have exceeded a secondary rate limit"}
        """
        XCTAssertEqual(detect(stdout: stdout, exitCode: 1)?.resetAt, now.addingTimeInterval(30))
    }

    /// With no headers (a `gh` that doesn't support `-i`), GraphQL's own
    /// `rateLimit.resetAt` is the last usable source.
    func testFallsBackToGraphQLResetAt() {
        let body = """
        {"data":{"rateLimit":{"limit":5000,"cost":1,"remaining":0,"resetAt":"2023-11-14T22:13:20Z"}},
         "errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}
        """
        XCTAssertEqual(
            detect(stdout: body, exitCode: 0)?.resetAt,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testNoResetInformationLeavesResetNil() {
        let info = detect(
            stderr: "gh: You have exceeded a secondary rate limit.",
            exitCode: 1
        )
        XCTAssertNotNil(info)
        XCTAssertNil(info?.resetAt)
    }

    // MARK: - Response splitting

    func testSplitsHeadersFromBody() {
        let raw = Data("HTTP/2.0 200 OK\r\nx-ratelimit-remaining: 4999\r\n\r\n{\"data\":{}}".utf8)
        let split = RateLimitDetector.splitHTTPResponse(raw)
        XCTAssertEqual(split?.headers["x-ratelimit-remaining"], "4999")
        XCTAssertEqual(split?.headers[RateLimitDetector.statusPseudoHeader], "200")
        XCTAssertEqual(split.map { String(data: $0.body, encoding: .utf8) }, #"{"data":{}}"#)
    }

    /// Without `-i` the payload is a bare body, which must pass through
    /// untouched rather than being mistaken for a malformed response.
    func testBareBodyIsNotSplit() {
        XCTAssertNil(RateLimitDetector.splitHTTPResponse(Data(#"{"data":{}}"#.utf8)))
    }

    /// A CRLF head followed by a body that itself contains a blank line: the
    /// *first* boundary is the real one.
    func testSplitUsesTheFirstBlankLine() {
        let raw = Data("HTTP/2.0 200 OK\r\nfoo: bar\r\n\r\nline\n\nline".utf8)
        let split = RateLimitDetector.splitHTTPResponse(raw)
        XCTAssertEqual(split.map { String(data: $0.body, encoding: .utf8) }, "line\n\nline")
    }
}
