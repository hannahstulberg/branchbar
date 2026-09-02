import Foundation
import Testing

@testable import BranchBarCore

/// Acceptance tests for `PushInfoDeriver`, packet 3.1, written from PLAN.md §3 ("Last push
/// observed"), §5, the §7 named invariants, and the OWNER comment on the stub.
///
/// The rule the whole type exists to keep honest: a reflog observation and a commit date are
/// **different facts**. The deriver is what decides which one the row carries, so every case here
/// is a value comparison with no process and no filesystem.
///
/// The upstream rows come from `synthetic-for-each-ref-heads-mixed.txt` through the real
/// `ForEachRefParser`, and the remote-tracking tips from `synthetic-for-each-ref-remotes.txt`, so
/// a change to either parser shows up here rather than in a hand-typed `Upstream`.
@Suite("PushInfoDeriver — reflog observation versus tip commit date")
struct PushInfoDeriverTests {

    // MARK: Fixtures, parsed by the real parsers

    private static let heads: [ParsedBranchRef] = {
        (try? ForEachRefParser.parseBranches(Fixture.text("synthetic-for-each-ref-heads-mixed.txt"))) ?? []
    }()

    private static let remoteTips: [ParsedRemoteRef] = {
        (try? ForEachRefParser.parseRemoteRefs(Fixture.text("synthetic-for-each-ref-remotes.txt"))) ?? []
    }()

    /// The `Upstream` of one row of the mixed heads fixture, or nil when the row has none.
    private static func upstream(_ branchName: String) -> Upstream? {
        guard let row = heads.first(where: { $0.branchName == branchName && $0.refName.hasPrefix("refs/heads/") }) else {
            Issue.record("no row named \(branchName) in synthetic-for-each-ref-heads-mixed.txt")
            return nil
        }
        return ForEachRefParser.upstream(from: row)
    }

    /// The remote-tracking tip for `origin/<branch>`, as the assembler looks it up.
    private static func tip(_ shortName: String) -> ParsedRemoteRef? {
        remoteTips.first { $0.shortName == shortName }
    }

    // MARK: - PLAN.md §7 `reflogPushBeatsTipCommitDate`

    /// PLAN.md §3: the reflog file is what **this clone observed**, and when it has a usable
    /// `update by push` line that observation is the fact the row carries — never the remote
    /// tip's commit date, which is a different fact with its own wording.
    @Test("reflogPushBeatsTipCommitDate")
    func reflogPushBeatsTipCommitDate() throws {
        let observation = try #require(
            ReflogFileReader.parse(Fixture.text("synthetic-reflog-push-and-fetch.txt")),
            "the fixture's newest usable line is the 1788200000 push onto c…")
        let tipCommitDate = Date(timeIntervalSince1970: 1_788_310_842)

        let push = PushInfoDeriver.derive(
            observation: observation,
            upstream: Self.upstream("main"),
            remoteTipOID: String(repeating: "c", count: 40),
            remoteTipCommitDate: tipCommitDate
        )

