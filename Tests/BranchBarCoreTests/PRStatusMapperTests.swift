import Foundation
import Testing

@testable import BranchBarCore

// Acceptance tests for the pure PR mapping, written before the implementation. Two rules do the
// work here. The pill: a merged PR is merged whatever its draft flag says, and an empty
// `reviewDecision` is no decision rather than a decision named "". The join: a PR matches a
// branch by `headRefName` first, and the head owner only breaks ties between PRs that share a
// head — it never excludes, or every fork PR would vanish.

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

    /// The fork case: PR 110's head owner is `contributor` while the local branch tracks
    /// `tester`. Matching by head name first is what keeps it visible.
    @Test("forkOriginatedPRStillMatchesItsLocalBranch")
    func forkOriginatedPRStillMatchesItsLocalBranch() throws {
        let prs = try mixedPullRequests()

        let matched = try #require(PRStatusMapper.match(
            branchName: "fork-feature",
            upstreamOwnerLogin: "tester",
            in: prs
        ))

        #expect(matched.number == 110)
        #expect(matched.headRepositoryOwnerLogin == "contributor",
                "a differing head owner narrows a tie, it never excludes")
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

    @Test("noLocalBranchesLeavesEveryAuthoredOpenPRInTheGroup")
    func noLocalBranchesLeavesEveryAuthoredOpenPRInTheGroup() throws {
        let authored = try openAuthoredPRs()

        let notOnThisMac = PRStatusMapper.openPRsNotOnThisMac(authoredOpenPRs: authored, localHeads: [])

        #expect(notOnThisMac.count == authored.count)
    }
}
