import Foundation

/// Pure mapping from a matched PR to the pill, and from a branch to its PR.
///
/// PLAN.md §5 join rule: match by `headRefName` **first**, with `headRepositoryOwnerLogin`
/// breaking a tie between PRs that share a head (prefer same owner, then OPEN, then latest
/// `updatedAt`).
///
/// The codex pre-ship review (MAJOR 9) narrowed the first half: owner is now a **constraint**, not
/// only a tie-break. Ignoring it meant a stranger's fork PR called `main` or `feature-x` supplied
/// the pill and the link for an unrelated local branch. A fork PR still matches the local branch
/// that tracks that fork (`forkOriginatedPRStillMatchesItsLocalBranch`) — what no longer matches is
/// a PR whose head belongs to someone else.
public enum PRStatusMapper {

    /// Maps a PR to its pill state: merged `state` → `.merged`, closed and not merged →
    /// `.closed`, open and `isDraft` → `.draft`, open with `reviewDecision` of
    /// `CHANGES_REQUESTED` → `.changesRequested` and `APPROVED` → `.approved`, and any other open
    /// PR (including `REVIEW_REQUIRED` and the empty string) → `.open`.
    public static func status(for pr: PRInfo) -> PRStatus {
        switch pr.state.uppercased() {
        case "MERGED":
            // `mergedBeatsDraftFlag`: the branch shipped, whatever the draft flag still says.
            return .merged
        case "CLOSED":
            return .closed
        default:
            if pr.isDraft { return .draft }
            switch pr.reviewDecision.uppercased() {
            case "APPROVED":
                return .approved
            case "CHANGES_REQUESTED":
                return .changesRequested
            default:
                // `emptyReviewDecisionStringIsNotAReviewDecision`: "" and REVIEW_REQUIRED are the
                // same "nobody has decided" pill.
                return .open
            }
        }
    }

    /// Returns the PR whose `headRefName` equals `branchName` **and** whose head owner this branch
    /// can claim, breaking a tie between several such PRs by preferring an OPEN state and then the
    /// latest `updatedAt`; returns nil when no PR qualifies.
    ///
    /// Which owner a branch can claim, in order (codex MAJOR 9):
    ///
    /// - `upstreamOwnerLogin` when the branch tracks a remote whose owner this app resolved. That
    ///   is the branch's own head on GitHub, so a PR from any other owner is a different head that
    ///   happens to share a name.
    /// - `repoOwnerLogin` when the branch tracks nothing: the repo's own slug owner is the only
    ///   owner it could plausibly have, and a candidate from elsewhere is not evidence about it.
    /// - Neither known — a repo whose remote never parsed — is no basis to reject, so the head
    ///   name alone matches, as it always did.
    public static func match(
        branchName: String,
        upstreamOwnerLogin: String?,
        repoOwnerLogin: String? = nil,
        in prs: [PRInfo]
    ) -> PRInfo? {
        let claimedOwner = upstreamOwnerLogin ?? repoOwnerLogin
        let candidates = prs.filter { pr in
            guard pr.headRefName == branchName else { return false }
            guard let claimedOwner else { return true }
            return pr.headRepositoryOwnerLogin == claimedOwner
        }
        guard candidates.count > 1 else { return candidates.first }

        func rank(_ pr: PRInfo) -> (Int, Date) {
            let isOpen = pr.state.uppercased() == "OPEN" ? 1 : 0
            return (isOpen, pr.updatedAt)
        }

        return candidates.max { rank($0) < rank($1) }
    }

    /// Returns the author-@me PRs that neither match an entry in `localHeads` — the (upstream
    /// owner login, branch name) pair of every local branch — nor share a name with anything in
    /// `localBranchNames`.
    ///
    /// The second test is the conservative one the codex review asked for (MAJOR 10). A local
    /// branch with no upstream, or one tracking a remote other than `origin`, contributes no
    /// owner, so it contributes no `LocalHead` either — and the group headed "Open PRs not on this
    /// Mac" then listed a branch that is sitting on this Mac. The group's own note says what it
    /// now means: "with no branch of that name on this Mac".
    public static func openPRsNotOnThisMac(
        authoredOpenPRs: [PRInfo],
        localHeads: Set<LocalHead>,
        localBranchNames: Set<String> = []
    ) -> [PRInfo] {
        authoredOpenPRs.filter { pr in
            guard !localBranchNames.contains(pr.headRefName) else { return false }
            return !localHeads.contains(
                LocalHead(ownerLogin: pr.headRepositoryOwnerLogin, branchName: pr.headRefName)
            )
        }
    }

    /// The key PLAN.md §3 requires for "Open PRs not on this Mac": owner **and** branch.
    public struct LocalHead: Hashable, Codable, Sendable {
        public var ownerLogin: String
        public var branchName: String

        public init(ownerLogin: String, branchName: String) {
            self.ownerLogin = ownerLogin
            self.branchName = branchName
        }
    }
}
