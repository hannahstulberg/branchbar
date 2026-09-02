import Foundation

/// Pure derivation of the push facts one branch row shows. PLAN.md §3.
///
/// The rule this type exists to keep honest: a reflog observation and a commit date are
/// different facts with different wording, and the fallback must never be presented as a push
/// (`fallbackLabelDoesNotClaimGitHubObservedTheBranch`).
public enum PushInfoDeriver {

    /// OWNER: packet 2.2 — build a `PushInfo` from an optional reflog observation and the branch's
    /// upstream: with an observation set `source = .reflogObserved`, carry its timestamp and OID,
    /// and set `originMovedSince` when that OID differs from `remoteTipOID`; with no observation
    /// but an upstream set `source = .tipCommitDate` and carry no `observedPushAt`; with no
    /// upstream set `source = .none`. Always carry `hasUpstream`, `upstreamGone`,
    /// `aheadOfLastKnownRemote`, and `remoteRefObservedAt` from the upstream so the presenter
    /// never has to look at the reflog again.
    public static func derive(
        observation: ReflogObservation?,
        upstream: Upstream?,
        remoteTipOID: String?,
        remoteTipCommitDate: Date?
    ) -> PushInfo {
        fatalError("OWNER: packet 2.2 — derive PushInfo from an optional reflog observation plus the upstream, setting source to reflogObserved, tipCommitDate, or none and computing originMovedSince against the remote tip OID.")
    }
}
