import Foundation

/// A local branch joined to its worktree, PR, and push observation. PLAN.md §5.
public struct Branch: Hashable, Codable, Sendable {
    /// Short name (`main`), never the full ref. PLAN.md §5 joins on exact branch name.
    public var name: String
    public var tipSHA: String
    public var committerDate: Date
    public var upstream: Upstream?
    /// Path of the worktree that has this branch checked out, if any.
    public var worktreePath: String?
    public var isCheckedOutInPrimary: Bool
    public var pr: PRInfo?
    public var prStatus: PRStatus
    public var push: PushInfo
    /// Decided by `RepoAssembler` (packet 3.1) and only rendered by `SnapshotPresenter`
    /// (packet 2.2). PLAN.md §5: "`Branch.group` is the boundary."
    public var group: BranchGroup

    public init(
        name: String,
        tipSHA: String,
        committerDate: Date,
        upstream: Upstream? = nil,
        worktreePath: String? = nil,
        isCheckedOutInPrimary: Bool = false,
        pr: PRInfo? = nil,
        prStatus: PRStatus = .notChecked,
        push: PushInfo = PushInfo(),
        group: BranchGroup = .active
    ) {
        self.name = name
        self.tipSHA = tipSHA
        self.committerDate = committerDate
        self.upstream = upstream
        self.worktreePath = worktreePath
        self.isCheckedOutInPrimary = isCheckedOutInPrimary
        self.pr = pr
        self.prStatus = prStatus
        self.push = push
        self.group = group
    }
}

/// PLAN.md §3: three named groups per repo, never one "clean up" bucket.
public enum BranchGroup: String, Hashable, Codable, Sendable, CaseIterable {
    case active
    case merged
    case closedUnmerged
}

/// Tracking information from `%(upstream:short)`, `%(upstream:remotename)`, and
/// `%(upstream:track,nobracket)`. PLAN.md §3: `behind` is parsed and never displayed;
/// "in sync" and "no upstream" are distinguished by `upstream:short`, never by the track field.
public struct Upstream: Hashable, Codable, Sendable {
    /// `%(upstream:short)`, e.g. `origin/main`.
    public var ref: String
    /// `%(upstream:remotename)`, e.g. `origin`.
    public var remote: String
    public var ahead: Int
    /// Parsed for completeness; PLAN.md §3 forbids presenting it.
    public var behind: Int
    /// `%(upstream:track,nobracket)` reported `gone`.
    public var isGone: Bool

    public init(ref: String, remote: String, ahead: Int = 0, behind: Int = 0, isGone: Bool = false) {
        self.ref = ref
        self.remote = remote
        self.ahead = ahead
        self.behind = behind
        self.isGone = isGone
    }

    /// Branch name inside the remote-tracking ref: `origin/feature/x` → `feature/x`.
    public var branchName: String {
        guard ref.hasPrefix(remote + "/") else { return ref }
        return String(ref.dropFirst(remote.count + 1))
    }
}
