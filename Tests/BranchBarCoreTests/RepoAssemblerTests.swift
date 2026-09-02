import Foundation
import Testing

@testable import BranchBarCore

/// Acceptance tests for `RepoAssembler`, packet 3.1, written from PLAN.md §5 ("Join rules"), the
/// §7 named invariants, and the OWNER comment on the stub.
///
/// The assembler is the one place a repo's shape is decided, so every rule here is a pure value
/// comparison: the inputs are the real parsers over the recorded and synthetic fixtures, and the
/// output is a `Repo`. PLAN.md §5 draws the boundary: grouping is decided here and only
/// **rendered** by `SnapshotPresenter`, so a group assertion belongs in this file and a wording
/// assertion never does.
@Suite("RepoAssembler — the pure join")
struct RepoAssemblerTests {

    // MARK: Fixtures and builders

    private static let repoPath = "/Users/tester/monorepo"
    private static let repoID = RepoID(commonDir: "/Users/tester/monorepo/.git")
    /// The synthetic PR fixture's repo: owner `tester`, so PR 110's `contributor` head owner is
    /// genuinely a fork.
    private static let remoteURL = "https://github.com/tester/demo.git"

    private static let mixedPRs: [PRInfo] = {
        (try? PRListDecoder.decode(Fixture.data("synthetic-gh-pr-list-mixed.json"))) ?? []
    }()

    private static let worktrees: [Worktree] = {
        (try? WorktreeListParser.parse(Fixture.data("synthetic-worktree-list-multi.txt"))) ?? []
    }()

    private static func pr(_ number: Int) -> PRInfo {
        guard let match = mixedPRs.first(where: { $0.number == number }) else {
            Issue.record("synthetic-gh-pr-list-mixed.json has no PR #\(number)")
            return PRInfo(number: number, url: "", state: "OPEN", isDraft: false, reviewDecision: "",
                          updatedAt: Date(timeIntervalSince1970: 0), baseRefName: "main",
                          headRefName: "", headRefOid: "", headRepositoryOwnerLogin: "")
        }
        return match
    }

    /// One `for-each-ref -- refs/heads` row, in the frozen field order.
    private static func ref(
        _ name: String,
        oid: String = String(repeating: "1", count: 40),
        date: Date = Date(timeIntervalSince1970: 1_788_000_000),
        upstream: String? = "origin",
        track: String = "",
        isHead: Bool = false
    ) -> ParsedBranchRef {
        ParsedBranchRef(
            refName: "refs/heads/\(name)",
            objectName: oid,
            committerDate: date,
            upstreamShort: upstream.map { "\($0)/\(name)" } ?? "",
            upstreamRemoteName: upstream ?? "",
            track: track,
            isHead: isHead
        )
    }

    private static func inputs(
        branchRefs: [ParsedBranchRef],
        remoteRefs: [ParsedRemoteRef] = [],
        worktrees: [Worktree] = [],
        worktreesEnumerated: Bool = true,
        fetchHeadObservedAt: Date? = nil,
        pushObservations: [String: ReflogObservation] = [:],
        pullRequests: [PRInfo] = [],
        authoredOpenPullRequests: [PRInfo] = [],
        queriedHeads: Set<String> = [],
        prAvailability: PRAvailability = .available,
        prLoadState: PRLoadState = .loaded,
        remoteURL: String? = RepoAssemblerTests.remoteURL
    ) -> RepoAssembler.Inputs {
        RepoAssembler.Inputs(
            id: repoID,
            path: repoPath,
            remoteURL: remoteURL,
            branchRefs: branchRefs,
            remoteRefs: remoteRefs,
            worktrees: worktrees,
            worktreesEnumerated: worktreesEnumerated,
            fetchHeadObservedAt: fetchHeadObservedAt,
            pushObservations: pushObservations,
            pullRequests: pullRequests,
            authoredOpenPullRequests: authoredOpenPullRequests,
            queriedHeads: queriedHeads,
            prAvailability: prAvailability,
            prLoadState: prLoadState
        )
    }

    private static func branch(_ repo: Repo, _ name: String) -> Branch? {
        repo.branches.first { $0.name == name }
    }

