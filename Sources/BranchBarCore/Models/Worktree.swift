import Foundation

/// One line group of `git worktree list --porcelain`. PLAN.md §5.
///
/// `branch` is nil for a detached checkout; PLAN.md §3 renders that as
/// "Worktree at commit abc1234 (no branch)" and the invariant
/// `noBranchWorktreeAppearsUnderRepoAndNoBranchClaimsIt` forbids joining it to a branch.
public struct Worktree: Hashable, Codable, Sendable {
    public var path: String
    /// `HEAD` line. Empty for a bare repo, which prints `bare` and no `HEAD`.
    public var headSHA: String
    /// Full ref name (`refs/heads/main`), or nil when the porcelain prints `detached`.
    public var branch: String?
    /// The first record `git worktree list` prints is the primary worktree.
    public var isPrimary: Bool
    public var isBare: Bool
    public var isLocked: Bool
    /// Text after `locked `, when the lock carries a reason.
    public var lockReason: String?
    public var isPrunable: Bool

    public init(
        path: String,
        headSHA: String,
        branch: String? = nil,
        isPrimary: Bool = false,
        isBare: Bool = false,
        isLocked: Bool = false,
        lockReason: String? = nil,
        isPrunable: Bool = false
    ) {
        self.path = path
        self.headSHA = headSHA
        self.branch = branch
        self.isPrimary = isPrimary
        self.isBare = isBare
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.isPrunable = isPrunable
    }
}
