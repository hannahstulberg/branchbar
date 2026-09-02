import Foundation

/// When this clone last heard from its remote, as a tri-state (codex round 5, MAJOR 4).
///
/// `FETCH_HEAD`'s modification date used to travel as `Date?`, and the tooltip read the `nil` as
/// proof: "This repo has not fetched yet." F15 made that false — a repo on a network volume has
/// its direct reads **refused**, deliberately, and a stat that throws for any other reason lands
/// in the same `nil`. So an ahead branch on a company file share announced that the repo had never
/// fetched, about a repo that fetches every day.
///
/// Only one of the three is an absence, and it has to be earned: `notFetchedYet` requires the open
/// to have answered `ENOENT`/`ENOTDIR`, which is the file not being there.
public enum FetchHeadState: Hashable, Codable, Sendable {
    /// There is no `FETCH_HEAD`: a clone that has only ever been pushed from.
    case notFetchedYet
    /// The read was skipped, refused, or failed. Nothing is known about the last fetch.
    case unavailable
    /// The `FETCH_HEAD` modification date, which is when a fetch last rewrote it.
    case observed(Date)

    /// The date, for the one caller that has a date-shaped field to fill.
    public var observedAt: Date? {
        if case .observed(let date) = self { return date }
        return nil
    }
}

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
    /// `observedPushOID != current remote-tracking tip OID` → append "(<remote> has moved since)".
    /// Named for origin because origin is the modal remote; the wording it drives names
    /// `remoteName` (codex round 2, MAJOR 5).
    public var originMovedSince: Bool
    public var source: Source
    /// The branch has tracking configuration — this is the `hasConfiguredUpstream` fact codex
    /// round 2 MAJOR 5 asks the row to keep apart from `remoteRefExists`. The stored name is
    /// unchanged because it is a required key of every `CacheFile` already on disk.
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
    /// The remote every count and every "has moved since" on this row was measured against —
    /// `%(upstream:remotename)`, or `origin` when an untracked branch's `origin/<name>` supplied
    /// the tip. Nil when there was nothing to measure against.
    ///
    /// Carried since codex round 2 MAJOR 5: a branch tracking `fork/feature` was compared against
    /// `fork` and then told the user about origin.
    /// Read with `decodeIfPresent` below, so a `CacheFile` written before this field loads with
    /// nil — no remote was recorded, and none is claimed.
    public var remoteName: String? = nil
    /// A remote-tracking ref for this branch was in `for-each-ref -- refs/remotes/`.
    ///
    /// Separate from `hasUpstream` because the two differ exactly where the old copy contradicted
    /// itself: `git push origin feature` without `-u` leaves no tracking configuration and a real
    /// `origin/feature`, and the row read its reflog and then said there was no matching branch on
    /// origin (codex round 2, MAJOR 5).
    /// Read with `decodeIfPresent` below: unlike the two optionals beside it this is a `Bool`,
    /// which a synthesized decoder demands a key for whatever default it carries — the field that
    /// made every 1.1-era cache fail to load (packet F12).
    public var remoteRefExists: Bool = false
    /// `git for-each-ref -- refs/remotes/` answered for this repo (codex round 3, MAJOR 6).
    ///
    /// False means the listing **failed**, so `remoteRefExists == false` is "nobody looked", not
    /// "there is no such branch". Without the distinction a failed listing produced no tip, the
    /// deriver selected `.none`, and the row read "No tracked remote branch" above a tertiary line
    /// claiming the branch was in sync with that same remote. Read with `decodeIfPresent` below,
    /// so a cache written before the field loads as "the listing answered" — which is what every
    /// refresh that wrote one had established.
    public var remoteRefsKnown: Bool = true
    /// What the `FETCH_HEAD` read actually established (codex round 5, MAJOR 4). The authoritative
    /// form of `remoteRefObservedAt`, which stays as the frozen key every `CacheFile` on disk
    /// already carries and still holds the observed date. Read with `decodeIfPresent`: an entry
    /// written before this field is read back through that date — a date is an observation, and
    /// its absence in an old file is what that build believed, so it decodes as `notFetchedYet`
    /// only when the old file recorded no date and no state.
    public var fetchHead: FetchHeadState = .notFetchedYet

    /// The `hasConfiguredUpstream` half of the codex round 2 MAJOR 5 split, under the name the
    /// finding uses. It is `hasUpstream`, which stays the stored name for cache compatibility.
    public var hasConfiguredUpstream: Bool { hasUpstream }

    /// This value with every claim its own fields cannot support taken back out (codex round 5,
    /// MINOR 8).
    ///
    /// `cache.json` is schema-checked and date-checked and was never invariant-checked, so a file
    /// any process running as the user can replace could say `source: reflogObserved` with no
    /// `observedPushAt` — and the presenter filled the hole with the branch's own commit date and
    /// rendered it as "Pushed from this Mac". The cache is documented as untrusted; this is what
    /// treating it that way means. A claim with nothing behind it becomes `unavailable`, which is
    /// the honest reading of a record that says a push was observed and does not say when.
    public func withoutUnsupportedClaims() -> PushInfo {
        var checked = self
        if checked.source == .reflogObserved && checked.observedPushAt == nil {
            checked.source = .unavailable
            checked.observedPushOID = nil
            checked.originMovedSince = false
        }
        // "The remote has moved since" is a comparison against the OID of an observation; with no
        // OID recorded there was no comparison.
        if checked.observedPushOID == nil { checked.originMovedSince = false }
        return checked
    }

    /// Where `observedPushAt` (or the fallback date) came from. PLAN.md §3.
    ///
    /// Six cases since codex round 5 MAJOR 3, which is the number of different things this app can
    /// have done about one branch's push history: it read a push, it read nothing, it could not
    /// read, it never looked, it has only a commit date, or it stopped at something it could not
    /// vouch for. Collapsing the middle three into `none` is what let the row say BranchBar "has
    /// not checked this one" about a branch whose `origin/<name>` reflog it had just read.
    public enum Source: String, Hashable, Codable, Sendable, CaseIterable {
        /// An `update by push` line in the reflog file, or in `git reflog show`.
        case reflogObserved
        /// No usable line: the date shown is a commit date, presented as a separate fact.
        case tipCommitDate
        /// Nothing was looked at, because there is nothing to look at: no tracking configuration
        /// and no `origin/<name>` behind it. The "not checked" wording belongs to this case alone.
        case none
        /// The reflog file held a line this app could not vouch for, so the walk stopped there
        /// rather than reporting the push it found above the corruption (codex round 3, MAJOR 7).
        /// The row says the push history is unreadable; it never falls back to a date.
        case unreadable
        /// `<remote>/<name>`'s reflog **was** read and held no usable line — absent, empty,
        /// fetch-only, deletion-only, or expired (codex round 5, MAJOR 3). A statement about what
        /// this Mac recorded, not about what BranchBar declined to do.
        case checkedNoObservation
        /// The read was skipped or refused: a repo on a network volume BranchBar will not open a
        /// descriptor against, or a reflog file that threw (codex round 5, MAJOR 3). Nothing was
        /// established, and nothing is claimed.
        case unavailable
    }

    /// What happened when this refresh went looking for one branch's push record (codex round 5,
    /// MAJOR 3). `RepoLoader` knows; `PushInfoDeriver` needs it to tell "checked and found
    /// nothing" apart from "never looked", which it cannot infer from a nil observation.
    public enum HistoryRead: String, Hashable, Codable, Sendable, CaseIterable {
        /// No remote-tracking ref to read a reflog for, so nothing was attempted.
        case notAttempted
        /// The reflog was read and held no usable line.
        case nothingObserved
        /// The read was skipped (a network volume) or failed.
        case unavailable
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
        remoteTipCommitDate: Date? = nil,
        remoteName: String? = nil,
        remoteRefExists: Bool = false,
        remoteRefsKnown: Bool = true,
        fetchHead: FetchHeadState? = nil
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
        self.remoteName = remoteName
        self.remoteRefExists = remoteRefExists
        self.remoteRefsKnown = remoteRefsKnown
        // A caller that hands in a date and nothing else means what every caller meant before the
        // tri-state existed: that date is the observation, and its absence is an absent file.
        self.fetchHead = fetchHead ?? remoteRefObservedAt.map(FetchHeadState.observed) ?? .notFetchedYet
    }

    /// Explicit for the reason spelled out on `PRCacheEntry.init(from:)` (packet F12). Of the
    /// three fields added here only `remoteRefExists` actually broke a load — a synthesized
    /// decoder already reads an `Optional` property with `decodeIfPresent` — but all three are
    /// read the same way so the rule is legible rather than a coincidence of their types. Frozen
    /// keys stay required.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        observedPushAt = try container.decodeIfPresent(Date.self, forKey: .observedPushAt)
        observedPushOID = try container.decodeIfPresent(String.self, forKey: .observedPushOID)
        originMovedSince = try container.decode(Bool.self, forKey: .originMovedSince)
        source = try container.decode(Source.self, forKey: .source)
        hasUpstream = try container.decode(Bool.self, forKey: .hasUpstream)
        upstreamGone = try container.decode(Bool.self, forKey: .upstreamGone)
        aheadOfLastKnownRemote =
            try container.decodeIfPresent(Int.self, forKey: .aheadOfLastKnownRemote)
        remoteRefObservedAt = try container.decodeIfPresent(Date.self, forKey: .remoteRefObservedAt)
        remoteTipCommitDate = try container.decodeIfPresent(Date.self, forKey: .remoteTipCommitDate)
        remoteName = try container.decodeIfPresent(String.self, forKey: .remoteName)
        remoteRefExists = try container.decodeIfPresent(Bool.self, forKey: .remoteRefExists) ?? false
        remoteRefsKnown = try container.decodeIfPresent(Bool.self, forKey: .remoteRefsKnown) ?? true
        fetchHead = try container.decodeIfPresent(FetchHeadState.self, forKey: .fetchHead)
            ?? remoteRefObservedAt.map(FetchHeadState.observed)
            ?? .notFetchedYet
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
