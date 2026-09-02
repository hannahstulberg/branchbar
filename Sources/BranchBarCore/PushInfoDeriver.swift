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
    /// The two remote dates are different facts and travel in different fields (codex MAJOR 7):
    /// `remoteTipCommitDate` is when the remote tip's commit was authored, and
    /// `fetchHeadObservedAt` — the `FETCH_HEAD` modification date — is when this clone last heard
    /// from origin. Only the second lands in `PushInfo.remoteRefObservedAt`, which is what the
    /// "last seen" tooltip reads.
    ///
    /// Three edges the tests pin down, all of them cases where the honest answer is "nothing":
    ///
    /// - **No upstream, nothing observed.** There is no tracked remote branch, so there is
    ///   nothing to date a push against and nothing to be ahead of: `source = .none`,
    ///   `aheadOfLastKnownRemote = nil` rather than `0`
    ///   (`noUpstreamRendersNeverPushedNotZeroCommits`; a `0` would render as "in sync with
    ///   origin"). An observation handed in **with** no upstream is kept, not dropped: `RepoLoader`
    ///   reads `origin/<branch>`'s reflog whenever that ref exists, because a push without `-u`
    ///   leaves a real push record behind an untracked branch (codex MAJOR 6).
    /// - **Gone upstream.** `%(upstream:track,nobracket)` said `gone`, so the ahead count has no
    ///   ref to count against and becomes nil — but the observation survives, because this clone
    ///   really did push, and the row says so beside "Upstream missing from last-known origin".
    /// - **Unknown tip.** With no `remoteTipOID` there is no evidence origin moved, so
    ///   `originMovedSince` stays false. The app never fetches and never guesses.
    public static func derive(
        observation: ReflogObservation?,
        upstream: Upstream?,
        remoteTipOID: String?,
        remoteTipCommitDate: Date?,
        fetchHeadObservedAt: Date? = nil
    ) -> PushInfo {
        guard let upstream else {
            // No tracking configuration, but the reflog of a same-named remote ref may still hold
            // a real push. The count stays nil — there is no upstream to be ahead of — while the
            // observation is reported for what it is.
            guard let observation else {
                return PushInfo(source: .none, hasUpstream: false)
            }
            return PushInfo(
                observedPushAt: observation.pushedAt,
                observedPushOID: observation.newOID,
                originMovedSince: originMoved(observation: observation, remoteTipOID: remoteTipOID),
                source: .reflogObserved,
                hasUpstream: false,
                aheadOfLastKnownRemote: nil,
                remoteRefObservedAt: fetchHeadObservedAt,
                remoteTipCommitDate: remoteTipCommitDate)
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
            remoteRefObservedAt: fetchHeadObservedAt,
            remoteTipCommitDate: remoteTipCommitDate
        )
    }

    /// PLAN.md §5: `originMovedSince = (observedPushOID != current remote-tracking tip OID)`.
    /// Both halves must exist for the comparison to mean anything.
    private static func originMoved(observation: ReflogObservation?, remoteTipOID: String?) -> Bool {
        guard let observation, let remoteTipOID else { return false }
        return observation.newOID != remoteTipOID
    }
}
