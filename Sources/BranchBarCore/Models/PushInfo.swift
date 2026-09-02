import Foundation

/// What this clone observed about pushes of one branch. PLAN.md §3 and §5.
///
/// The label is "Pushed from this Mac 2 days ago", never "You pushed": the reflog file records
/// what this clone observed and nothing about other machines. When there is no usable line the
/// fallback is a different fact with its own wording — "Last push unknown · newest commit dated
/// 2 days ago" — which is why `source` is part of the model and not an implementation detail.
public struct PushInfo: Hashable, Codable, Sendable {
    /// Timestamp of the newest `update by push` line above the deletion boundary.
    public var observedPushAt: Date?
    /// New OID of that line.
    public var observedPushOID: String?
    /// `observedPushOID != current remote-tracking tip OID` → append "(origin has moved since)".
    public var originMovedSince: Bool
    public var source: Source
    public var hasUpstream: Bool
    /// `%(upstream:track,nobracket)` said `gone`; copy says "Upstream missing from last-known
    /// origin", never "deleted on GitHub" — the app never fetches.
    public var upstreamGone: Bool
    /// Ahead count relative to the last-known remote-tracking ref, nil when there is no upstream.
    public var aheadOfLastKnownRemote: Int?
    /// When this clone last heard from origin: the `FETCH_HEAD` modification date, which is a
    /// local observation. It carried the remote tip's **committer date** until codex MAJOR 7,
    /// which meant fetching a two-year-old commit today reported origin as "last seen 2 years
    /// ago". Nil when the clone has no `FETCH_HEAD` — it has never fetched.
    public var remoteRefObservedAt: Date?
    /// Committer date of the remote-tracking tip. A fact about the commit, not about when it was
    /// seen, and the date the "Last push unknown · newest commit dated …" fallback reads: the
    /// local tip can sit far ahead of what origin holds, so `Branch.committerDate` was the wrong
    /// number there (codex MAJOR 7).
    public var remoteTipCommitDate: Date?

    /// Where `observedPushAt` (or the fallback date) came from. PLAN.md §3.
    public enum Source: String, Hashable, Codable, Sendable, CaseIterable {
        /// An `update by push` line in the reflog file, or in `git reflog show`.
        case reflogObserved
        /// No usable line: the date shown is a commit date, presented as a separate fact.
        case tipCommitDate
        /// Nothing to show at all (no upstream, never pushed).
        case none
    }

    public init(
        observedPushAt: Date? = nil,
        observedPushOID: String? = nil,
        originMovedSince: Bool = false,
        source: Source = .none,
        hasUpstream: Bool = false,
        upstreamGone: Bool = false,
        aheadOfLastKnownRemote: Int? = nil,
        remoteRefObservedAt: Date? = nil,
        remoteTipCommitDate: Date? = nil
    ) {
        self.observedPushAt = observedPushAt
        self.observedPushOID = observedPushOID
        self.originMovedSince = originMovedSince
        self.source = source
        self.hasUpstream = hasUpstream
        self.upstreamGone = upstreamGone
        self.aheadOfLastKnownRemote = aheadOfLastKnownRemote
        self.remoteRefObservedAt = remoteRefObservedAt
        self.remoteTipCommitDate = remoteTipCommitDate
    }
}

/// One usable push line, whatever produced it. Returned by `ReflogFileReader` (the file) and
/// `ReflogParser` (the `git reflog show` fallback) so `PushInfoDeriver` has one input shape.
public struct ReflogObservation: Hashable, Codable, Sendable {
    public var pushedAt: Date
    /// New OID of the `update by push` line, compared against the remote-tracking tip.
    public var newOID: String

    public init(pushedAt: Date, newOID: String) {
        self.pushedAt = pushedAt
        self.newOID = newOID
    }
}
