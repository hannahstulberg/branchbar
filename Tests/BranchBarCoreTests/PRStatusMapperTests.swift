import Foundation
import Testing

@testable import BranchBarCore

// Acceptance tests for the pure PR mapping, written before the implementation. Two rules do the
// work here. The pill: a merged PR is merged whatever its draft flag says, and an empty
// `reviewDecision` is no decision rather than a decision named "". The join: a PR matches a
// branch by `headRefName` first, and by an owner the branch can claim — the codex pre-ship
// review (MAJOR 9) made owner a constraint rather than only a tie-break, because a stranger's
// fork PR called `main` was supplying the pill and the link for an unrelated local branch.

/// Decoded once per test from the fixture, so these tests read the same rows `gh` writes.
private func mixedPullRequests() throws -> [PRInfo] {
    try PRListDecoder.decode(Fixture.data("synthetic-gh-pr-list-mixed.json"))
}

private func pr(_ number: Int, in prs: [PRInfo]) throws -> PRInfo {
    try #require(prs.first { $0.number == number }, "PR \(number) is missing from the fixture")
}

/// A row shaped like the ones `gh` returns, for the two cases the fixtures cannot hold: a merged
/// PR whose draft flag is still set, and an isolated undecided PR.
private func makePR(
    number: Int = 1,
    state: String,
    isDraft: Bool = false,
    reviewDecision: String = "",
    headRefName: String = "feature-x",
    headRepositoryOwnerLogin: String = "tester"
) -> PRInfo {
    PRInfo(
        number: number,
        url: "https://github.com/tester/demo/pull/\(number)",
        state: state,
        isDraft: isDraft,
        reviewDecision: reviewDecision,
        mergedAt: state == "MERGED" ? Date(timeIntervalSince1970: 1_786_000_000) : nil,
        updatedAt: Date(timeIntervalSince1970: 1_786_000_000),
        baseRefName: "main",
        headRefName: headRefName,
        headRefOid: "1111111111111111111111111111111111111111",
        headRepositoryOwnerLogin: headRepositoryOwnerLogin,
        mergeCommitOid: state == "MERGED" ? "9999999999999999999999999999999999999999" : nil
    )
}

@Suite("PRStatusMapper maps a PR to its pill")
struct PRStatusMapperPillTests {

    @Test("everyPillStateComesFromStateDraftAndReviewDecision")
    func everyPillStateComesFromStateDraftAndReviewDecision() throws {
        let prs = try mixedPullRequests()

        #expect(PRStatusMapper.status(for: try pr(101, in: prs)) == .draft)
        #expect(PRStatusMapper.status(for: try pr(102, in: prs)) == .open)
        #expect(PRStatusMapper.status(for: try pr(104, in: prs)) == .changesRequested)
        #expect(PRStatusMapper.status(for: try pr(105, in: prs)) == .approved)
        #expect(PRStatusMapper.status(for: try pr(106, in: prs)) == .merged)
        #expect(PRStatusMapper.status(for: try pr(107, in: prs)) == .closed)
    }

