import Foundation

/// Pure derivation of the push facts one branch row shows. PLAN.md §3.
///
/// The rule this type exists to keep honest: a reflog observation and a commit date are
/// different facts with different wording, and the fallback must never be presented as a push
/// (`fallbackLabelDoesNotClaimGitHubObservedTheBranch`).
public enum PushInfoDeriver {

    /// Build a `PushInfo` from an optional reflog observation and the branch's upstream: with an
    /// observation set `source = .reflogObserved`, carry its timestamp and OID, and set
    /// `originMovedSince` when that OID differs from `remoteTipOID`; with no observation but an
    /// upstream set `source = .tipCommitDate` and carry no `observedPushAt`; with no upstream set
    /// `source = .none`. Always carry `hasUpstream`, `upstreamGone`, `aheadOfLastKnownRemote`, and
    /// `remoteRefObservedAt` from the upstream so the presenter never has to look at the reflog
    /// again.
    ///
    /// `remoteTipCommitDate` is the committer date of the remote-tracking tip, which is exactly
    /// what `PushInfo.remoteRefObservedAt` is defined to hold — the "last-known origin" anchor the
    /// tooltip reads. No second field is added for it.
    ///
    /// Three edges the tests pin down, all of them cases where the honest answer is "nothing":
    ///
    /// - **No upstream.** There is no remote branch, so there is nothing to date a push against
    ///   and nothing to be ahead of: `source = .none`, `aheadOfLastKnownRemote = nil` rather than
    ///   `0` (`noUpstreamRendersNeverPushedNotZeroCommits`; a `0` would render as "in sync with
    ///   origin"). An observation handed in without an upstream is dropped for the same reason.
    /// - **Gone upstream.** `%(upstream:track,nobracket)` said `gone`, so the ahead count has no
    ///   ref to count against and becomes nil — but the observation survives, because this clone
    ///   really did push, and the row says so beside "Upstream missing from last-known origin".
    /// - **Unknown tip.** With no `remoteTipOID` there is no evidence origin moved, so
    ///   `originMovedSince` stays false. The app never fetches and never guesses.
    public static func derive(
        observation: ReflogObservation?,
        upstream: Upstream?,
        remoteTipOID: String?,
        remoteTipCommitDate: Date?
    ) -> PushInfo {
        guard let upstream else {
            // Everything about a push is keyed on the upstream. Without one the row's push line
            // is "Never pushed from this Mac", which carries no date and no count.
            return PushInfo(source: .none, hasUpstream: false)
        }

        let source: PushInfo.Source
        if observation != nil {
            source = .reflogObserved
        } else if remoteTipCommitDate != nil {
            source = .tipCommitDate
        } else {
            // An upstream whose ref is gone or was never fetched: no observation and no tip date
            // is nothing to show, and a `.tipCommitDate` with no date would be a label with a
            // hole in it.
            source = .none
        }

        return PushInfo(
            observedPushAt: observation?.pushedAt,
            observedPushOID: observation?.newOID,
            originMovedSince: originMoved(observation: observation, remoteTipOID: remoteTipOID),
            source: source,
            hasUpstream: true,
            upstreamGone: upstream.isGone,
            aheadOfLastKnownRemote: upstream.isGone ? nil : upstream.ahead,
            remoteRefObservedAt: remoteTipCommitDate
        )
    }

    /// PLAN.md §5: `originMovedSince = (observedPushOID != current remote-tracking tip OID)`.
    /// Both halves must exist for the comparison to mean anything.
    private static func originMoved(observation: ReflogObservation?, remoteTipOID: String?) -> Bool {
        guard let observation, let remoteTipOID else { return false }
        return observation.newOID != remoteTipOID
    }
}
