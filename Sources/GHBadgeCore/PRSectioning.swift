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
    public static func sections(
        needsReviewRaw: [PullRequest],
        reviewedByRaw: [PullRequest],
        authoredRaw: [PullRequest],
        whitelist: [String],
        ignoreWhitelistForOwnPRs: Bool,
        ignoreOlderThan cutoff: Date? = nil,
        ignoredAuthors: [String] = []
    ) -> PRSections {
        let allowed = Set(whitelist.map { $0.lowercased() })
        let ignored = Set(ignoredAuthors.map { $0.lowercased() })

        func permitted(_ pr: PullRequest) -> Bool {
            allowed.contains(pr.repo.lowercased())
        }

        // Staleness filter. A missing timestamp is kept: we can't prove it's
        // old, and hiding on uncertainty would drop fresh PRs on decode edge
        // cases.
        func recent(_ pr: PullRequest) -> Bool {
            guard let cutoff else { return true }
            return pr.updatedAt.map { $0 >= cutoff } ?? true
        }

        // Same "missing data, don't hide" rule as `recent`: an unknown author
        // can't be proven to match the ignore list.
        func notIgnored(_ pr: PullRequest) -> Bool {
            guard let author = pr.authorLogin else { return true }
            return !ignored.contains(author.lowercased())
        }

        // You can't review your own PR, so an authored PR never belongs in
        // "needs review" even when a team you're in was requested.
        let authoredURLs = Set(dedupe(authoredRaw).map(\.url))

        let needsReview = dedupe(needsReviewRaw)
            .filter { permitted($0) && !authoredURLs.contains($0.url) && recent($0) && notIgnored($0) }
            .sorted(by: PullRequest.byRecency)

        // A re-requested review wins: if a PR appears in both, it belongs only
        // in section 1.
        let needsReviewURLs = Set(needsReview.map(\.url))

        let alreadyReviewed = dedupe(reviewedByRaw)
            .filter { permitted($0) && !needsReviewURLs.contains($0.url) && recent($0) && notIgnored($0) }
            .sorted(by: PullRequest.byRecency)

        let mine = dedupe(authoredRaw)
            .filter { (ignoreWhitelistForOwnPRs || permitted($0)) && recent($0) }
            .sorted(by: PullRequest.byRecency)

        return PRSections(
            needsReview: needsReview,
            alreadyReviewed: alreadyReviewed,
            myOpenPRs: mine
        )
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
