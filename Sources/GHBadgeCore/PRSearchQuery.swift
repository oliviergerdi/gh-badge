import Foundation

/// Everything one refresh needs, from one request.
///
/// The three buckets mirror the three `gh search prs` calls this replaces, so
/// `PRSectioning` is unchanged: it still receives "review requested",
/// "reviewed by" and "authored" separately and applies the whitelist itself.
public struct PRSearchResponse: Equatable, Sendable {
    /// Union of the viewer's own review requests and every active team's.
    public var needsReview: [PullRequest] = []
    public var reviewedBy: [PullRequest] = []
    public var authored: [PullRequest] = []

    /// Staleness and branch names, free here: both come from scalar fields on
    /// PRs this query already walks, so the separate revision round-trip that
    /// `GHClient.fetchRevisionInfo` used to make is no longer needed.
    public var revisionInfo = PRRevisionInfo()

    /// Aliases whose result set hit `pageSize`. Surfaced rather than swallowed:
    /// a truncated bucket means the whitelist filter runs over an incomplete
    /// set, so a watched repo's PR can silently go missing from the badge.
    public var truncatedBuckets: [String] = []

    public init() {}
}

/// Builds and parses the single GraphQL document that replaces every per-refresh
/// REST call.
///
/// **Why one GraphQL request instead of N REST searches.** The old shape cost
/// `3 + teams` calls against the REST *search* endpoint — whose budget is 30
/// requests per minute, not the 5,000/hr people assume — plus one `gh api
/// graphql` for revision info, plus, whenever that batch was rejected, one `gh
/// pr view` per listed PR fired concurrently. Past roughly four watched repos
/// that last path alone could put 50+ simultaneous requests in flight and trip
/// the secondary rate limit on every poll.
///
/// GraphQL collapses all of it: aliased `search` fields run in a single
/// document, and the per-PR data (`headRefOid`, `headRefName`,
/// `viewerLatestReview`) rides along on nodes the search already returns. One
/// HTTP request per refresh, costing a handful of points against a 5,000/hr
/// budget.
///
/// **Why the searches stay repo-agnostic.** No `repo:` qualifiers are injected
/// from the whitelist. GitHub's search syntax caps query length and operator
/// count, so a growing whitelist would eventually produce an invalid query —
/// exactly the "more repos, more breakage" cliff being fixed. Instead the query
/// asks for the viewer's PRs across all of GitHub and `PRSectioning` filters
/// locally, which costs nothing extra: it is the same one request either way.
public enum PRSearchQuery {
    /// GitHub's hard ceiling for `first:` on a connection. Buckets that reach
    /// it are reported in `truncatedBuckets`.
    public static let maxPageSize = 100

    static let needsReviewAlias = "needsReview"
    static let reviewedByAlias = "reviewedBy"
    static let authoredAlias = "authored"
    static let teamAliasPrefix = "team"

    /// - Parameters:
    ///   - login: the viewer's resolved login. Preferred over `@me` for the
    ///     same reason as before — `@me` is a documented search shorthand, but
    ///     the literal login is unambiguous in every qualifier.
    ///   - teams: "org/team-slug" entries whose review requests also count.
    ///     Each becomes its own alias; they can't be OR'd into one qualifier.
    public static func build(login: String, teams: [String], pageSize: Int = maxPageSize) -> String {
        let size = min(max(pageSize, 1), maxPageSize)
        var fields: [String] = [
            // Costs nothing and rides along on every response, including the
            // one that reports exhaustion — which is where `RateLimitDetector`
            // reads `resetAt` from when no headers are available.
            "rateLimit { limit cost remaining resetAt }"
        ]

        fields.append(searchField(alias: needsReviewAlias, query: "review-requested:\(login)", size: size))
        fields.append(searchField(alias: reviewedByAlias, query: "reviewed-by:\(login)", size: size))
        fields.append(searchField(alias: authoredAlias, query: "author:\(login)", size: size))

        for (index, team) in teams.enumerated() {
            fields.append(
                searchField(
                    alias: "\(teamAliasPrefix)\(index)",
                    query: "review-requested:\(team)",
                    size: size
                )
            )
        }

        return """
        query {
        \(fields.joined(separator: "\n"))
        }

        fragment prFields on PullRequest {
          number
          title
          url
          updatedAt
          state
          isDraft
          headRefName
          headRefOid
          author { login }
          repository { nameWithOwner }
          viewerLatestReview { commit { oid } }
        }
        """
    }

