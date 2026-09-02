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
        /// False when `git worktree list` failed, so `worktrees` is "unknown" rather than "none".
        /// The Merged group is suppressed in that case (codex MAJOR 12).
        public var worktreesEnumerated: Bool
        /// `FETCH_HEAD`'s modification date: when this clone last heard from origin. Nil when the
        /// clone has never fetched (codex MAJOR 7).
        public var fetchHeadObservedAt: Date?
        /// Keyed by local branch name.
        public var pushObservations: [String: ReflogObservation]
        /// The recent-100 list plus anything the per-head fallback returned.
        public var pullRequests: [PRInfo]
        public var authoredOpenPullRequests: [PRInfo]
        /// The (owner, head) pairs this refresh actually asked GitHub about. A branch the
        /// coverage does not cover gets `notChecked`; one it covers with no PR gets `none`.
        /// Keyed by owner as well as name since codex round 2 MAJOR 4.
        public var queryCoverage: PRQueryCoverage
        /// Owner login per configured remote name, resolved by `RepoLoader` from
        /// `config --get remote.<name>.url`. A branch tracking a remote that is absent here has an
        /// owner that exists and could not be established, which is not the same as origin's
        /// (codex round 2, MAJOR 4).
        public var remoteOwners: [String: String]
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
            worktreesEnumerated: Bool = true,
            fetchHeadObservedAt: Date? = nil,
            pushObservations: [String: ReflogObservation] = [:],
            pullRequests: [PRInfo] = [],
            authoredOpenPullRequests: [PRInfo] = [],
            queryCoverage: PRQueryCoverage = PRQueryCoverage(),
            remoteOwners: [String: String] = [:],
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
            self.worktreesEnumerated = worktreesEnumerated
            self.fetchHeadObservedAt = fetchHeadObservedAt
            self.pushObservations = pushObservations
            self.pullRequests = pullRequests
            self.authoredOpenPullRequests = authoredOpenPullRequests
            self.queryCoverage = queryCoverage
            self.remoteOwners = remoteOwners
            self.prAvailability = prAvailability
            self.prFetchedAt = prFetchedAt
            self.prLoadState = prLoadState
            self.errors = errors
            self.isStale = isStale
            self.refreshedAt = refreshedAt
        }
    }

    /// The join. Branches come from the `refs/heads` rows, worktrees join them by exact branch
    /// name, PRs join through `PRStatusMapper`, and push facts come from `PushInfoDeriver` against
    /// the matching remote-tracking ref. Grouping is decided here and only rendered by
    /// `SnapshotPresenter`; `Branch.group` is the boundary (PLAN.md §5).
    ///
    /// Two PR facts are repo-wide and short-circuit the per-branch join, in this order:
    /// an unavailable `PRAvailability` makes every branch `.unavailable` and empties
    /// "Open PRs not on this Mac" (a half-populated list from a failed query would read as fact),
    /// and a `notLoaded` load state makes every branch `.notLoaded` — the collapsed-repo state,
    /// which is a statement about this app and not about GitHub.
    public static func assemble(_ inputs: Inputs) -> Repo {
        let slug = inputs.remoteURL.flatMap(GitHubSlug.init(remoteURL:))
        let worktreeByBranch = worktreesByBranchName(inputs.worktrees)
        let remoteTips = Dictionary(
            inputs.remoteRefs.map { ($0.shortName, $0) },
            uniquingKeysWith: { first, _ in first })

        let isUnavailable: Bool
        if case .unavailable = inputs.prAvailability { isUnavailable = true } else { isUnavailable = false }
        let isNotLoaded = inputs.prLoadState == .notLoaded

        var branches: [Branch] = []
        var localHeads: Set<PRStatusMapper.LocalHead> = []
        var localBranchNames: Set<String> = []

        // `-- refs/heads` is the frozen pattern, but a row that is not a branch must never become
        // one: `refs/tags/main` and `refs/heads/main` are different objects with the same name.
        for row in inputs.branchRefs where row.refName.hasPrefix("refs/heads/") {
            let name = row.branchName
            let upstream = ForEachRefParser.upstream(from: row)
            let upstreamTip = upstream.flatMap { remoteTips[$0.ref] }
            // The same-named `origin/<branch>` behind an untracked branch (codex MAJOR 6): the ref
            // whose reflog the loader read, and the remote its wording has to name.
            let sameNamedOriginTip = remoteTips["origin/\(name)"]
            let tip = upstreamTip ?? sameNamedOriginTip
            let remoteName = upstream?.remote ?? (sameNamedOriginTip != nil ? "origin" : nil)
            let owner = upstreamOwnerLogin(upstream: upstream, slug: slug, remoteOwners: inputs.remoteOwners)
            // A branch that tracks something whose owner this app never resolved: the head exists
            // on GitHub, and which head it is was never established (codex round 2, MAJOR 4).
            let ownerUnresolved = upstream != nil && owner == nil
            let claimedOwner = ownerUnresolved ? nil : (owner ?? slug?.owner)

            localBranchNames.insert(name)
            if let owner {
                localHeads.insert(PRStatusMapper.LocalHead(ownerLogin: owner, branchName: name))
            }

            let matched = (isUnavailable || isNotLoaded)
                ? nil
                : PRStatusMapper.match(
                    branchName: name,
                    upstreamOwnerLogin: owner,
                    repoOwnerLogin: slug?.owner,
                    upstreamOwnerUnresolved: ownerUnresolved,
                    in: inputs.pullRequests)

            let status: PRStatus
            if isUnavailable {
                status = .unavailable
            } else if isNotLoaded {
                status = .notLoaded
            } else if let matched {
                status = PRStatusMapper.status(for: matched)
            } else {
                // The `none` versus `notChecked` distinction: `none` is only reachable after this
                // branch's own head — owner included — was queried
                // (`unqueriedBranchIsNotCheckedNeverNone`, `unknownOwnerRendersNotCheckedNeverNone`).
                status = inputs.queryCoverage.covers(headRefName: name, ownerLogin: claimedOwner)
                    ? .none
                    : .notChecked
            }

            let worktreePath = worktreeByBranch[name]?.path

            branches.append(Branch(
                name: name,
                tipSHA: row.objectName,
                committerDate: row.committerDate,
                upstream: upstream,
                worktreePath: worktreePath,
                isCheckedOutInPrimary: row.isHead,
                pr: matched,
                prStatus: status,
                push: PushInfoDeriver.derive(
                    observation: inputs.pushObservations[name],
                    upstream: upstream,
                    remoteTipOID: tip?.objectName,
                    remoteTipCommitDate: tip?.committerDate,
                    fetchHeadObservedAt: inputs.fetchHeadObservedAt,
                    remoteName: remoteName),
                group: group(
                    status: status,
                    tipSHA: row.objectName,
                    pr: matched,
                    worktreePath: worktreePath,
                    worktreesEnumerated: inputs.worktreesEnumerated)))
        }

        branches.sort { $0.name < $1.name }

        let openElsewhere = isUnavailable
            ? []
            : PRStatusMapper.openPRsNotOnThisMac(
                authoredOpenPRs: inputs.authoredOpenPullRequests,
                localHeads: localHeads,
                localBranchNames: localBranchNames)

        return Repo(
            id: inputs.id,
            name: (inputs.path as NSString).lastPathComponent,
            path: inputs.path,
            remoteURL: inputs.remoteURL,
            githubSlug: slug,
            worktrees: inputs.worktrees,
            branches: branches,
            openPRsNotOnThisMac: openElsewhere,
            prAvailability: inputs.prAvailability,
            prFetchedAt: inputs.prFetchedAt,
            prLoadState: inputs.prLoadState,
            lastRefreshed: inputs.refreshedAt,
            errors: inputs.errors,
            isStale: inputs.isStale,
            lastActivity: branches.map(\.committerDate).max())
    }

    // MARK: - The join rules, one function each

    /// PLAN.md §5: worktrees join by exact branch name, and a worktree with no branch — a detached
    /// checkout — never joins (`noBranchWorktreeAppearsUnderRepoAndNoBranchClaimsIt`). The
    /// porcelain prints the full ref, so the key is its short name.
    static func worktreesByBranchName(_ worktrees: [Worktree]) -> [String: Worktree] {
        var byName: [String: Worktree] = [:]
        for worktree in worktrees {
            guard let ref = worktree.branch else { continue }
            let name = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            // git allows one checkout per branch, so a later record for the same name would be a
            // malformed porcelain; the first record wins rather than the last.
            if byName[name] == nil { byName[name] = worktree }
        }
        return byName
    }

    /// The owner half of the "Open PRs not on this Mac" key and of the PR match. Guessing the
    /// slug's owner for a branch that tracks something else would silently hide a fork PR
    /// (`openElsewhereKeyedByOwnerAndBranchNotBranchAlone`), so it is only ever resolved:
    /// `remoteOwners` for any configured remote whose URL `RepoLoader` read, and the slug for
    /// origin, whose URL is the slug (codex round 2, MAJOR 4 widened this past origin).
    static func upstreamOwnerLogin(
        upstream: Upstream?,
        slug: GitHubSlug?,
        remoteOwners: [String: String] = [:]
    ) -> String? {
        guard let upstream else { return nil }
        if let resolved = remoteOwners[upstream.remote] { return resolved }
        return upstream.remote == "origin" ? slug?.owner : nil
    }

    /// PLAN.md §5: `merged` = `prStatus == merged && tipSHA == headRefOid && worktreePath == nil`;
    /// `closedUnmerged` = `prStatus == closed`; everything else is active.
    ///
    /// All three clauses of the merged rule are safety, not cosmetics: a tip past the merged head
    /// is work that did not ship (`branchWithCommitsAfterItsMergeIsNotInMergedGroup`), and a
    /// branch checked out in a worktree cannot be deleted without removing the worktree first
    /// (`mergedBranchWithWorktreeStaysActive`).
    ///
    /// `worktreesEnumerated` is the fourth clause and the one that came from the codex review
    /// (MAJOR 12): when `git worktree list` failed, `worktreePath == nil` means "not known",
    /// not "no worktree holds it", and reading the first as the second put a checked-out branch
    /// under Merged. Unknown suppresses the group instead.
    static func group(
        status: PRStatus,
        tipSHA: String,
        pr: PRInfo?,
        worktreePath: String?,
        worktreesEnumerated: Bool = true
    ) -> BranchGroup {
        switch status {
        case .merged:
            guard worktreesEnumerated else { return .active }
            guard let pr, tipSHA == pr.headRefOid, worktreePath == nil else { return .active }
            return .merged
        case .closed:
            return .closedUnmerged
        default:
            return .active
        }
    }
}