    /// PLAN.md §5: `gh` returns `""`, not null, when nobody has reviewed. An empty string that
    /// reached the pill as a decision would render a branch as reviewed when it is not.
    @Test("emptyReviewDecisionStringIsNotAReviewDecision")
    func emptyReviewDecisionStringIsNotAReviewDecision() throws {
        #expect(PRStatusMapper.status(for: makePR(state: "OPEN", reviewDecision: "")) == .open)
        #expect(PRStatusMapper.status(for: makePR(state: "OPEN", reviewDecision: "REVIEW_REQUIRED")) == .open)

        let prs = try mixedPullRequests()
        let undecided = try pr(103, in: prs)

        #expect(undecided.reviewDecision == "")
        #expect(PRStatusMapper.status(for: undecided) == .open,
                "no decision yet is open, never approved and never changesRequested")
        #expect(PRStatusMapper.status(for: try pr(102, in: prs)) == .open,
                "REVIEW_REQUIRED is the same open pill")

        // The recorded list is 17 real PRs, every one of them with an empty reviewDecision.
        let recorded = try PRListDecoder.decode(Fixture.data("recorded-gh-pr-list-hannah-personal-agent.json"))
        let recordedMerged = try #require(recorded.first { $0.state == "MERGED" })
        #expect(recordedMerged.reviewDecision == "")
        #expect(PRStatusMapper.status(for: recordedMerged) == .merged)
    }

    /// A PR can be merged while `isDraft` is still true on the row `gh` returns. Merged wins:
    /// the branch shipped, and a "draft" pill on shipped work is the wrong story.
    @Test("mergedBeatsDraftFlag")
    func mergedBeatsDraftFlag() throws {
        let mergedDraft = makePR(state: "MERGED", isDraft: true)
        #expect(PRStatusMapper.status(for: mergedDraft) == .merged,
                "a merged PR is merged whatever isDraft says")

        var fromFixture = try pr(106, in: try mixedPullRequests())
        fromFixture.isDraft = true
        #expect(fromFixture.state == "MERGED")
        #expect(PRStatusMapper.status(for: fromFixture) == .merged)
    }

    @Test("closedUnmergedIsClosedNotMerged")
    func closedUnmergedIsClosedNotMerged() throws {
        let abandoned = try pr(107, in: try mixedPullRequests())

        #expect(abandoned.state == "CLOSED")
        #expect(abandoned.mergedAt == nil)
        #expect(abandoned.mergeCommitOid == nil)
        #expect(PRStatusMapper.status(for: abandoned) == .closed)
    }
}

@Suite("PRStatusMapper joins a branch to its PR by head name first")
struct PRStatusMapperMatchTests {

