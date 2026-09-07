import Foundation

/// Pure backoff-delay math for retrying `gh` calls, deliberately separated out
/// (same reasoning as `PRSectioning`/`StaleReviewQuery`) so it's testable
/// without a main actor, a network, or a `gh` binary.
///
/// Two distinct problems, two policies:
///   - `delay(failureCount:normalInterval:)`: a transient failure (a network
///     blip, a timeout, `gh` briefly erroring) used to mean waiting out the
///     full, user-configured refresh interval — often minutes — before the
///     badge would recover on its own, forcing a manual click to see current
///     data sooner. `PRStore`'s poll loop uses this to retry the *whole*
///     refresh cycle sooner instead.
///   - `jobRetryDelay(attempt:)`: a single flaky `gh search prs` invocation
///     (e.g. one team's `--review-requested` query hitting "connection closed
///     by peer" while sibling jobs in the same batch succeed) used to leave a
///     stuck-looking error banner: `PRSectioning`'s "partial success is still
///     useful" design means the fresh data from the sibling jobs shows up
///     fine, but the one failing job's error persists every cycle it keeps
///     failing on, which can look like a hung refresh even though most of
///     the picture is current. Retrying that one job a couple of times
///     in-place, within the same cycle, fixes a one-off blip before it ever
///     reaches `PRStore`'s error state.
public enum RetryBackoff {
    /// Delay before the first automatic retry after a transient failure.
    public static let initialDelay: TimeInterval = 5

    /// Ceiling on the backoff delay, independent of how many failures have
    /// piled up.
    public static let maxDelay: TimeInterval = 120

    /// The delay before the next poll, given how many *consecutive* transient
    /// failures just occurred.
    ///
    /// - Parameters:
    ///   - failureCount: Consecutive transient failures so far. `0` (no
    ///     failure, or a fatal-configuration failure that backing off can't
    ///     fix — see `GHError.isFatalConfiguration`) means "nothing to back
    ///     off from", so the normal interval applies.
    ///   - normalInterval: The user's configured refresh interval. The
    ///     backoff delay never exceeds this — retrying slower than the
    ///     normal cadence would defeat the point of backing off at all.
    public static func delay(failureCount: Int, normalInterval: TimeInterval) -> TimeInterval {
        guard failureCount > 0 else { return normalInterval }
        // Capped exponent: 2^8 already pushes `initialDelay` past `maxDelay`,
        // so higher counts can't overflow or grow the value further.
        let exponent = min(failureCount - 1, 8)
        let backoff = initialDelay * pow(2, Double(exponent))
        return min(backoff, maxDelay, normalInterval)
    }

    /// Total attempts for a single `gh` invocation (the first try plus this
    /// many retries) before its failure is surfaced to the rest of the
    /// refresh cycle.
    public static let maxJobAttempts = 3

    /// Delay before retrying one failed `gh` invocation, given the attempt
    /// number just made (1 = the first, original attempt). Deliberately much
    /// shorter than `delay(...)`: this papers over a single flaky subprocess
    /// call within one refresh cycle, not the whole poll cycle, so it should
    /// add at most a couple of seconds of latency, not minutes.
    public static func jobRetryDelay(attempt: Int) -> TimeInterval {
        min(0.5 * pow(2, Double(max(attempt - 1, 0))), 2)
    }
}
