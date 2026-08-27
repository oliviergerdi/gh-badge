import Combine
import Foundation

/// Unit for the "ignore PRs older than" staleness threshold.
public enum StalenessUnit: String, CaseIterable, Sendable {
    case hours, days, weeks

    public var seconds: TimeInterval {
        switch self {
        case .hours: return 3_600
        case .days: return 86_400
        case .weeks: return 604_800
        }
    }
}

@MainActor
public final class SettingsStore: ObservableObject {
    public enum Key {
        public static let repoWhitelist = "repoWhitelist"
        public static let teamReviewEnabled = "teamReviewEnabled"
        public static let teams = "teams"
        public static let ignoreWhitelistForOwnPRs = "ignoreWhitelistForOwnPRs"
        public static let launchAtLogin = "launchAtLogin"
        public static let refreshIntervalSeconds = "refreshIntervalSeconds"
        public static let ignoreOlderThanEnabled = "ignoreOlderThanEnabled"
        public static let ignoreOlderThanValue = "ignoreOlderThanValue"
        public static let ignoreOlderThanUnit = "ignoreOlderThanUnit"
    }

    public static let refreshIntervalOptions = [60, 120, 300, 600]
    public static let defaultRefreshInterval = 300

    private let defaults: UserDefaults
    private var isLoading = false

    /// Repositories to watch, as "owner/repo". Opt-in: an empty list means the
    /// review sections stay empty, by design.
    @Published public var repoWhitelist: [String] = [] {
        didSet { persist(repoWhitelist, Key.repoWhitelist) }
    }

    /// Also count PRs where review was requested from one of `teams`.
    @Published public var teamReviewEnabled: Bool = false {
        didSet { persist(teamReviewEnabled, Key.teamReviewEnabled) }
    }

    /// Teams as "org/team-slug".
    @Published public var teams: [String] = [] {
        didSet { persist(teams, Key.teams) }
    }

    /// Show all of my own open PRs regardless of the whitelist.
    @Published public var ignoreWhitelistForOwnPRs: Bool = false {
        didSet { persist(ignoreWhitelistForOwnPRs, Key.ignoreWhitelistForOwnPRs) }
    }

    /// Hide PRs whose `updatedAt` is older than the threshold. Off by default.
    @Published public var ignoreOlderThanEnabled: Bool = false {
        didSet { persist(ignoreOlderThanEnabled, Key.ignoreOlderThanEnabled) }
    }

    /// The threshold amount; clamped to a minimum of 1 so the cutoff never
    /// lands in the future (which would hide everything).
    @Published public var ignoreOlderThanValue: Int = 1 {
        didSet {
            if ignoreOlderThanValue < 1 {
                ignoreOlderThanValue = 1
            } else {
                persist(ignoreOlderThanValue, Key.ignoreOlderThanValue)
            }
        }
    }

    /// Raw value of the unit, persisted as a string so `UserDefaults` stays
    /// happy without a custom `RawRepresentable` round-trip.
    @Published public var ignoreOlderThanUnitRaw: String = StalenessUnit.days.rawValue {
        didSet { persist(ignoreOlderThanUnitRaw, Key.ignoreOlderThanUnit) }
    }

    @Published public var launchAtLogin: Bool = false {
        didSet { persist(launchAtLogin, Key.launchAtLogin) }
    }