        #expect(push.source == .reflogObserved)
        #expect(push.observedPushAt == Date(timeIntervalSince1970: 1_788_200_000),
                "the push line's timestamp, not the tip's commit date")
        #expect(push.observedPushAt != tipCommitDate)
        #expect(push.observedPushOID == String(repeating: "c", count: 40))
        #expect(push.hasUpstream)
    }

    /// The fallback half of the same rule: no usable line leaves `observedPushAt` nil and marks
    /// the source `.tipCommitDate`, so the presenter cannot render a commit date as a push
    /// (`fallbackLabelDoesNotClaimGitHubObservedTheBranch`).
    @Test("fetchOnlyReflogFallsBackToTipCommitDateWithNoObservedPushAt")
    func fetchOnlyReflogFallsBackToTipCommitDate() throws {
        let observation = ReflogFileReader.parse(Fixture.text("synthetic-reflog-fetch-only.txt"))
        #expect(observation == nil, "fetch and pull lines are not pushes")

        let tipCommitDate = Date(timeIntervalSince1970: 1_788_290_000)
        let push = PushInfoDeriver.derive(
            observation: observation,
            upstream: Self.upstream("ahead-two"),
            remoteTipOID: Self.tip("origin/ahead-two")?.objectName,
            remoteTipCommitDate: tipCommitDate
        )

        #expect(push.source == .tipCommitDate)
        #expect(push.observedPushAt == nil, "there is no observed push to date")
        #expect(push.observedPushOID == nil)
        #expect(push.originMovedSince == false, "nothing was observed, so nothing can have moved since")
        #expect(push.remoteRefObservedAt == tipCommitDate,
                "the tip's committer date is the last-known-origin anchor the tooltip needs")
    }

    // MARK: - PLAN.md §7 `noUpstreamRendersNeverPushedNotZeroCommits`

    /// The deriver half of the invariant (the copy half lives in `SnapshotPresenterTests`): with
    /// no upstream there is nothing to be ahead **of**, so `aheadOfLastKnownRemote` is nil rather
    /// than 0 — a 0 would render as "in sync with origin" for a branch that has no origin.
    @Test("noUpstreamRendersNeverPushedNotZeroCommits")
    func noUpstreamRendersNeverPushedNotZeroCommits() throws {
        #expect(Self.upstream("no-upstream") == nil, "the fixture row has an empty upstream:short")

        let push = PushInfoDeriver.derive(
            observation: nil,
            upstream: nil,
            remoteTipOID: nil,
            remoteTipCommitDate: nil
        )

        #expect(push.aheadOfLastKnownRemote == nil, "nil, never 0")
        #expect(push.hasUpstream == false)
        #expect(push.upstreamGone == false)
        #expect(push.source == .none)
        #expect(push.observedPushAt == nil)
    }

    /// An observation without an upstream is not a push story the row can tell: PLAN.md §3 keys
    /// the whole push line on the upstream, so the deriver reports `.none` rather than dating a
    /// push against a remote branch that is not being tracked.
    @Test("observationWithoutAnUpstreamIsStillSourceNone")
    func observationWithoutAnUpstreamIsStillSourceNone() throws {
        let observation = ReflogFileReader.parse(Fixture.text("synthetic-reflog-push-and-fetch.txt"))

        let push = PushInfoDeriver.derive(
            observation: observation,
            upstream: nil,
            remoteTipOID: nil,
            remoteTipCommitDate: nil
        )

        #expect(push.source == .none)
        #expect(push.observedPushAt == nil)
        #expect(push.hasUpstream == false)
        #expect(push.aheadOfLastKnownRemote == nil)
    }

    // MARK: - PLAN.md §7 `observedPushWhoseOIDIsNotTheRemoteTipSetsOriginMovedSince`

    /// PLAN.md §5: `originMovedSince = (observedPushOID != current remote-tracking tip OID)`.
    /// The fixture's newest push lands on b…; paired with a tip that is not b… the row appends
    /// "(origin has moved since)".
    @Test("observedPushWhoseOIDIsNotTheRemoteTipSetsOriginMovedSince")
    func observedPushWhoseOIDIsNotTheRemoteTipSetsOriginMovedSince() throws {
        let observation = try #require(
            ReflogFileReader.parse(Fixture.text("synthetic-reflog-push-oid-differs-from-tip.txt")))
        #expect(observation.newOID == String(repeating: "b", count: 40))

        let movedTip = try #require(Self.tip("origin/ahead-two"), "OID 1010…, which is not b…")
        let moved = PushInfoDeriver.derive(
            observation: observation,
            upstream: Self.upstream("ahead-two"),
            remoteTipOID: movedTip.objectName,
            remoteTipCommitDate: movedTip.committerDate
        )
        #expect(moved.originMovedSince, "the observed push is not where origin now points")
        #expect(moved.source == .reflogObserved, "origin moving does not erase the observation")

        let sameTip = PushInfoDeriver.derive(
            observation: observation,
            upstream: Self.upstream("ahead-two"),
            remoteTipOID: observation.newOID,
            remoteTipCommitDate: movedTip.committerDate
        )
        #expect(sameTip.originMovedSince == false, "same OID, so origin has not moved")
    }

    /// An unknown tip is not a moved tip. With no remote-tracking OID to compare against — the
    /// upstream is gone, or the ref was never fetched — the app must not claim origin moved; it
    /// has no evidence either way, and PLAN.md §3 forbids inventing remote facts.
    @Test("absentRemoteTipDoesNotClaimOriginMoved")
    func absentRemoteTipDoesNotClaimOriginMoved() throws {
        let observation = try #require(
            ReflogFileReader.parse(Fixture.text("synthetic-reflog-push-oid-differs-from-tip.txt")))

        let push = PushInfoDeriver.derive(
            observation: observation,
            upstream: Self.upstream("upstream-gone"),
            remoteTipOID: nil,
            remoteTipCommitDate: nil
        )

        #expect(push.originMovedSince == false)
    }

    // MARK: - PLAN.md §7 `goneUpstreamKeepsObservationButNilAhead`

    /// `%(upstream:track,nobracket)` said `gone`: the ahead count is meaningless (there is no
    /// last-known remote ref to count against) but the observation still happened, and PLAN.md §3
    /// keeps it so the row can say "Pushed from this Mac 2 days ago · Upstream missing from
    /// last-known origin".
    @Test("goneUpstreamKeepsObservationButNilAhead")
    func goneUpstreamKeepsObservationButNilAhead() throws {
        let upstream = try #require(Self.upstream("upstream-gone"))
        #expect(upstream.isGone, "the fixture row's track field is `gone`")

        let observation = try #require(
            ReflogFileReader.parse(Fixture.text("synthetic-reflog-push-and-fetch.txt")))

        let push = PushInfoDeriver.derive(
            observation: observation,
            upstream: upstream,
            remoteTipOID: nil,
            remoteTipCommitDate: nil
        )

        #expect(push.hasUpstream, "the branch still has an upstream configured; it is the ref that is gone")
        #expect(push.upstreamGone)
        #expect(push.aheadOfLastKnownRemote == nil, "nothing to be ahead of")
        #expect(push.source == .reflogObserved)
        #expect(push.observedPushAt == observation.pushedAt, "the observation survives the gone upstream")
        #expect(push.observedPushOID == observation.newOID)
    }

    // MARK: - PLAN.md §7 `aheadCountBecomesAheadOfLastKnownRemote`

    /// The only count the UI shows, and it is relative to the **last-known** remote ref, not to
    /// GitHub: `%(upstream:track,nobracket)`'s ahead clause lands in `aheadOfLastKnownRemote`
    /// unchanged. `behind` is parsed and never carried into `PushInfo` at all (PLAN.md §3).
    @Test("aheadCountBecomesAheadOfLastKnownRemote")
    func aheadCountBecomesAheadOfLastKnownRemote() throws {
        let aheadTwo = try #require(Self.upstream("ahead-two"))
        #expect(aheadTwo.ahead == 2)

        let tip = try #require(Self.tip("origin/ahead-two"))
        let push = PushInfoDeriver.derive(
            observation: nil,
            upstream: aheadTwo,
            remoteTipOID: tip.objectName,
            remoteTipCommitDate: tip.committerDate
        )
        #expect(push.aheadOfLastKnownRemote == 2)

        // In sync is 0, and that is a real answer — distinct from nil, which means "no upstream".
        let inSync = try #require(Self.upstream("main"))
        let mainTip = try #require(Self.tip("origin/main"))
        let synced = PushInfoDeriver.derive(
            observation: nil,
            upstream: inSync,
            remoteTipOID: mainTip.objectName,
            remoteTipCommitDate: mainTip.committerDate
        )
        #expect(synced.aheadOfLastKnownRemote == 0, "in sync is 0, not nil")

        // A diverged branch carries only the ahead half; `behind` never reaches the UI.
        let diverged = try #require(Self.upstream("diverged"))
        #expect(diverged.behind == 4, "parsed…")
        let divergedPush = PushInfoDeriver.derive(
            observation: nil,
            upstream: diverged,
            remoteTipOID: Self.tip("origin/diverged")?.objectName,
            remoteTipCommitDate: Self.tip("origin/diverged")?.committerDate
        )
        #expect(divergedPush.aheadOfLastKnownRemote == 1, "…and only the ahead count is carried")
    }
}
