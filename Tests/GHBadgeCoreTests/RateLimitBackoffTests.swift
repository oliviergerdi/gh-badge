import XCTest

@testable import GHBadgeCore

final class RateLimitBackoffTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testHonoursGitHubsResetTime() {
        let end = RetryBackoff.rateLimitCooldownEnd(
            resetAt: now.addingTimeInterval(600),
            now: now
        )
        XCTAssertEqual(end, now.addingTimeInterval(600))
    }

    /// A reset timestamp already in the past — clock skew, or a header read a
    /// moment too late — must not mean "retry immediately", which is exactly
    /// how a secondary limit gets re-tripped the instant it lifts.
    func testAPastResetStillWaitsTheMinimum() {
        let end = RetryBackoff.rateLimitCooldownEnd(
            resetAt: now.addingTimeInterval(-500),
            now: now
        )
        XCTAssertEqual(end, now.addingTimeInterval(RetryBackoff.minRateLimitCooldown))
    }

    func testAnAbsurdResetIsCappedAnHourOut() {
        let end = RetryBackoff.rateLimitCooldownEnd(
            resetAt: now.addingTimeInterval(86_400),
            now: now
        )
        XCTAssertEqual(end, now.addingTimeInterval(RetryBackoff.maxRateLimitCooldown))
    }

    /// The secondary limit publishes no reset, so repeated refusals have to
    /// escalate on their own rather than re-probing on the same cadence that
    /// just failed.
    func testBlindWaitsDoubleWithEachConsecutiveRefusal() {
        func wait(_ count: Int) -> TimeInterval {
            RetryBackoff.rateLimitCooldownEnd(resetAt: nil, consecutiveRateLimits: count, now: now)
                .timeIntervalSince(now)
        }
        XCTAssertEqual(wait(1), RetryBackoff.rateLimitFallbackCooldown)
        XCTAssertEqual(wait(2), RetryBackoff.rateLimitFallbackCooldown * 2)
        XCTAssertEqual(wait(3), RetryBackoff.rateLimitFallbackCooldown * 4)
        XCTAssertEqual(wait(99), RetryBackoff.maxRateLimitCooldown)
    }

    /// Unlike the transient-failure backoff, a cooldown is *not* clamped to the
    /// refresh interval. Polling every 60s through a 15-minute limit keeps the
    /// limit alive instead of waiting it out.
    func testCooldownIsNotCappedByTheRefreshInterval() {
        let end = now.addingTimeInterval(900)
        XCTAssertEqual(RetryBackoff.delayUntilCooldownEnd(end, now: now), 900)
    }

    func testCooldownDelayNeverGoesToZero() {
        XCTAssertEqual(RetryBackoff.delayUntilCooldownEnd(now.addingTimeInterval(-10), now: now), 1)
    }

    func testJitterOnlyEverAddsTime() {
        // Waking early would waste a reset time we were explicitly told.
        XCTAssertEqual(RetryBackoff.jittered(100, fraction: 0.1, randomUnit: 0), 100)
        XCTAssertEqual(RetryBackoff.jittered(100, fraction: 0.1, randomUnit: 1), 110)
        XCTAssertEqual(RetryBackoff.jittered(100, fraction: 0.1, randomUnit: 0.5), 105)
    }

    func testJitterLeavesAZeroDelayAlone() {
        XCTAssertEqual(RetryBackoff.jittered(0, randomUnit: 1), 0)
    }
}
