import Foundation

/// Pure mapping from a matched PR to the pill, and from a branch to its PR.
///
/// PLAN.md §5 join rule: match by `headRefName` **first**; `headRepositoryOwnerLogin` only
/// disambiguates when several PRs share a head (prefer same owner, then OPEN, then latest
/// `updatedAt`). It never excludes, or a fork PR would vanish
/// (`forkOriginatedPRStillMatchesItsLocalBranch`).
public enum PRStatusMapper {

    /// OWNER: packet 2.2 — map a PR to its pill state: merged `state` → `.merged`, closed and not
    /// merged → `.closed`, open and `isDraft` → `.draft`, open with `reviewDecision` of
    /// `CHANGES_REQUESTED` → `.changesRequested` and `APPROVED` → `.approved`, and any other open
    /// PR (including `REVIEW_REQUIRED` and the empty string) → `.open`.
    public static func status(for pr: PRInfo) -> PRStatus {
        fatalError("OWNER: packet 2.2 — map a PRInfo to its PRStatus pill, treating an empty reviewDecision as no decision.")
    }

    /// OWNER: packet 2.2 — return the PR whose `headRefName` equals `branchName`, breaking a tie
    /// between several such PRs by preferring `upstreamOwnerLogin` when it is non-nil, then an
    /// OPEN state, then the latest `updatedAt`; return nil when no PR shares the head, and never
    /// filter a PR out because its head owner differs.
    public static func match(branchName: String, upstreamOwnerLogin: String?, in prs: [PRInfo]) -> PRInfo? {
        fatalError("OWNER: packet 2.2 — match a branch to its PR by headRefName first, using head owner only to break ties.")
    }

    /// OWNER: packet 2.2 — return the author-@me PRs whose (head owner login, head branch) pair
    /// matches no entry in `localHeads`, which is the (upstream owner login, branch name) pair of
    /// every local branch; a local `feature-x` tracking `origin` must not hide the user's fork PR
    /// also named `feature-x` (`openElsewhereKeyedByOwnerAndBranchNotBranchAlone`).
    public static func openPRsNotOnThisMac(
        authoredOpenPRs: [PRInfo],
        localHeads: Set<LocalHead>
    ) -> [PRInfo] {
        fatalError("OWNER: packet 2.2 — filter author-@me open PRs down to those whose owner-plus-branch pair matches no local branch.")
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
