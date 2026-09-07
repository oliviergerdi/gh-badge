import XCTest
@testable import GHBadgeCore

final class RetryBackoffTests: XCTestCase {

    func testNoFailureUsesNormalInterval() {
        XCTAssertEqual(RetryBackoff.delay(failureCount: 0, normalInterval: 300), 300)
    }

    func testFirstFailureUsesInitialDelay() {
        XCTAssertEqual(RetryBackoff.delay(failureCount: 1, normalInterval: 300), RetryBackoff.initialDelay)
    }

    func testDelayDoublesWithEachConsecutiveFailure() {
        XCTAssertEqual(RetryBackoff.delay(failureCount: 1, normalInterval: 1_000), 5)
        XCTAssertEqual(RetryBackoff.delay(failureCount: 2, normalInterval: 1_000), 10)
        XCTAssertEqual(RetryBackoff.delay(failureCount: 3, normalInterval: 1_000), 20)
        XCTAssertEqual(RetryBackoff.delay(failureCount: 4, normalInterval: 1_000), 40)
    }

    func testDelayIsCappedAtMaxDelay() {
        XCTAssertEqual(RetryBackoff.delay(failureCount: 10, normalInterval: 10_000), RetryBackoff.maxDelay)
        // A huge failure count must not overflow or exceed the cap either.
        XCTAssertEqual(RetryBackoff.delay(failureCount: 1_000, normalInterval: 10_000), RetryBackoff.maxDelay)
    }

    /// Backing off slower than the user's own configured interval would defeat
    /// the purpose: it should never be a worse experience than no backoff.
    func testDelayNeverExceedsNormalInterval() {
        XCTAssertEqual(RetryBackoff.delay(failureCount: 5, normalInterval: 60), 60)
    }

    func testDelayIsMonotonicNonDecreasingWithFailureCount() {
        let normalInterval: TimeInterval = 1_000
        var previous: TimeInterval = 0
        for count in 1...12 {
            let delay = RetryBackoff.delay(failureCount: count, normalInterval: normalInterval)
            XCTAssertGreaterThanOrEqual(delay, previous)
            previous = delay
        }
    }

    // MARK: - jobRetryDelay (single flaky `gh` invocation within one cycle)

    func testJobRetryDelayDoublesFromFirstAttempt() {
        XCTAssertEqual(RetryBackoff.jobRetryDelay(attempt: 1), 0.5)
        XCTAssertEqual(RetryBackoff.jobRetryDelay(attempt: 2), 1.0)
    }

    /// Deliberately short: this is patching over one flaky subprocess call
    /// within a single refresh cycle, not backing off the whole poll cycle.
    func testJobRetryDelayIsCappedAtTwoSeconds() {
        XCTAssertEqual(RetryBackoff.jobRetryDelay(attempt: 3), 2.0)
        XCTAssertEqual(RetryBackoff.jobRetryDelay(attempt: 20), 2.0)
    }

    func testJobRetryDelayHandlesNonPositiveAttempt() {
        XCTAssertEqual(RetryBackoff.jobRetryDelay(attempt: 0), 0.5)
    }
}