    @Published public var refreshIntervalSeconds: Int = SettingsStore.defaultRefreshInterval {
        didSet { persist(refreshIntervalSeconds, Key.refreshIntervalSeconds) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private func load() {
        isLoading = true
        repoWhitelist = defaults.stringArray(forKey: Key.repoWhitelist) ?? []
        teamReviewEnabled = defaults.bool(forKey: Key.teamReviewEnabled)
        teams = defaults.stringArray(forKey: Key.teams) ?? []
        ignoreWhitelistForOwnPRs = defaults.bool(forKey: Key.ignoreWhitelistForOwnPRs)
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        let stored = defaults.integer(forKey: Key.refreshIntervalSeconds)
        refreshIntervalSeconds = Self.refreshIntervalOptions.contains(stored)
            ? stored
            : Self.defaultRefreshInterval
        ignoreOlderThanEnabled = defaults.bool(forKey: Key.ignoreOlderThanEnabled)
        let storedAmount = defaults.integer(forKey: Key.ignoreOlderThanValue)
        ignoreOlderThanValue = storedAmount >= 1 ? storedAmount : 1
        ignoreOlderThanUnitRaw = defaults.string(forKey: Key.ignoreOlderThanUnit)
            ?? StalenessUnit.days.rawValue
        isLoading = false
    }

    private func persist(_ value: Any, _ key: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
    }

    // MARK: - Mutation helpers

    /// Accepts "owner/repo", a full GitHub URL, or a "git@github.com:owner/repo.git"
    /// remote, and normalises to "owner/repo". Returns nil if it cannot.
    /// `nonisolated` so tests (and any non-main-actor caller) can use it: static
    /// members of a `@MainActor` type are otherwise main-actor isolated too.
    public nonisolated static func normalizeRepo(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if let range = s.range(of: "github.com") {
            s = String(s[range.upperBound...])
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
        }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let parts = s.split(separator: "/").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        guard parts.allSatisfy({ $0.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil }) else {
            return nil
        }
        return "\(parts[0])/\(parts[1])"
    }

    /// "org/team-slug". Same shape as a repo, different meaning, so validated
    /// with the same rules.
    public nonisolated static func normalizeTeam(_ raw: String) -> String? {
        normalizeRepo(raw)
    }

    /// Returns false when the entry is invalid or already present.
    @discardableResult
    public func addRepo(_ raw: String) -> Bool {
        guard let repo = Self.normalizeRepo(raw) else { return false }
        guard !repoWhitelist.contains(where: { $0.caseInsensitiveCompare(repo) == .orderedSame }) else {
            return false
        }
        repoWhitelist.append(repo)
        return true
    }

    public func removeRepos(_ repos: Set<String>) {
        repoWhitelist.removeAll { repos.contains($0) }
    }

    @discardableResult
    public func addTeam(_ raw: String) -> Bool {
        guard let team = Self.normalizeTeam(raw) else { return false }
        guard !teams.contains(where: { $0.caseInsensitiveCompare(team) == .orderedSame }) else {
            return false
        }
        teams.append(team)
        return true
    }

    public func removeTeams(_ toRemove: Set<String>) {
        teams.removeAll { toRemove.contains($0) }
    }

    // MARK: - Derived

    /// Teams actually used for querying: only when the toggle is on.
    public var activeTeams: [String] {
        teamReviewEnabled ? teams : []
    }

    public var ignoreOlderThanUnit: StalenessUnit {
        StalenessUnit(rawValue: ignoreOlderThanUnitRaw) ?? .days
    }

    /// The cutoff `Date` when "ignore older than" is enabled, else nil.
    public var ignoreOlderThanCutoff: Date? {
        guard ignoreOlderThanEnabled else { return nil }
        return Self.cutoff(now: Date(), amount: ignoreOlderThanValue, unit: ignoreOlderThanUnit)
    }

    /// `now` minus `amount` × `unit`, floored at one unit so a zero/negative
    /// amount can't produce a future cutoff. Kept `nonisolated` and static so
    /// tests can exercise it deterministically.
    public nonisolated static func cutoff(now: Date, amount: Int, unit: StalenessUnit) -> Date {
        now.addingTimeInterval(-unit.seconds * TimeInterval(max(amount, 1)))
    }

    public nonisolated static func intervalLabel(_ seconds: Int) -> String {
        seconds < 60
            ? "\(seconds) seconds"
            : (seconds == 60 ? "1 minute" : "\(seconds / 60) minutes")
    }
}
