import Foundation

/// What we learned about a rate limit from a single `gh` invocation.
///
/// `resetAt` is whatever GitHub actually told us (a `retry-after` delta or an
/// `x-ratelimit-reset` epoch, or GraphQL's `rateLimit.resetAt`). It is optional
/// because not every rate-limit response carries a usable one — `gh` only
/// surfaces response headers when asked with `-i`, and the secondary-limit body
/// often says nothing more precise than "retry your request again later".
/// Callers fall back to `RetryBackoff.rateLimitFallbackCooldown` in that case.
public struct RateLimitInfo: Equatable, Sendable {
    public var resetAt: Date?
    /// GitHub has two distinct mechanisms and they behave differently:
    ///
    ///   - **Primary**: a fixed hourly budget (5,000 REST points/hr, 5,000
    ///     GraphQL points/hr, 30 search requests/min). Resets on a schedule
    ///     that `x-ratelimit-reset` states exactly.
    ///   - **Secondary**: an abuse heuristic tripped by *concurrency* and
    ///     burstiness rather than volume. No published reset; the only cure is
    ///     to stop making requests for a while.
    ///
    /// Worth distinguishing because the secondary limit is the one this app
    /// actually trips (see `GHClient.revisionInfoPerPR`'s unbounded fan-out
    /// before it was capped), and its remedy — fewer requests in flight — is
    /// not the same as waiting for an hourly window to roll over.
    public var isSecondary: Bool

    public init(resetAt: Date? = nil, isSecondary: Bool = false) {
        self.resetAt = resetAt
        self.isSecondary = isSecondary
    }
}

/// Pure detection of GitHub rate limiting from a `gh` invocation's output,
/// separated from `GHClient` (same reasoning as `PRSectioning` and
/// `RetryBackoff`) so every branch is testable without a network or a `gh`
/// binary.
///
/// Detection has to be text-based because `gh` is a CLI, not a client library:
/// there is no typed error to switch on, only an exit code, some stderr, and —
/// when invoked with `-i` — the raw response head. All three are consulted,
/// because which one carries the signal depends on how GitHub refused:
///
///   - REST primary/secondary limits: HTTP 403 or 429, message on stderr.
///   - GraphQL primary limit: **HTTP 200** with `errors[].type == "RATE_LIMITED"`
///     in the body. This is the trap — exit code 0, nothing on stderr, and the
///     naive reading is "the query succeeded and returned no data".
public enum RateLimitDetector {
    /// Phrases GitHub and `gh` use for the two limit kinds. Matched
    /// case-insensitively against stderr and response bodies.
    private static let secondaryPhrases = [
        "secondary rate limit",
        "exceeded a secondary rate limit",
        "abuse detection",
    ]

    /// Deliberately no bare `"rate limit"` entry: paired with the
    /// `mentionsLimit && exitCode != 0` arm below, that would turn any failing
    /// call whose message merely mentions the phrase into a cooldown.
    private static let primaryPhrases = [
        "api rate limit exceeded",
        "rate limit exceeded",
        "exceeded a rate limit",
    ]

    /// Inspects one `gh` result. Returns nil when there is no sign of rate
    /// limiting — which is the overwhelmingly common case, so this stays cheap.
    ///
    /// - Parameters:
    ///   - stdout: raw stdout. May be a bare body, or a full HTTP response head
    ///     plus body when the call used `-i`.
    ///   - stderr: raw stderr, already trimmed by `ProcessRunner`.
    ///   - exitCode: the process exit status.
    ///   - now: injectable for tests; `retry-after` is a *delta*, so the
    ///     resulting date depends on it.
    public static func detect(
        stdout: Data,
        stderr: String,
        exitCode: Int32,
        now: Date = Date()
    ) -> RateLimitInfo? {
        // Fast path for the overwhelmingly common case. A clean exit with
        // nothing on stderr and no `"errors"` key anywhere in the payload
        // cannot be a refusal, and skipping it avoids a second full JSON parse
        // of a response `PRSearchQuery` is about to parse properly.
        if exitCode == 0, stderr.isEmpty, stdout.range(of: Data("\"errors\"".utf8)) == nil {
            return nil
        }

        let split = splitHTTPResponse(stdout)
        let headers = split?.headers ?? [:]
        let body = split?.body ?? stdout

        // A GraphQL rate limit arrives as a *successful* HTTP response whose
        // body carries the refusal, so the body is inspected even on exit 0.
        let graphQLErrors = graphQLErrorEntries(body)
        let graphQLRateLimited = graphQLErrors.contains {
            ($0["type"] as? String)?.uppercased() == "RATE_LIMITED"
        }

        // Only GitHub-authored text is searched — stderr and the `message`
        // fields of error objects. Never the whole body: a successful response
        // carries PR *titles*, and a PR called "handle secondary rate limit"
        // would otherwise convince us we had been throttled.
        var messages = [stderr]
        messages.append(contentsOf: graphQLErrors.compactMap { $0["message"] as? String })
        if let restMessage = restErrorMessage(body) { messages.append(restMessage) }
        let haystack = messages.joined(separator: "\n").lowercased()

        let mentionsLimit = primaryPhrases.contains { haystack.contains($0) }
        let mentionsSecondary = secondaryPhrases.contains { haystack.contains($0) }

        // 429 is unambiguous. 403 is not — it is also plain "you can't see this
        // repo" — so it only counts alongside rate-limit wording.
        let status = statusCode(from: headers, stderr: stderr)
        let is429 = status == 429
        let is403WithLimitWording = status == 403 && mentionsLimit

        guard graphQLRateLimited || mentionsSecondary || is429 || is403WithLimitWording
            || (mentionsLimit && exitCode != 0)
        else { return nil }

        return RateLimitInfo(
            resetAt: resetDate(headers: headers, body: body, now: now),
            isSecondary: mentionsSecondary || (is429 && !graphQLRateLimited)
        )
    }

