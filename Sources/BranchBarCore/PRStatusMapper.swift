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

    /// The three values `gh pr list --json state` can print, as a closed set (codex round 4,
    /// MINOR 1).
    ///
    /// Case-insensitive because the mapper always was; a value outside the set is `nil`, which is
    /// the whole point of naming the set.
    public enum State: String, Hashable, Sendable, CaseIterable {
        case open = "OPEN"
        case merged = "MERGED"
        case closed = "CLOSED"

        public init?(apiValue: String) {
            self.init(rawValue: apiValue.uppercased())
        }
    }

    /// Maps a PR to its pill state: `MERGED` → `.merged`, `CLOSED` → `.closed`, `OPEN` and
    /// `isDraft` → `.draft`, `OPEN` with `reviewDecision` of `CHANGES_REQUESTED` →
    /// `.changesRequested` and `APPROVED` → `.approved`, and any other open PR (including
    /// `REVIEW_REQUIRED` and the empty string) → `.open`.
    ///
    /// Anything that is not one of the three states is `.unavailable` (codex round 4, MINOR 1).
    /// The default arm used to be the *open* arm, so a state GitHub adds later — and any
    /// malformed cached or CLI JSON — rendered an "Open" pill and an open-PR link for a PR this
    /// app can say nothing about. `.draft` and the two review pills are statements about an open
    /// PR too, so an unknown state does not reach them either.
    public static func status(for pr: PRInfo) -> PRStatus {
        guard let state = State(apiValue: pr.state) else { return .unavailable }
        switch state {
        case .merged:
            // `mergedBeatsDraftFlag`: the branch shipped, whatever the draft flag still says.
            return .merged
        case .closed:
            return .closed
        case .open:
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
    ///
    /// Two changes came from codex round 2 (MAJOR 4). Logins are compared case-insensitively:
    /// GitHub treats `Contributor` and `contributor` as one account, `gh` prints the casing the
    /// account was created with, and the clone URL carries the casing that was typed, so a byte
    /// comparison rejected the user's own PR. And `upstreamOwnerUnresolved` is the third answer
    /// the old two-valued owner could not express: a branch tracking a remote whose URL this app
    /// could not resolve has an owner that exists and is unknown, which is a reason to claim
    /// nothing — not a licence to fall back to the origin repository's owner and not a licence to
    /// match on the head name alone.
    public static func match(
        branchName: String,
        upstreamOwnerLogin: String?,
        repoOwnerLogin: String? = nil,
        upstreamOwnerUnresolved: Bool = false,
        in prs: [PRInfo]
    ) -> PRInfo? {
        guard !upstreamOwnerUnresolved else { return nil }
        let claimedOwner = (upstreamOwnerLogin ?? repoOwnerLogin)?.lowercased()
        let candidates = prs.filter { pr in
            guard pr.headRefName == branchName else { return false }
            guard let claimedOwner else { return true }
            return pr.headRepositoryOwnerLogin.lowercased() == claimedOwner
        }
        guard candidates.count > 1 else { return candidates.first }

        func rank(_ pr: PRInfo) -> (Int, Date) {
            let isOpen = State(apiValue: pr.state) == .open ? 1 : 0
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
    ///
    /// `ownerLogin` is held lower-cased (codex round 2, MAJOR 4). This value is a lookup key and
    /// nothing renders it, so folding it here is what makes the set membership test agree with
    /// GitHub's own case-insensitive account names.
    public struct LocalHead: Hashable, Codable, Sendable {
        public var ownerLogin: String
        public var branchName: String

        public init(ownerLogin: String, branchName: String) {
            self.ownerLogin = ownerLogin.lowercased()
            self.branchName = branchName
        }
    }
}
