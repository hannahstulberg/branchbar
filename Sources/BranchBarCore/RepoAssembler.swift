import Foundation

/// The pure join. Everything the UI shows about one repo is decided here from values, with no
/// process and no filesystem, so every join rule in PLAN.md §5 has a unit test that runs in
/// microseconds.
///
/// PLAN.md §5 draws the boundary explicitly: grouping is decided here and only **rendered** by
/// `SnapshotPresenter`, and `Branch.group` is where the two meet.
public enum RepoAssembler {

    /// Everything one repo's join needs. A struct rather than fifteen parameters so a test can
    /// build a baseline and vary one field.
    public struct Inputs: Sendable {
        public var id: RepoID
        public var path: String
        public var remoteURL: String?
        public var branchRefs: [ParsedBranchRef]
        public var remoteRefs: [ParsedRemoteRef]
        public var worktrees: [Worktree]
        /// Keyed by local branch name.
        public var pushObservations: [String: ReflogObservation]
        /// The recent-100 list plus anything the per-head fallback returned.
        public var pullRequests: [PRInfo]
        public var authoredOpenPullRequests: [PRInfo]
        /// Branch names whose head was actually queried. A branch outside this set gets
        /// `notChecked`; a branch inside it with no PR gets `none`.
        public var queriedHeads: Set<String>
        public var prAvailability: PRAvailability
        public var prFetchedAt: Date?
        public var prLoadState: PRLoadState
        public var errors: [RepoError]
        public var isStale: Bool
        public var refreshedAt: Date?

        public init(
            id: RepoID,
            path: String,
            remoteURL: String? = nil,
            branchRefs: [ParsedBranchRef] = [],
            remoteRefs: [ParsedRemoteRef] = [],
            worktrees: [Worktree] = [],
            pushObservations: [String: ReflogObservation] = [:],
            pullRequests: [PRInfo] = [],
            authoredOpenPullRequests: [PRInfo] = [],
            queriedHeads: Set<String> = [],
            prAvailability: PRAvailability = .available,
            prFetchedAt: Date? = nil,
            prLoadState: PRLoadState = .notLoaded,
            errors: [RepoError] = [],
            isStale: Bool = false,
            refreshedAt: Date? = nil
        ) {
            self.id = id
            self.path = path
            self.remoteURL = remoteURL
            self.branchRefs = branchRefs
            self.remoteRefs = remoteRefs
            self.worktrees = worktrees
            self.pushObservations = pushObservations
            self.pullRequests = pullRequests
            self.authoredOpenPullRequests = authoredOpenPullRequests
            self.queriedHeads = queriedHeads
            self.prAvailability = prAvailability
            self.prFetchedAt = prFetchedAt
            self.prLoadState = prLoadState
            self.errors = errors
            self.isStale = isStale
            self.refreshedAt = refreshedAt
        }
    }

    /// OWNER: packet 3.1 — join branches to worktrees by exact branch name (a worktree with no
    /// branch never joins), to PRs through `PRStatusMapper.match`, and to push observations
    /// through `PushInfoDeriver.derive` against the matching remote-tracking ref; set each
    /// branch's `prStatus` to `notChecked` unless its head is in `queriedHeads`; assign
    /// `group = .merged` only when the PR is merged **and** `tipSHA == headRefOid` **and** the
    /// branch has no worktree, `.closedUnmerged` when the PR is closed unmerged, and `.active`
    /// otherwise; and return a `Repo` whose `openPRsNotOnThisMac` comes from
    /// `PRStatusMapper.openPRsNotOnThisMac` and whose `lastActivity` is the newest branch
    /// committer date.
    public static func assemble(_ inputs: Inputs) -> Repo {
        fatalError("OWNER: packet 3.1 — join branches, worktrees, PRs, and push observations into a Repo, assigning the merged / closedUnmerged / active groups and the open-elsewhere PR list.")
    }
}
