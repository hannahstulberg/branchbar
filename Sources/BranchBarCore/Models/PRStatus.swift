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
///
/// Eight cases since codex round 2 MAJOR 7. `commandFailed` used to carry three unrelated
/// failures under one sentence that asserted both a cause and a cure — "did not answer for this
/// repo in time. Refreshing usually fixes it." — which was false for a 404 answered in 40 ms and
/// false again for a deleted repo. And every 403 that was not rate limiting became
/// `ghNotAuthenticated`, which sent a managed NYT account round a `gh auth login` loop that
/// cannot lift an organization policy. The two new cases carry those apart:
///
/// - `forbidden(repo:)` — GitHub answered 403 for a reason a new token does not change: SAML,
///   an IP allow-list, an organization policy, a grant the account will not be given. The repo
///   travels with the case because the copy names it.
/// - `timedOut` — and only the runner's timeout, which is the one failure whose copy may say the
///   CLI did not answer in time.
public enum PRUnavailableReason: Hashable, Codable, Sendable {
    case ghNotInstalled
    case ghNotAuthenticated(host: String)
    case noRemote
    case notGitHubRemote
    case rateLimited
    /// A 403 that is neither rate limiting nor a credential problem. `repo` is the
    /// `host/owner/name` the request named, which the copy repeats back.
    case forbidden(repo: String)
    /// The `gh` lookup ran past `RefreshPolicy.ghListTimeout` and was killed.
    case timedOut
    /// Anything the list above does not name; the copy states the first stderr line and promises
    /// nothing about it.
    case commandFailed
}

/// Which heads a refresh actually asked GitHub about, keyed the way a head is actually
/// identified (codex round 2, MAJOR 4).
///
/// A head is an (owner, branch name) pair, not a name: `stranger:main` and `tester:main` are two
/// different heads. The recent-100 list answers for the pairs **it** names and for nothing else,
/// so marking `main` queried because a stranger's PR mentioned it skipped the per-head query for
/// the user's own `main`, the stranger's PR was then correctly rejected as a match, and the row
/// read "No PR" beside an open PR.
public struct PRQueryCoverage: Hashable, Codable, Sendable {
    /// One (owner, head) pair. `ownerLogin` is held lower-cased: GitHub logins are
    /// case-insensitive, and `gh` prints whatever casing the account was created with.
    public struct OwnedHead: Hashable, Codable, Sendable {
        public var ownerLogin: String
        public var headRefName: String

        public init(ownerLogin: String, headRefName: String) {
            self.ownerLogin = ownerLogin.lowercased()
            self.headRefName = headRefName
        }
    }

    /// Heads asked about with `gh pr list --head <name>`, which answers for every owner of that
    /// head — the query filters on the head branch and not on who owns it.
    public var anyOwnerHeads: Set<String>
    /// Pairs the recent-100 list named, which answers for those owners only.
    public var ownedHeads: Set<OwnedHead>

    public init(anyOwnerHeads: Set<String> = [], ownedHeads: Set<OwnedHead> = []) {
        self.anyOwnerHeads = anyOwnerHeads
        self.ownedHeads = ownedHeads
    }

    /// True when this refresh really did ask GitHub about the head this branch has on GitHub.
    ///
    /// A nil `ownerLogin` is never covered, whatever was asked: with no owner established there is
    /// no head to have asked about, and `none` would claim an answer nobody has
    /// (`unknownOwnerRendersNotCheckedNeverNone`).
    public func covers(headRefName: String, ownerLogin: String?) -> Bool {
        guard let ownerLogin else { return false }
        if anyOwnerHeads.contains(headRefName) { return true }
        return ownedHeads.contains(OwnedHead(ownerLogin: ownerLogin, headRefName: headRefName))
    }

    /// Records the head a `--head` query asked about, for every owner.
    public mutating func recordAnyOwner(head: String) {
        anyOwnerHeads.insert(head)
    }

    /// Records the (owner, head) pair one returned PR answers for.
    public mutating func record(_ pr: PRInfo) {
        ownedHeads.insert(OwnedHead(ownerLogin: pr.headRepositoryOwnerLogin, headRefName: pr.headRefName))
    }
}
