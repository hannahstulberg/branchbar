import Foundation

/// PLAN.md §5, ten cases. The distinction that came from a review finding: `none` is only
/// reachable after the branch's head was actually queried and returned nothing; `notChecked`
/// covers the per-repo cap, the deadline, and a collapsed repo. Invariant
/// `unqueriedBranchIsNotCheckedNeverNone`.
public enum PRStatus: String, Hashable, Codable, Sendable, CaseIterable {
    /// Queried, no PR exists for this head.
    case none
    case draft
    case open
    case changesRequested
    case approved
    case merged
    case closed
    /// `gh` missing, not signed in, no remote, not GitHub, rate limited, or the command failed.
    case unavailable
    /// Repo is collapsed; PLAN.md §3 renders "PR status loads when expanded".
    case notLoaded
    /// The per-head query never ran (cap of 20, 45 s deadline, or collapsed repo).
    case notChecked
}

/// Whether a repo's PR data has been fetched this session. PLAN.md §5 `Repo.prLoadState`.
public enum PRLoadState: String, Hashable, Codable, Sendable, CaseIterable {
    case notLoaded
    case loaded
    /// Loaded from `CacheFile.prCache` past its 10-minute TTL.
    case stale
}

/// One row of `gh pr list --json …`. PLAN.md §5, field names match the JSON keys except
/// `headRepositoryOwnerLogin`, which is flattened from the `headRepositoryOwner` object
/// (a footgun recorded in CLAUDE.md: the field is an object, use `.login`).
public struct PRInfo: Hashable, Codable, Sendable {
    public var number: Int
    public var url: String
    /// `OPEN`, `MERGED`, `CLOSED` as `gh` prints them.
    public var state: String
    public var isDraft: Bool
    /// `gh` returns `""`, not null, when there is no decision yet. Invariant
    /// `emptyReviewDecisionStringIsNotAReviewDecision`.
    public var reviewDecision: String
    public var mergedAt: Date?
    public var updatedAt: Date
    public var baseRefName: String
    public var headRefName: String
    public var headRefOid: String
    public var headRepositoryOwnerLogin: String
    public var mergeCommitOid: String?

    public init(
        number: Int,
        url: String,
        state: String,
        isDraft: Bool,
        reviewDecision: String,
        mergedAt: Date? = nil,
        updatedAt: Date,
        baseRefName: String,
        headRefName: String,
        headRefOid: String,
        headRepositoryOwnerLogin: String,
        mergeCommitOid: String? = nil
    ) {
        self.number = number
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.mergedAt = mergedAt
        self.updatedAt = updatedAt
        self.baseRefName = baseRefName
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.headRepositoryOwnerLogin = headRepositoryOwnerLogin
        self.mergeCommitOid = mergeCommitOid
    }
}

/// PLAN.md §5. `detail` carries the diagnostic (a `gh` stderr line), never the user-facing copy;
/// packet 4.0's `Strings.swift` owns the copy for each reason.
/// Also an `Error` so `GHClient` can return it as the failure half of a `Result` without a
/// second, parallel error enum drifting out of sync with the reason list.
public enum PRAvailability: Error, Hashable, Codable, Sendable {
    case available
    case unavailable(PRUnavailableReason, detail: String?)
}

/// PLAN.md §5. Every reason gets one action in the UI contract (§5a item 1).
public enum PRUnavailableReason: Hashable, Codable, Sendable {
    case ghNotInstalled
    case ghNotAuthenticated(host: String)
    case noRemote
    case notGitHubRemote
    case rateLimited
    case commandFailed
}