    /// The fork case: PR 110's head is `contributor:fork-feature`, and the local branch that
    /// belongs to it is one tracking that fork. It still gets its pill.
    ///
    /// The owner this test passes changed with codex MAJOR 9. It used to be `tester` — the repo's
    /// own owner — on the rule that a differing head owner narrows a tie and never excludes, which
    /// is precisely how an outside contributor's PR ended up attached to someone else's branch.
    /// The invariant it is named for survives: a PR raised from a fork matches the local branch
    /// that tracks that fork.
    @Test("forkOriginatedPRStillMatchesItsLocalBranch")
    func forkOriginatedPRStillMatchesItsLocalBranch() throws {
        let prs = try mixedPullRequests()

        let matched = try #require(PRStatusMapper.match(
            branchName: "fork-feature",
            upstreamOwnerLogin: "contributor",
            repoOwnerLogin: "tester",
            in: prs
        ))

        #expect(matched.number == 110)
        #expect(matched.headRepositoryOwnerLogin == "contributor")
    }

    /// codex MAJOR 9, the case the old rule got wrong. A local `fork-feature` that tracks
    /// `tester`'s own origin is not the head of `contributor:fork-feature`; they are two branches
    /// that share a name. With one candidate and no owner check, that PR supplied the pill, the
    /// link, and — if it had been merged — the Merged group.
    @Test("singleSameNamedForkPRDoesNotAttachToAnUnrelatedLocalBranch")
    func singleSameNamedForkPRDoesNotAttachToAnUnrelatedLocalBranch() throws {
        let prs = try mixedPullRequests()
        let fork = try pr(110, in: prs)
        #expect(fork.headRepositoryOwnerLogin == "contributor")
        #expect(prs.filter { $0.headRefName == "fork-feature" }.count == 1, "exactly one candidate")

        #expect(PRStatusMapper.match(
            branchName: "fork-feature",
            upstreamOwnerLogin: "tester",
            repoOwnerLogin: "tester",
            in: prs) == nil,
            "the local branch's head on GitHub is tester:fork-feature, which has no PR")

        // Owner unknown on the branch falls back to the repo's owner, which is the only owner the
        // branch could plausibly have.
        #expect(PRStatusMapper.match(
            branchName: "fork-feature",
            upstreamOwnerLogin: nil,
            repoOwnerLogin: "tester",
            in: prs) == nil)

        // With neither owner known — a remote this app never parsed — there is no basis to
        // reject, and the head name alone still matches.
        #expect(PRStatusMapper.match(
            branchName: "fork-feature",
            upstreamOwnerLogin: nil,
            repoOwnerLogin: nil,
            in: prs)?.number == 110)
    }

    /// Two PRs share `shared-head`: 108 is CLOSED and older, 109 is OPEN and newer. With the same
    /// owner on both, the tie-break falls to OPEN.
    @Test("severalPRsOnOneHeadBreakTheTieOnOwnerThenOpenThenNewest")
    func severalPRsOnOneHeadBreakTheTieOnOwnerThenOpenThenNewest() throws {
        let prs = try mixedPullRequests()

        let matched = try #require(PRStatusMapper.match(
            branchName: "shared-head",
            upstreamOwnerLogin: "tester",
            in: prs
        ))

        #expect(matched.number == 109)
        #expect(matched.state == "OPEN")
    }

    /// codex round 2, MAJOR 4. GitHub logins are case-insensitive — `Contributor` and
    /// `contributor` are one account — and `gh` prints whatever casing the account was created
    /// with, while `remote.origin.url` carries whatever casing the clone URL was typed with.
    /// Comparing the two as bytes rejected the user's own PR and left the row reading "No PR"
    /// beside an open one.
    @Test("ownerComparisonIsCaseInsensitive")
    func ownerComparisonIsCaseInsensitive() throws {
        let prs = try mixedPullRequests()
        let fork = try pr(110, in: prs)
        #expect(fork.headRepositoryOwnerLogin == "contributor")

        #expect(PRStatusMapper.match(
            branchName: "fork-feature",
            upstreamOwnerLogin: "Contributor",
            repoOwnerLogin: "Tester",
            in: prs)?.number == 110,
            "a differently-cased login is the same account")

        // The repo-owner fallback is compared the same way.
        #expect(PRStatusMapper.match(
            branchName: "signed-off",
            upstreamOwnerLogin: nil,
            repoOwnerLogin: "TESTER",
            in: prs)?.number == 105)

        // Case-insensitive never means "everyone matches": a different owner still loses.
        #expect(PRStatusMapper.match(
            branchName: "fork-feature",
            upstreamOwnerLogin: "TESTER",
            repoOwnerLogin: "tester",
            in: prs) == nil)

        // The open-elsewhere key is the same comparison, so a differently-cased local head still
        // keeps the PR out of the "not on this Mac" group.
        let localHeads: Set<PRStatusMapper.LocalHead> = [
            PRStatusMapper.LocalHead(ownerLogin: "Contributor", branchName: "fork-feature")
        ]
        #expect(PRStatusMapper.openPRsNotOnThisMac(
            authoredOpenPRs: [fork], localHeads: localHeads).isEmpty)
    }

    @Test("aBranchNoPRSharesAHeadWithMatchesNothing")
    func aBranchNoPRSharesAHeadWithMatchesNothing() throws {
        let prs = try mixedPullRequests()

        #expect(PRStatusMapper.match(branchName: "local-only", upstreamOwnerLogin: "tester", in: prs) == nil)
        #expect(PRStatusMapper.match(branchName: "local-only", upstreamOwnerLogin: nil, in: prs) == nil)
    }

    @Test("aBranchWithNoUpstreamOwnerStillMatchesOnHeadName")
    func aBranchWithNoUpstreamOwnerStillMatchesOnHeadName() throws {
        let prs = try mixedPullRequests()

        let matched = try #require(PRStatusMapper.match(
            branchName: "signed-off",
            upstreamOwnerLogin: nil,
            in: prs
        ))
        #expect(matched.number == 105)
    }
}

@Suite("PRStatusMapper keys open-elsewhere PRs on owner and branch together")
struct PRStatusMapperOpenElsewhereTests {