    /// `is:pr is:open` is baked in rather than left to the caller: `type: ISSUE`
    /// searches issues *and* PRs, and every bucket here is open-PRs-only.
    private static func searchField(alias: String, query: String, size: Int) -> String {
        """
          \(alias): search(query: "is:pr is:open \(escape(query))", type: ISSUE, first: \(size)) {
            issueCount
            nodes { ...prFields }
          }
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Parsing

    /// nil means the response was unusable as a whole (not JSON, or no `data`
    /// object at all) and the caller should fall back to the REST path. A
    /// response with *some* buckets missing is not a failure: the present ones
    /// are returned and the absent ones come back empty, matching the existing
    /// "partial success is still useful" rule in `PRStore.merge`.
    public static func parse(_ responseData: Data, pageSize: Int = maxPageSize) -> PRSearchResponse? {
        guard
            let root = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let data = root["data"] as? [String: Any]
        else { return nil }

        // `bucket` deliberately touches neither `response` nor anything it is
        // assigned into. A nested function that mutated `response` while its
        // return value was being appended to `response` would be overlapping
        // access to the same variable — which Swift's exclusivity checking
        // rejects outright in the `append(contentsOf:)` case below.
        var revision = PRRevisionInfo()
        var truncated: [String] = []

        func bucket(_ alias: String) -> [PullRequest] {
            guard let node = data[alias] as? [String: Any] else { return [] }
            let raw = (node["nodes"] as? [Any]) ?? []

            // Decode and harvest revision fields in one pass over the same
            // object. Zipping a decoded array back against the raw one would
            // silently misalign the moment a single node failed to decode,
            // attaching one PR's branch name to a different PR.
            var prs: [PullRequest] = []
            prs.reserveCapacity(raw.count)
            for case let object as [String: Any] in raw {
                guard let pr = decodeNode(object) else { continue }
                prs.append(pr)
                absorbRevisionFields(from: object, for: pr, into: &revision)
            }

            // `issueCount` is the true total; `nodes` is capped at `first:`.
            let total = node["issueCount"] as? Int
            if (total ?? prs.count) > pageSize || raw.count >= pageSize {
                truncated.append(alias)
            }
            return prs
        }

        var needsReview = bucket(needsReviewAlias)
        let reviewedBy = bucket(reviewedByAlias)
        let authored = bucket(authoredAlias)

        // Team aliases are discovered from the response rather than recomputed
        // from a team list, so parsing can't drift out of step with building.
        // Sorted by index, not lexicographically, so team10 doesn't land
        // between team1 and team2.
        let teamAliases = data.keys
            .compactMap { key -> (index: Int, alias: String)? in
                guard key.hasPrefix(teamAliasPrefix),
                      let index = Int(key.dropFirst(teamAliasPrefix.count))
                else { return nil }
                return (index: index, alias: key)
            }
            .sorted { $0.index < $1.index }
            .map { $0.alias }
        for alias in teamAliases {
            needsReview.append(contentsOf: bucket(alias))
        }

        var response = PRSearchResponse()
        // The viewer's own request and a team's overlap whenever review is
        // asked of both, same as the merged REST queries this replaces.
        response.needsReview = PRSectioning.dedupe(needsReview)
        response.reviewedBy = reviewedBy
        response.authored = authored
        response.revisionInfo = revision
        response.truncatedBuckets = truncated
        return response
    }

    /// The GraphQL node shape is key-for-key compatible with what `gh search
    /// prs --json` emits (`repository.nameWithOwner`, `author.login`, `state`,
    /// `isDraft`, `updatedAt`), so `PullRequest`'s existing decoder is reused
    /// rather than duplicated. `state` arrives as `OPEN`; the decoder already
    /// lowercases it.
    ///
    /// Decoded one node at a time on purpose: `search(type: ISSUE)` returns a
    /// union, and one unexpected member should cost that single row, not the
    /// whole bucket.
    static func decodeNode(_ object: [String: Any]) -> PullRequest? {
        guard
            object["url"] != nil,
            let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        return try? JSONDecoder().decode(PullRequest.self, from: data)
    }

    /// Same "can't prove it, don't move it" rule as the old
    /// `PRRevisionQuery.parse`: a missing or malformed review node contributes
    /// nothing rather than wrongly marking a review fresh or stale.
    private static func absorbRevisionFields(
        from node: [String: Any],
        for pr: PullRequest,
        into info: inout PRRevisionInfo
    ) {
        if let branchName = node["headRefName"] as? String {
            info.branchNames[pr.url] = branchName
        }
        if
            let headRefOid = node["headRefOid"] as? String,
            let review = node["viewerLatestReview"] as? [String: Any],
            let commit = review["commit"] as? [String: Any],
            let reviewedOid = commit["oid"] as? String,
            reviewedOid != headRefOid
        {
            info.staleReviewURLs.insert(pr.url)
        }
    }
}
