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
    /// `remoteName` names the remote every fact here was measured against; it defaults to the
    /// upstream's own remote, and a caller that resolved the tip from `origin/<branch>` behind an
    /// untracked branch passes `"origin"`. `remoteRefExists` follows from the tip: a
    /// remote-tracking ref that `for-each-ref` listed is a ref that exists (codex round 2,
    /// MAJOR 5).
    /// `pushHistoryUnreadable` is the reflog's third answer (codex round 3, MAJOR 7): a nonempty
    /// line the reader could not vouch for stopped the walk, so there is no push date to report
    /// and the tip-commit fallback would be reporting a date over corruption. It outranks every
    /// other source, because the thing below the corruption could be the deletion that makes the
    /// rest of the file a lie.
    ///
    /// `remoteRefsState` is what `for-each-ref -- refs/remotes/` did (codex round 3, MAJOR 6).
    /// `.failed` travels to the row as `remoteRefsKnown: false`, which is what keeps "No tracked
    /// remote branch" and "In sync with last-known origin" off a row whose remote nobody read.
    public static func derive(
        observation: ReflogObservation?,
        upstream: Upstream?,
        remoteTipOID: String?,
        remoteTipCommitDate: Date?,
        fetchHeadObservedAt: Date? = nil,
        remoteName: String? = nil,
        pushHistoryUnreadable: Bool = false,
        remoteRefsState: RemoteFactState = .known
    ) -> PushInfo {
        let remote = remoteName ?? upstream?.remote
        let remoteRefExists = remoteTipOID != nil || remoteTipCommitDate != nil
        let remoteRefsKnown = remoteRefsState != .failed

        // The uncertainty boundary short-circuits both arms below: no date, no OID, no
        // "has moved since" comparison against an OID this reader refused to trust.
        if pushHistoryUnreadable {
            return PushInfo(
                source: .unreadable,
                hasUpstream: upstream != nil,
                upstreamGone: upstream?.isGone ?? false,
                aheadOfLastKnownRemote: (upstream?.isGone ?? true) ? nil : upstream?.ahead,
                remoteRefObservedAt: fetchHeadObservedAt,
                remoteTipCommitDate: remoteTipCommitDate,
                remoteName: remote,
                remoteRefExists: remoteRefExists,
                remoteRefsKnown: remoteRefsKnown)
        }

        guard let upstream else {
            // No tracking configuration, but the reflog of a same-named remote ref may still hold
            // a real push. The count stays nil — there is no upstream to be ahead of — while the
            // observation is reported for what it is.
            guard let observation else {
                return PushInfo(
                    source: .none,
                    hasUpstream: false,
                    remoteName: remote,
                    remoteRefExists: remoteRefExists,
                    remoteRefsKnown: remoteRefsKnown)
            }
            return PushInfo(
                observedPushAt: observation.pushedAt,
                observedPushOID: observation.newOID,
                originMovedSince: originMoved(observation: observation, remoteTipOID: remoteTipOID),
                source: .reflogObserved,
                hasUpstream: false,
                aheadOfLastKnownRemote: nil,
                remoteRefObservedAt: fetchHeadObservedAt,
                remoteTipCommitDate: remoteTipCommitDate,
                remoteName: remote,
                remoteRefExists: remoteRefExists,
                remoteRefsKnown: remoteRefsKnown)
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
            remoteTipCommitDate: remoteTipCommitDate,
            remoteName: remote,
            remoteRefExists: remoteRefExists,
            remoteRefsKnown: remoteRefsKnown
        )
    }

    /// PLAN.md §5: `originMovedSince = (observedPushOID != current remote-tracking tip OID)`.
    /// Both halves must exist for the comparison to mean anything.
    private static func originMoved(observation: ReflogObservation?, remoteTipOID: String?) -> Bool {
        guard let observation, let remoteTipOID else { return false }
        return observation.newOID != remoteTipOID
    }
}
