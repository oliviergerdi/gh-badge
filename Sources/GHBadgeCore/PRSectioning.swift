import Foundation

public struct PRSections: Equatable, Sendable {
    public var needsReview: [PullRequest]
    public var alreadyReviewed: [PullRequest]
    public var myOpenPRs: [PullRequest]

    public init(
        needsReview: [PullRequest] = [],
        alreadyReviewed: [PullRequest] = [],
        myOpenPRs: [PullRequest] = []
    ) {
        self.needsReview = needsReview
        self.alreadyReviewed = alreadyReviewed
        self.myOpenPRs = myOpenPRs
    }

    public var isEmpty: Bool {
        needsReview.isEmpty && alreadyReviewed.isEmpty && myOpenPRs.isEmpty
    }

    /// The number rendered in the menu bar.
    public var badgeCount: Int { needsReview.count }
}

/// Pure section-assembly logic, deliberately separated from `PRStore` so it can
/// be tested without a main actor, a network, or a `gh` binary.
public enum PRSectioning {
    /// - Parameters:
    ///   - needsReviewRaw: union of `--review-requested=<me>` and any per-team results.
    ///   - reviewedByRaw: `--reviewed-by=<me>` results.
    ///   - authoredRaw: `--author=<me>` results.
    ///   - whitelist: "owner/repo" entries; empty means the review sections stay empty.
    ///   - ignoreWhitelistForOwnPRs: when true, `myOpenPRs` is not whitelist-filtered.
    ///   - cutoff: when non-nil, PRs whose `updatedAt` predates it are hidden.
    ///   - ignoredAuthors: logins to hide from the review sections only (e.g.
    ///     "dependabot[bot]"); `myOpenPRs` is always PRs you authored, so this
    ///     list has nothing to say about it.
    ///   - staleReviewURLs: URLs (from `reviewedCandidates`) with new commits
    ///     pushed since the viewer's last review. Functionally a fresh review
    ///     request, so these move into `needsReview` (and the badge) instead
    ///     of staying parked in `alreadyReviewed`.
    public static func sections(
        needsReviewRaw: [PullRequest],
        reviewedByRaw: [PullRequest],
        authoredRaw: [PullRequest],
        whitelist: [String],
        ignoreWhitelistForOwnPRs: Bool,
        ignoreOlderThan cutoff: Date? = nil,
        ignoredAuthors: [String] = [],
        staleReviewURLs: Set<String> = []
    ) -> PRSections {
        let permitted = permittedPredicate(whitelist)
        let recent = recentPredicate(cutoff)
        let notIgnored = notIgnoredPredicate(ignoredAuthors)

        let baseNeeds = baseNeedsReview(
            needsReviewRaw: needsReviewRaw,
            authoredRaw: authoredRaw,
            permitted: permitted,
            recent: recent,
            notIgnored: notIgnored
        )

        let candidates = reviewedCandidates(
            needsReviewRaw: needsReviewRaw,
            reviewedByRaw: reviewedByRaw,
            authoredRaw: authoredRaw,
            whitelist: whitelist,
            ignoreOlderThan: cutoff,
            ignoredAuthors: ignoredAuthors
        )

        let staleReviewed = candidates.filter { staleReviewURLs.contains($0.url) }
        let alreadyReviewed = candidates
            .filter { !staleReviewURLs.contains($0.url) }
            .sorted(by: PullRequest.byRecency)

        let needsReview = (baseNeeds + staleReviewed).sorted(by: PullRequest.byRecency)

        let mine = dedupe(authoredRaw)
            .filter { (ignoreWhitelistForOwnPRs || permitted($0)) && recent($0) }
            .sorted(by: PullRequest.byRecency)

        return PRSections(
            needsReview: needsReview,
            alreadyReviewed: alreadyReviewed,
            myOpenPRs: mine
        )
    }

    /// PRs that would land in "Already Reviewed, Still Open": pass every filter
    /// (whitelist, staleness, ignored authors) and aren't already claimed by
    /// "Needs My Review". Exposed separately so a caller needing I/O keyed off
    /// this exact set (checking each for new commits since the viewer's last
    /// review) doesn't have to re-derive the filter rules itself.
    public static func reviewedCandidates(
        needsReviewRaw: [PullRequest],
        reviewedByRaw: [PullRequest],
        authoredRaw: [PullRequest],
        whitelist: [String],
        ignoreOlderThan cutoff: Date? = nil,
        ignoredAuthors: [String] = []
    ) -> [PullRequest] {
        let permitted = permittedPredicate(whitelist)
        let recent = recentPredicate(cutoff)
        let notIgnored = notIgnoredPredicate(ignoredAuthors)

        let needsReview = baseNeedsReview(
            needsReviewRaw: needsReviewRaw,
            authoredRaw: authoredRaw,
            permitted: permitted,
            recent: recent,
            notIgnored: notIgnored
        )
        // A re-requested review wins: if a PR appears in both, it belongs only
        // in section 1.
        let needsReviewURLs = Set(needsReview.map(\.url))

        return dedupe(reviewedByRaw)
            .filter { permitted($0) && !needsReviewURLs.contains($0.url) && recent($0) && notIgnored($0) }
    }

    // MARK: - Shared filter rules

    private static func permittedPredicate(_ whitelist: [String]) -> (PullRequest) -> Bool {
        let allowed = Set(whitelist.map { $0.lowercased() })
        return { allowed.contains($0.repo.lowercased()) }
    }

    /// A missing timestamp is kept: we can't prove it's old, and hiding on
    /// uncertainty would drop fresh PRs on decode edge cases.
    private static func recentPredicate(_ cutoff: Date?) -> (PullRequest) -> Bool {
        { pr in
            guard let cutoff else { return true }
            return pr.updatedAt.map { $0 >= cutoff } ?? true
        }
    }

    /// Same "missing data, don't hide" rule as `recentPredicate`: an unknown
    /// author can't be proven to match the ignore list.
    private static func notIgnoredPredicate(_ ignoredAuthors: [String]) -> (PullRequest) -> Bool {
        let ignored = Set(ignoredAuthors.map { $0.lowercased() })
        return { pr in
            guard let author = pr.authorLogin else { return true }
            return !ignored.contains(author.lowercased())
        }
    }

    /// You can't review your own PR, so an authored PR never belongs in
    /// "needs review" even when a team you're in was requested.
    private static func baseNeedsReview(
        needsReviewRaw: [PullRequest],
        authoredRaw: [PullRequest],
        permitted: (PullRequest) -> Bool,
        recent: (PullRequest) -> Bool,
        notIgnored: (PullRequest) -> Bool
    ) -> [PullRequest] {
        let authoredURLs = Set(dedupe(authoredRaw).map(\.url))
        return dedupe(needsReviewRaw)
            .filter { permitted($0) && !authoredURLs.contains($0.url) && recent($0) && notIgnored($0) }
    }

    /// De-duplicates by URL, keeping first occurrence. Needed because the user
    /// query and the per-team queries overlap whenever review is requested from
    /// both an individual and their team.
    public static func dedupe(_ prs: [PullRequest]) -> [PullRequest] {
        var seen = Set<String>()
        var result: [PullRequest] = []
        result.reserveCapacity(prs.count)
        for pr in prs where seen.insert(pr.url).inserted {
            result.append(pr)
        }
        return result
    }
}