    /// GraphQL signals an exhausted budget with an error entry rather than an
    /// HTTP status, so these are read structurally: an unrelated error whose
    /// message happens to say "rate limit" still has to clear the other checks.
    private static func graphQLErrorEntries(_ body: Data) -> [[String: Any]] {
        guard
            let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let errors = root["errors"] as? [[String: Any]]
        else { return [] }
        return errors
    }

    /// REST refusals carry a top-level `message`, e.g.
    /// `{"message": "API rate limit exceeded for user ID …"}`.
    private static func restErrorMessage(_ body: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return root["message"] as? String
    }

    /// Best available reset time, most precise source first.
    static func resetDate(headers: [String: String], body: Data, now: Date) -> Date? {
        // `retry-after` is what GitHub sends for secondary limits, and it is a
        // delta in seconds, not a timestamp.
        if let retryAfter = headers["retry-after"], let seconds = TimeInterval(retryAfter) {
            return now.addingTimeInterval(seconds)
        }
        // `x-ratelimit-reset` is a UTC epoch, sent for primary limits.
        if let reset = headers["x-ratelimit-reset"], let epoch = TimeInterval(reset) {
            return Date(timeIntervalSince1970: epoch)
        }
        // GraphQL's own `rateLimit { resetAt }`, present whenever the query
        // asked for it — including on the response that reports exhaustion.
        if
            let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let data = root["data"] as? [String: Any],
            let rateLimit = data["rateLimit"] as? [String: Any],
            let resetAt = rateLimit["resetAt"] as? String,
            let date = PullRequest.parseTimestamp(resetAt)
        {
            return date
        }
        return nil
    }

    /// From the `-i` status line if present, otherwise from `gh`'s own
    /// "(HTTP 403)" suffix on stderr.
    static func statusCode(from headers: [String: String], stderr: String) -> Int? {
        if let status = headers[statusPseudoHeader], let code = Int(status) { return code }
        guard
            let range = stderr.range(of: "HTTP [0-9]{3}", options: .regularExpression)
        else { return nil }
        return Int(stderr[range].dropFirst(5))
    }

    /// Key under which `splitHTTPResponse` stashes the status line's code.
    /// Prefixed with a colon so it can never collide with a real header name.
    static let statusPseudoHeader = ":status"

    /// Splits `gh api -i` output into lowercased headers and the body.
    ///
    /// Returns nil when `stdout` is a bare body (no `-i`, or a `gh` old enough
    /// not to support it), which callers treat as "no headers, all body" rather
    /// than as an error — header data is an optimisation for pinpointing the
    /// reset time, never a requirement.
    public static func splitHTTPResponse(_ data: Data) -> (headers: [String: String], body: Data)? {
        guard data.starts(with: Array("HTTP/".utf8)) else { return nil }

        // CRLF per the spec, but be liberal: some proxies and `gh` versions
        // normalise line endings before printing. Whichever blank line comes
        // first is the real head/body boundary — a CRLF response can still
        // contain a bare "\n\n" further down, inside the body.
        let separators = [Data("\r\n\r\n".utf8), Data("\n\n".utf8)]
        guard
            let separator = separators
                .compactMap({ data.range(of: $0) })
                .min(by: { $0.lowerBound < $1.lowerBound })
        else { return nil }

        let headText = String(data: data[..<separator.lowerBound], encoding: .utf8) ?? ""
        let body = data[separator.upperBound...]

        var headers: [String: String] = [:]
        for (index, line) in headText.split(separator: "\n").enumerated() {
            // `.whitespacesAndNewlines`, not `.whitespaces`: the latter is
            // Unicode Zs plus tab and does *not* include CR. Splitting a CRLF
            // head on "\n" leaves a trailing "\r" on every line, and a value of
            // "90\r" fails `TimeInterval(_:)` — which silently threw away every
            // `retry-after` and `x-ratelimit-reset` GitHub sent us.
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if index == 0 {
                // "HTTP/2.0 403 Forbidden", or just "HTTP/2 429".
                let parts = trimmed.split(separator: " ")
                if parts.count >= 2 { headers[statusPseudoHeader] = String(parts[1]) }
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let name = trimmed[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = trimmed[trimmed.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        return (headers, Data(body))
    }
}
