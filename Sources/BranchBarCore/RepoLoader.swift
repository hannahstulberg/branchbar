import Foundation

/// One repo, end to end: git first (always, it is local and fast), then `gh` only when the repo
/// is expanded or in the 5 most recently active and its PR cache is older than the TTL.
///
/// PLAN.md §3: a stage that fails is recorded as a `RepoError` and the other stages still run,
/// so `oneRepoFailingLeavesOthersPopulated` holds.
public struct RepoLoader: Sendable {
    private let git: GitClient
    private let gh: GHClient?
    private let reflog: ReflogFileReader
    private let policy: RefreshPolicy

    public init(git: GitClient, gh: GHClient?, reflog: ReflogFileReader, policy: RefreshPolicy = .default) {
        self.git = git
        self.gh = gh
        self.reflog = reflog
        self.policy = policy
    }

    /// OWNER: packet 3.1 — run the five git stages for this repo (`rev-parse`,
    /// `config --get remote.origin.url`, both `for-each-ref`s, `worktree list`) plus a reflog file
    /// read per upstream branch, catching each stage into a `RepoError` instead of throwing; then,
    /// only when `wantsPullRequests` is true and `cachedPRs` is nil or older than
    /// `policy.prCacheTTL`, run the recent-100 `gh` list, up to `policy.perHeadFallbackCap`
    /// per-head queries for branches it did not match, and the author-@me list; and return
    /// `RepoAssembler.assemble` of everything, with `queriedHeads` naming exactly the heads that
    /// were actually queried.
    public func load(
        _ discovered: DiscoveredRepo,
        wantsPullRequests: Bool,
        cachedPRs: PRCacheEntry?,
        now: Date
    ) async -> Repo {
        fatalError("OWNER: packet 3.1 — load one repo: every git stage isolated into a RepoError, gh only when wanted and the cache is cold, then RepoAssembler.assemble.")
    }
}
