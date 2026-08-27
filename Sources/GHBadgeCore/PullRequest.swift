import Foundation

/// A pull request as returned by `gh search prs --json repository,number,title,url,updatedAt,state,author`.
///
/// The `repository` value is confirmed (live `gh` 2.98.0) to be an object with
/// `name` and `nameWithOwner`; only the latter is consumed. Decoding fails
/// loudly if `gh` ever changes that shape, so a breaking change surfaces as an
/// error banner rather than silently wrong output.
public struct PullRequest: Identifiable, Hashable, Codable, Sendable {
    /// The PR URL. Unique per PR and used for de-duplication across sections.
    public var id: String { url }

    /// "owner/repo".
    public let repo: String
    public let number: Int
    public let title: String
    public let url: String
    public let updatedAt: Date?
    public let state: String

    /// The PR author's login, e.g. "dependabot[bot]". Optional: fixtures and
    /// any payload predating this field omit it, and decoding must not
    /// fabricate a value in that case.
    public let authorLogin: String?

    public init(
        repo: String,
        number: Int,
        title: String,
        url: String,
        updatedAt: Date? = nil,
        state: String = "open",
        authorLogin: String? = nil
    ) {
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.updatedAt = updatedAt
        self.state = state
        self.authorLogin = authorLogin
    }

    /// Just the repository name, without the owner. Used in the dropdown, where
    /// the owner is usually noise.
    public var repoShortName: String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }

    public var owner: String? {
        let parts = repo.split(separator: "/")
        return parts.count == 2 ? String(parts[0]) : nil
    }

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case repository, number, title, url, updatedAt, state, author
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        self.url = try c.decode(String.self, forKey: .url)
        self.number = try c.decode(Int.self, forKey: .number)
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? "(untitled)"
        self.state = (try c.decodeIfPresent(String.self, forKey: .state) ?? "open").lowercased()

        let repo = try c.nestedContainer(keyedBy: RepositoryKeys.self, forKey: .repository)
        self.repo = try repo.decode(String.self, forKey: .nameWithOwner)

        self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
            .flatMap(PullRequest.parseTimestamp)

        // `try?`, not `decodeIfPresent`: an `author` key whose value is present
        // but missing `login` (or a shape we don't expect) should degrade to
        // nil rather than throw, same tolerance as a wholly absent key.
        if let authorContainer = try? c.nestedContainer(keyedBy: AuthorKeys.self, forKey: .author) {
            self.authorLogin = try? authorContainer.decode(String.self, forKey: .login)
        } else {
            self.authorLogin = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var repoContainer = c.nestedContainer(keyedBy: RepositoryKeys.self, forKey: .repository)
        try repoContainer.encode(repo, forKey: .nameWithOwner)
        try c.encode(number, forKey: .number)
        try c.encode(title, forKey: .title)
        try c.encode(url, forKey: .url)
        try c.encode(state, forKey: .state)
        if let updatedAt {
            try c.encode(PullRequest.formatTimestamp(updatedAt), forKey: .updatedAt)
        }
        if let authorLogin {
            var authorContainer = c.nestedContainer(keyedBy: AuthorKeys.self, forKey: .author)
            try authorContainer.encode(authorLogin, forKey: .login)
        }
    }

    // MARK: - Repository

    /// Confirmed live (`gh search prs --json repository`, gh 2.98.0): an object
    /// with `name` and `nameWithOwner`. Only `nameWithOwner` is consumed.
    private enum RepositoryKeys: String, CodingKey {
        case nameWithOwner
    }

    /// Confirmed live (`gh search prs --json author`, gh 2.98.0): an object
    /// with `login`, `id`, `is_bot`, `type`, `url`. Only `login` is consumed.
    private enum AuthorKeys: String, CodingKey {
        case login
    }

    // MARK: - Timestamps

    static func parseTimestamp(_ raw: String) -> Date? {
        timestampCodec.date(from: raw)
    }

    static func formatTimestamp(_ date: Date) -> String {
        timestampCodec.string(from: date)
    }
}

/// `ISO8601DateFormatter` is a non-`Sendable` class, so holding one in a bare
/// `static let` is unsafe shared mutable state: a warning under Swift 5's
/// concurrency checking and an error in Swift 6 language mode. Lock-guarded and
/// exposed as `Sendable`, which makes the file-scope `let` below safe.
private final class TimestampCodec: @unchecked Sendable {
    private let lock = NSLock()
    private let plain: ISO8601DateFormatter
    private let fractional: ISO8601DateFormatter

    init() {
        plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    /// GitHub emits whole seconds, but fractional seconds are valid ISO 8601 and
    /// a single formatter will not parse both.
    func date(from raw: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return plain.date(from: raw) ?? fractional.date(from: raw)
    }

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return plain.string(from: date)
    }
}

private let timestampCodec = TimestampCodec()

extension PullRequest {
    /// Newest first. Entries with no timestamp sort last rather than jumping to
    /// the top, which is what a `nil`-as-distantPast comparison would do.
    public static func byRecency(_ a: PullRequest, _ b: PullRequest) -> Bool {
        switch (a.updatedAt, b.updatedAt) {
        case let (l?, r?): return l > r
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): return a.url < b.url
        }
    }
}