    // MARK: - Worktree join — PLAN.md §7 `noBranchWorktreeAppearsUnderRepoAndNoBranchClaimsIt`

    /// A detached worktree has no `branch` line, so it can never join a branch — but it is still
    /// part of the repo and PLAN.md §3 renders it as "Worktree at commit abc1234 (no branch)".
    /// The fixture carries two detached records among seven.
    @Test("noBranchWorktreeAppearsUnderRepoAndNoBranchClaimsIt")
    func noBranchWorktreeAppearsUnderRepoAndNoBranchClaimsIt() throws {
        let detachedPaths = Self.worktrees.filter { $0.branch == nil }.map(\.path)
        #expect(detachedPaths.count >= 2, "the fixture has a detached and a prunable-detached record")

        let repo = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref("main", isHead: true), Self.ref("worktree-spike")],
            worktrees: Self.worktrees
        ))

        #expect(repo.worktrees.count == Self.worktrees.count,
                "every worktree the porcelain printed appears under the repo, joined or not")
        for path in detachedPaths {
            #expect(!repo.branches.contains { $0.worktreePath == path },
                    "no branch may claim the branchless worktree at \(path)")
        }
    }

    /// A branch checked out in a linked worktree carries that worktree's path — the marker the
    /// row leads with — and is not the primary's checked-out branch.
    @Test("branchCheckedOutInLinkedWorktreeGetsThatPath")
    func branchCheckedOutInLinkedWorktreeGetsThatPath() throws {
        let repo = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref("main", isHead: true), Self.ref("worktree-spike")],
            worktrees: Self.worktrees
        ))

        let spike = try #require(Self.branch(repo, "worktree-spike"))
        #expect(spike.worktreePath == "/Users/tester/monorepo/.claude/worktrees/spike")
        #expect(spike.isCheckedOutInPrimary == false)

        // `%(HEAD)` is the primary's marker, because `for-each-ref` ran with `-C <primary>`.
        let main = try #require(Self.branch(repo, "main"))
        #expect(main.isCheckedOutInPrimary, "the fixture row for main carries the `*` marker")
        #expect(main.worktreePath == "/Users/tester/monorepo", "the primary is a worktree too")
    }

    /// PLAN.md §5: "exact branch name". A slash and a space are part of the name, and a name that
    /// merely ends with another name is a different branch.
    @Test("joinIsExactNameIncludingSlashes")
    func joinIsExactNameIncludingSlashes() throws {
        let repo = RepoAssembler.assemble(Self.inputs(
            branchRefs: [
                Self.ref("feature/spacing scale"),
                Self.ref("spacing scale"),
                Self.ref("feature/spacing"),
            ],
            worktrees: Self.worktrees
        ))

        let exact = try #require(Self.branch(repo, "feature/spacing scale"))
        #expect(exact.worktreePath == "/Users/tester/Developer/repos with spaces/design tokens")

        #expect(Self.branch(repo, "spacing scale")?.worktreePath == nil,
                "a suffix of the worktree's branch name is a different branch")
        #expect(Self.branch(repo, "feature/spacing")?.worktreePath == nil,
                "a prefix of the worktree's branch name is a different branch")
    }

    // MARK: - PR join — PLAN.md §7 `forkOriginatedPRStillMatchesItsLocalBranch`

    /// A clone **of the fork** — origin is `contributor/demo` — has a local `fork-feature` whose
    /// head on GitHub is `contributor:fork-feature`, which is PR 110's head. It gets its pill.
    ///
    /// The repo this test assembles changed with codex MAJOR 9. It used to be `tester/demo`, on
    /// the rule that a differing head owner never excludes — which is how an outside
    /// contributor's PR came to supply the pill and the link for `tester`'s own branch. The
    /// exclusion case is `singleSameNamedForkPRDoesNotAttachToAnUnrelatedLocalBranch` and is
    /// asserted below.
    @Test("forkOriginatedPRStillMatchesItsLocalBranch")
    func forkOriginatedPRStillMatchesItsLocalBranch() throws {
        let repo = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref("fork-feature")],
            pullRequests: Self.mixedPRs,
            queriedHeads: ["fork-feature"],
            remoteURL: "https://github.com/contributor/demo.git"
        ))

        let branch = try #require(Self.branch(repo, "fork-feature"))
        #expect(branch.pr?.number == 110)
        #expect(branch.pr?.headRepositoryOwnerLogin == "contributor")
        #expect(branch.prStatus == .open)

        // The same branch in `tester`'s own clone is a different head that shares a name, and the
        // head was queried, so it reads `none` rather than `notChecked`.
        let unrelated = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref("fork-feature")],
            pullRequests: Self.mixedPRs,
            queriedHeads: ["fork-feature"]
        ))
        let unrelatedBranch = try #require(Self.branch(unrelated, "fork-feature"))
        #expect(unrelatedBranch.pr == nil)
        #expect(unrelatedBranch.prStatus == PRStatus.none)
    }

    /// Several PRs on one head: the tie-break prefers the same owner, then OPEN, then the latest
    /// `updatedAt`. A merged PR from last month must not win over the open one that is live now,
    /// or the branch would sit in the Merged group while its review is still running.
    @Test("openPRPreferredOverMergedForSameHead")
    func openPRPreferredOverMergedForSameHead() throws {
        let head = "shared-head"
        let merged = PRInfo(
            number: 201, url: "https://github.com/tester/demo/pull/201", state: "MERGED",
            isDraft: false, reviewDecision: "APPROVED",
            mergedAt: Date(timeIntervalSince1970: 1_786_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_786_000_000),
            baseRefName: "main", headRefName: head,
            headRefOid: String(repeating: "1", count: 40), headRepositoryOwnerLogin: "tester",
            mergeCommitOid: String(repeating: "9", count: 40))
        let open = PRInfo(
            number: 202, url: "https://github.com/tester/demo/pull/202", state: "OPEN",
            isDraft: false, reviewDecision: "",
            updatedAt: Date(timeIntervalSince1970: 1_787_000_000),
            baseRefName: "main", headRefName: head,
            headRefOid: String(repeating: "1", count: 40), headRepositoryOwnerLogin: "tester")

        let repo = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref(head)],
            pullRequests: [merged, open],
            queriedHeads: [head]
        ))

        let branch = try #require(Self.branch(repo, head))
        #expect(branch.pr?.number == 202, "OPEN wins the tie-break")
        #expect(branch.prStatus == .open)
        #expect(branch.group == .active, "and the branch stays out of the Merged group")

        // The fixture's own shared head (108 CLOSED, 109 OPEN) resolves the same way.
        let fixtureRepo = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref(head)],
            pullRequests: Self.mixedPRs,
            queriedHeads: [head]
        ))
        #expect(Self.branch(fixtureRepo, head)?.pr?.number == 109)
    }

    // MARK: - PLAN.md §7 `unqueriedBranchIsNotCheckedNeverNone`

    /// The distinction that came from the codex review: `none` means "we asked and there is no
    /// PR"; a branch whose head was never queried — past the cap of 20, past the deadline — is
    /// `notChecked`. Mapping the second to the first would tell the user a PR does not exist when
    /// the app never looked.
    @Test("unqueriedBranchIsNotCheckedNeverNone")
    func unqueriedBranchIsNotCheckedNeverNone() throws {
        let empty = try PRListDecoder.decode(Fixture.data("synthetic-gh-pr-list-empty.json"))
        #expect(empty.isEmpty)

        let repo = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref("asked-about"), Self.ref("never-asked")],
            pullRequests: empty,
            queriedHeads: ["asked-about"]
        ))

        // Unwrapped rather than compared through an optional: `PRStatus?.none` would read as nil.
        let asked = try #require(Self.branch(repo, "asked-about"))
        let unasked = try #require(Self.branch(repo, "never-asked"))
        #expect(asked.prStatus == PRStatus.none, "queried and answered with nothing is `none`")
        #expect(unasked.prStatus == .notChecked, "never queried is `notChecked`, never `none`")
    }

    /// PLAN.md §5a: a collapsed repo renders "PR status loads when expanded", so a `notLoaded`
    /// load state has to reach every branch as `notLoaded` rather than as a claim about PRs.
    @Test("notLoadedPRStateMakesEveryBranchNotLoaded")
    func notLoadedPRStateMakesEveryBranchNotLoaded() throws {
        let repo = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref("signed-off"), Self.ref("abandoned")],
            pullRequests: Self.mixedPRs,
            queriedHeads: ["signed-off", "abandoned"],
            prLoadState: .notLoaded
        ))

        #expect(repo.branches.allSatisfy { $0.prStatus == .notLoaded })
        #expect(repo.branches.allSatisfy { $0.pr == nil }, "nothing was loaded, so no PR is attached")
    }

    /// `ghMissingMakesEveryBranchUnavailableWithoutThrowing`, at the join: an unavailable
    /// `PRAvailability` is a repo-wide fact. Every branch reads `unavailable` — the reason names
    /// the one action that fixes it — and "Open PRs not on this Mac" is empty rather than
    /// half-populated from a stale list.
    @Test("unavailableAvailabilityForcesUnavailableOnEveryBranch")
    func unavailableAvailabilityForcesUnavailableOnEveryBranch() throws {
        let repo = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref("signed-off"), Self.ref("shipped"), Self.ref("no-pr")],
            pullRequests: Self.mixedPRs,
            authoredOpenPullRequests: [Self.pr(105), Self.pr(110)],
            queriedHeads: ["signed-off", "shipped", "no-pr"],
            prAvailability: .unavailable(.ghNotInstalled, detail: "gh: command not found")
        ))

        #expect(repo.branches.allSatisfy { $0.prStatus == .unavailable })
        #expect(repo.branches.allSatisfy { $0.group == .active },
                "with no PR facts, nothing can be grouped as merged or closed")
        #expect(repo.openPRsNotOnThisMac.isEmpty)
        #expect(repo.prAvailability == .unavailable(.ghNotInstalled, detail: "gh: command not found"))
    }

    // MARK: - Groups — PLAN.md §5 `merged = prStatus == merged && tipSHA == headRefOid && worktreePath == nil`

    /// The safety half of the merged rule. PR 106 merged head `shipped` at 6666…; a local commit
    /// after the merge moves the tip, and the branch is no longer the thing that shipped. Putting
    /// it in Merged would invite deleting unmerged work.
    @Test("branchWithCommitsAfterItsMergeIsNotInMergedGroup")
    func branchWithCommitsAfterItsMergeIsNotInMergedGroup() throws {
        let merged = Self.pr(106)
        #expect(merged.state == "MERGED")

        let moved = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref("shipped", oid: String(repeating: "e", count: 40))],
            pullRequests: Self.mixedPRs,
            queriedHeads: ["shipped"]
        ))
        let movedBranch = try #require(Self.branch(moved, "shipped"))
        #expect(movedBranch.prStatus == .merged, "the PR is still merged…")
        #expect(movedBranch.group == .active, "…but the branch has moved past it")

        let atMerge = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref("shipped", oid: merged.headRefOid)],
            pullRequests: Self.mixedPRs,
            queriedHeads: ["shipped"]
        ))
        #expect(Self.branch(atMerge, "shipped")?.group == .merged,
                "tip still at the merged head, and no worktree, so it is Merged")
    }

    /// PR 107 is CLOSED with a null `mergeCommit`. Closed without merging is its own group and its
    /// own copy; labelling it Merged would claim work shipped that never did.
    @Test("closedUnmergedBranchIsNotLabelledMerged")
    func closedUnmergedBranchIsNotLabelledMerged() throws {
        let closed = Self.pr(107)
        #expect(closed.state == "CLOSED")
        #expect(closed.mergeCommitOid == nil)

        let repo = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref("abandoned", oid: closed.headRefOid)],
            pullRequests: Self.mixedPRs,
            queriedHeads: ["abandoned"]
        ))

        let branch = try #require(Self.branch(repo, "abandoned"))
        #expect(branch.prStatus == .closed)
        #expect(branch.group == .closedUnmerged)
        #expect(branch.group != .merged)
    }

    /// The third clause of the merged rule. A branch checked out in a worktree cannot be deleted
    /// without removing the worktree first, so it stays in "Branches and worktrees" where the
    /// worktree marker is visible, whatever its PR says.
    @Test("mergedBranchWithWorktreeStaysActive")
    func mergedBranchWithWorktreeStaysActive() throws {
        let merged = Self.pr(106)
        let worktree = Worktree(
            path: "/Users/tester/monorepo/.claude/worktrees/shipped",
            headSHA: merged.headRefOid,
            branch: "refs/heads/shipped")

        let repo = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref("shipped", oid: merged.headRefOid)],
            worktrees: [worktree],
            pullRequests: Self.mixedPRs,
            queriedHeads: ["shipped"]
        ))

        let branch = try #require(Self.branch(repo, "shipped"))
        #expect(branch.prStatus == .merged)
        #expect(branch.worktreePath == worktree.path)
        #expect(branch.group == .active, "a checked-out branch is never in the Merged group")
    }

    // MARK: - Open PRs not on this Mac — PLAN.md §7

    /// An author-@me PR whose head exists locally is not "not on this Mac". PR 105's head
    /// `signed-off` is a local branch tracking `origin`, whose owner resolves from the slug, so
    /// the pair matches and the PR is excluded.
    @Test("openPRsNotOnThisMacExcludesHeadsThatExistLocally")
    func openPRsNotOnThisMacExcludesHeadsThatExistLocally() throws {
        let repo = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref("signed-off")],
            pullRequests: Self.mixedPRs,
            authoredOpenPullRequests: [Self.pr(105), Self.pr(103)],
            queriedHeads: ["signed-off"]
        ))

        #expect(!repo.openPRsNotOnThisMac.contains { $0.number == 105 },
                "its head is checked out on this Mac")
        #expect(repo.openPRsNotOnThisMac.map(\.number) == [103],
                "the PR whose head has no local branch is the only one left")
    }

    /// PLAN.md §7's key is owner **and** branch, and `PRStatusMapperTests` still pins that key.
    /// At the assembler the group is now the conservative one codex MAJOR 10 asked for: the
    /// heading claims there is no branch of that name on this Mac, and a local `fork-feature`
    /// makes that claim false whoever owns the PR's head. What the owner key still buys is a
    /// repo whose local branches share **no** name with the PR.
    @Test("openElsewhereKeyedByOwnerAndBranchNotBranchAlone")
    func openElsewhereKeyedByOwnerAndBranchNotBranchAlone() throws {
        let fork = Self.pr(110)
        #expect(fork.headRepositoryOwnerLogin == "contributor")

        // Was `== [110]` before codex MAJOR 10: a same-named local branch is on this Mac, and a
        // group headed "not on this Mac" may not list it.
        let repo = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref("fork-feature")],
            pullRequests: [],
            authoredOpenPullRequests: [fork],
            queriedHeads: ["fork-feature"]
        ))
        #expect(repo.openPRsNotOnThisMac.isEmpty,
                "a branch of that name is on this Mac, whoever owns the PR's head")

        // No branch of that name: the PR is genuinely elsewhere, whatever the local branches are
        // called or whom they track.
        let elsewhere = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref("main")],
            authoredOpenPullRequests: [fork],
            queriedHeads: ["main"]
        ))
        #expect(elsewhere.openPRsNotOnThisMac.map(\.number) == [110])

        // Same branch name and the same owner: on this Mac by either test.
        let sameOwner = PRInfo(
            number: 111, url: "https://github.com/tester/demo/pull/111", state: "OPEN",
            isDraft: false, reviewDecision: "",
            updatedAt: fork.updatedAt, baseRefName: "main", headRefName: "fork-feature",
            headRefOid: fork.headRefOid, headRepositoryOwnerLogin: "tester")
        let ownedRepo = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref("fork-feature")],
            authoredOpenPullRequests: [sameOwner],
            queriedHeads: ["fork-feature"]
        ))
        #expect(ownedRepo.openPRsNotOnThisMac.isEmpty)
    }

    /// codex MAJOR 10. A local branch with no upstream contributes no owner, so it contributed no
    /// `LocalHead` — and an authored PR with that exact branch name was listed under a heading
    /// saying the branch is not on this Mac. It is; it just tracks nothing.
    @Test("localBranchWithoutUpstreamStillExcludesSameNamedAuthoredPR")
    func localBranchWithoutUpstreamStillExcludesSameNamedAuthoredPR() throws {
        let authored = Self.pr(105)
        #expect(authored.headRefName == "signed-off")

        let repo = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref("signed-off", upstream: nil)],
            authoredOpenPullRequests: [authored, Self.pr(103)],
            queriedHeads: ["signed-off"]
        ))

        let branch = try #require(Self.branch(repo, "signed-off"))
        #expect(branch.upstream == nil, "the local branch tracks nothing, so it names no owner")
        #expect(!repo.openPRsNotOnThisMac.contains { $0.number == 105 },
                "and yet the branch is sitting on this Mac")
        #expect(repo.openPRsNotOnThisMac.map(\.number) == [103])

        // A branch tracking some remote other than `origin` names no owner either.
        let upstreamElsewhere = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref("signed-off", upstream: "fork")],
            authoredOpenPullRequests: [authored],
            queriedHeads: ["signed-off"]
        ))
        #expect(upstreamElsewhere.openPRsNotOnThisMac.isEmpty)
    }

    /// codex MAJOR 12, the grouping half. When `git worktree list` fails there is no worktree
    /// list, and `worktreePath == nil` then means "not known" rather than "no worktree holds it".
    /// Reading the first as the second put a branch that cannot be deleted — its worktree is
    /// checked out — under the heading whose whole purpose is "this one is finished with".
    @Test("worktreeEnumerationFailureSuppressesMergedGroup")
    func worktreeEnumerationFailureSuppressesMergedGroup() throws {
        let merged = Self.pr(106)
        #expect(merged.state == "MERGED")

        let enumerated = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref("shipped", oid: merged.headRefOid)],
            pullRequests: Self.mixedPRs,
            queriedHeads: ["shipped"]
        ))
        #expect(Self.branch(enumerated, "shipped")?.group == .merged, "the baseline")

        let unknown = RepoAssembler.assemble(Self.inputs(
            branchRefs: [Self.ref("shipped", oid: merged.headRefOid)],
            worktrees: [],
            worktreesEnumerated: false,
            pullRequests: Self.mixedPRs,
            queriedHeads: ["shipped"]
        ))
        let branch = try #require(Self.branch(unknown, "shipped"))
        #expect(branch.prStatus == .merged, "the PR is still merged…")
        #expect(branch.group == .active, "…but nothing may claim no worktree holds the branch")
        #expect(unknown.branches.allSatisfy { $0.group != .merged },
                "no branch at all reaches the Merged group while the worktrees are unknown")
    }

    // MARK: - Order and repo-level facts

    /// PLAN.md §5a item 3: rows fill in but never reorder mid-refresh, which starts with a total
    /// order that does not depend on the order `for-each-ref` happened to print.
    @Test("branchesSortedByName")
    func branchesSortedByName() throws {
        let repo = RepoAssembler.assemble(Self.inputs(
            branchRefs: [
                Self.ref("zeta"),
                Self.ref("feature/nested"),
                Self.ref("alpha"),
                Self.ref("Beta"),
                Self.ref("feature/anchor"),
            ]
        ))

        #expect(repo.branches.map(\.name) == repo.branches.map(\.name).sorted())
        #expect(repo.branches.map(\.name) == ["Beta", "alpha", "feature/anchor", "feature/nested", "zeta"])
    }

    /// Repo-level facts the section header and the section order stand on: the name is the last
    /// path component, the slug is parsed from the remote URL, and `lastActivity` is the newest
    /// committer date across the branches.
    @Test("repoCarriesNameSlugAndNewestCommitterDate")
    func repoCarriesNameSlugAndNewestCommitterDate() throws {
        let newest = Date(timeIntervalSince1970: 1_788_310_842)
        let repo = RepoAssembler.assemble(Self.inputs(
            branchRefs: [
                Self.ref("main", date: Date(timeIntervalSince1970: 1_787_000_000)),
                Self.ref("newer", date: newest),
                Self.ref("older", date: Date(timeIntervalSince1970: 1_700_000_000)),
            ]
        ))

        #expect(repo.name == "monorepo")
        #expect(repo.path == Self.repoPath)
        #expect(repo.id == Self.repoID)
        #expect(repo.githubSlug == GitHubSlug(host: "github.com", owner: "tester", name: "demo"))
        #expect(repo.lastActivity == newest)
    }

    /// A tag that shares a branch name is not a branch. The frozen invocation is scoped to
    /// `refs/heads`, and the assembler must not turn a `refs/tags/main` row into a second `main`.
    @Test("tagRefIsNotABranch")
    func tagRefIsNotABranch() throws {
        let rows = try ForEachRefParser.parseBranches(Fixture.text("synthetic-for-each-ref-heads-mixed.txt"))
        #expect(rows.contains { $0.refName == "refs/tags/main" }, "the fixture carries the collision")

        let repo = RepoAssembler.assemble(Self.inputs(branchRefs: rows))

        #expect(repo.branches.filter { $0.name == "main" }.count == 1)
        #expect(!repo.branches.contains { $0.name.hasPrefix("refs/") })
    }

    /// The push facts travel through `PushInfoDeriver` against the matching remote-tracking ref,
    /// so the assembler is where a branch's reflog observation meets its tip OID.
    @Test("pushObservationIsDerivedAgainstTheMatchingRemoteTip")
    func pushObservationIsDerivedAgainstTheMatchingRemoteTip() throws {
        let rows = try ForEachRefParser.parseBranches(Fixture.text("synthetic-for-each-ref-heads-mixed.txt"))
        let tips = try ForEachRefParser.parseRemoteRefs(Fixture.text("synthetic-for-each-ref-remotes.txt"))
        let observation = try #require(
            ReflogFileReader.parse(Fixture.text("synthetic-reflog-push-oid-differs-from-tip.txt")))

        let repo = RepoAssembler.assemble(Self.inputs(
            branchRefs: rows,
            remoteRefs: tips,
            pushObservations: ["ahead-two": observation]
        ))

        let aheadTwo = try #require(Self.branch(repo, "ahead-two"))
        #expect(aheadTwo.push.source == .reflogObserved)
        #expect(aheadTwo.push.observedPushOID == observation.newOID)
        #expect(aheadTwo.push.originMovedSince, "origin/ahead-two points at 1010…, not b…")
        #expect(aheadTwo.push.aheadOfLastKnownRemote == 2)

        let noUpstream = try #require(Self.branch(repo, "no-upstream"))
        #expect(noUpstream.push.source == .none)
        #expect(noUpstream.push.aheadOfLastKnownRemote == nil)

        let main = try #require(Self.branch(repo, "main"))
        #expect(main.push.source == .tipCommitDate, "no observation for main, but its tip is known")
        // Was `remoteRefObservedAt` until codex MAJOR 7: the tip's committer date is a fact about
        // the commit, and "last seen" is a fact about this clone. They are two fields now, and
        // only `FETCH_HEAD`'s modification date fills the second.
        #expect(main.push.remoteTipCommitDate == Date(timeIntervalSince1970: 1_788_310_842))
        #expect(main.push.remoteRefObservedAt == nil, "no FETCH_HEAD was handed in")

        let fetchedAt = Date(timeIntervalSince1970: 1_788_400_000)
        let observed = RepoAssembler.assemble(Self.inputs(
            branchRefs: rows,
            remoteRefs: tips,
            fetchHeadObservedAt: fetchedAt,
            pushObservations: ["ahead-two": observation]
        ))
        #expect(observed.branches.filter { $0.push.source != PushInfo.Source.none }
            .allSatisfy { $0.push.remoteRefObservedAt == fetchedAt },
                "FETCH_HEAD is one fact per repo, so every row with a push story carries the same one")
    }
}
