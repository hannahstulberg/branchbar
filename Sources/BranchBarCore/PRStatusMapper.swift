import Foundation

/// Pure mapping from a matched PR to the pill, and from a branch to its PR.
///
/// PLAN.md §5 join rule: match by `headRefName` **first**; `headRepositoryOwnerLogin` only
/// disambiguates when several PRs share a head (prefer same owner, then OPEN, then latest
/// `updatedAt`). It never excludes, or a fork PR would vanish
/// (`forkOriginatedPRStillMatchesItsLocalBranch`).
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

    /// Returns the PR whose `headRefName` equals `branchName`, breaking a tie between several
    /// such PRs by preferring `upstreamOwnerLogin` when it is non-nil, then an OPEN state, then
    /// the latest `updatedAt`; returns nil when no PR shares the head, and never filters a PR out
    /// because its head owner differs.
    public static func match(branchName: String, upstreamOwnerLogin: String?, in prs: [PRInfo]) -> PRInfo? {
        let candidates = prs.filter { $0.headRefName == branchName }
        guard candidates.count > 1 else { return candidates.first }

        func rank(_ pr: PRInfo) -> (Int, Int, Date) {
            let sameOwner = (upstreamOwnerLogin != nil && pr.headRepositoryOwnerLogin == upstreamOwnerLogin) ? 1 : 0
            let isOpen = pr.state.uppercased() == "OPEN" ? 1 : 0
            return (sameOwner, isOpen, pr.updatedAt)
        }

        return candidates.max { rank($0) < rank($1) }
    }

    /// Returns the author-@me PRs whose (head owner login, head branch) pair matches no entry in
    /// `localHeads`, which is the (upstream owner login, branch name) pair of every local branch;
    /// a local `feature-x` tracking `origin` must not hide the user's fork PR also named
    /// `feature-x` (`openElsewhereKeyedByOwnerAndBranchNotBranchAlone`).
    public static func openPRsNotOnThisMac(
        authoredOpenPRs: [PRInfo],
        localHeads: Set<LocalHead>
    ) -> [PRInfo] {
        authoredOpenPRs.filter { pr in
            !localHeads.contains(
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