    private func openAuthoredPRs() throws -> [PRInfo] {
        try mixedPullRequests().filter { $0.state == "OPEN" }
    }

    /// PLAN.md §3: a local `feature-x` tracking `origin` must not hide the user's fork PR also
    /// named `feature-x`. Keyed on branch alone, PR 110 would disappear from the group.
    @Test("openElsewhereKeyedByOwnerAndBranchNotBranchAlone")
    func openElsewhereKeyedByOwnerAndBranchNotBranchAlone() throws {
        let authored = try openAuthoredPRs()
        let localHeads: Set<PRStatusMapper.LocalHead> = [
            PRStatusMapper.LocalHead(ownerLogin: "tester", branchName: "fork-feature")
        ]

        let notOnThisMac = PRStatusMapper.openPRsNotOnThisMac(
            authoredOpenPRs: authored,
            localHeads: localHeads
        )

        #expect(notOnThisMac.contains { $0.number == 110 },
                "the local branch belongs to tester; PR 110's head is contributor's, so it is elsewhere")
    }

    @Test("openPRsNotOnThisMacExcludesHeadsThatExistLocally")
    func openPRsNotOnThisMacExcludesHeadsThatExistLocally() throws {
        let authored = try openAuthoredPRs()
        let localHeads: Set<PRStatusMapper.LocalHead> = [
            PRStatusMapper.LocalHead(ownerLogin: "tester", branchName: "draft-branch"),
            PRStatusMapper.LocalHead(ownerLogin: "tester", branchName: "signed-off"),
            PRStatusMapper.LocalHead(ownerLogin: "contributor", branchName: "fork-feature")
        ]

        let notOnThisMac = PRStatusMapper.openPRsNotOnThisMac(
            authoredOpenPRs: authored,
            localHeads: localHeads
        )
        let numbers = Set(notOnThisMac.map(\.number))

        #expect(numbers.contains(101) == false, "draft-branch is checked out here")
        #expect(numbers.contains(105) == false, "signed-off is checked out here")
        #expect(numbers.contains(110) == false, "the same owner and the same branch is a local head")
        #expect(numbers == [102, 103, 104, 109], "everything else the author has open lives only on GitHub")
    }

    /// codex MAJOR 10. A local branch with no upstream, or one tracking a remote other than
    /// `origin`, contributes no owner and therefore no `LocalHead` — so an authored PR with that
    /// exact branch name landed under a heading that says the branch is not on this Mac. The
    /// name-only exclusion is deliberately conservative: it can hide a genuine fork PR, and the
    /// group's note ("with no branch of that name on this Mac") is what it now promises.
    @Test("localBranchWithoutUpstreamStillExcludesSameNamedAuthoredPR")
    func localBranchWithoutUpstreamStillExcludesSameNamedAuthoredPR() throws {
        let authored = try openAuthoredPRs()
        #expect(authored.contains { $0.headRefName == "draft-branch" })

        // No upstream anywhere, so `localHeads` is empty — the state the old key could not see.
        let notOnThisMac = PRStatusMapper.openPRsNotOnThisMac(
            authoredOpenPRs: authored,
            localHeads: [],
            localBranchNames: ["draft-branch", "fork-feature"]
        )
        let numbers = Set(notOnThisMac.map(\.number))

        #expect(!numbers.contains(101), "draft-branch is a branch on this Mac, tracked or not")
        #expect(!numbers.contains(110), "and so is fork-feature, whoever owns the PR's head")
        #expect(numbers == [102, 103, 104, 105, 109],
                "everything the author has open under a name no local branch carries")
    }

    @Test("noLocalBranchesLeavesEveryAuthoredOpenPRInTheGroup")
    func noLocalBranchesLeavesEveryAuthoredOpenPRInTheGroup() throws {
        let authored = try openAuthoredPRs()

        let notOnThisMac = PRStatusMapper.openPRsNotOnThisMac(authoredOpenPRs: authored, localHeads: [])

        #expect(notOnThisMac.count == authored.count)
    }
}
