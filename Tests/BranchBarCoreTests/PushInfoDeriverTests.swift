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
        // Was `remoteRefObservedAt == tipCommitDate` until codex MAJOR 7. A commit date is not an
        // observation date — fetching a two-year-old commit today reported origin as "last seen 2
        // years ago" — so the two facts now travel in two fields, and only `FETCH_HEAD`'s
        // modification date fills the one the "last seen" tooltip reads.
        #expect(push.remoteTipCommitDate == tipCommitDate,
                "the tip's committer date is what the fallback label dates")
        #expect(push.remoteRefObservedAt == nil, "no FETCH_HEAD was handed in, so nothing was seen")

        let fetched = Date(timeIntervalSince1970: 1_788_400_000)
        let withFetchHead = PushInfoDeriver.derive(
            observation: observation,
            upstream: Self.upstream("ahead-two"),
            remoteTipOID: Self.tip("origin/ahead-two")?.objectName,
            remoteTipCommitDate: tipCommitDate,
            fetchHeadObservedAt: fetched
        )
        #expect(withFetchHead.remoteRefObservedAt == fetched)
        #expect(withFetchHead.remoteTipCommitDate == tipCommitDate)
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

    /// codex MAJOR 6, the deriver half. This used to assert `.none`, on the rule that the whole
    /// push line is keyed on the upstream — which made every branch pushed with a bare
    /// `git push origin <branch>` read "Never pushed". `RepoLoader` now reads `origin/<branch>`'s
    /// reflog whenever that ref exists, and an observation it finds is reported as the observation
    /// it is. The count still has nothing to count against, so it stays nil.
    @Test("observationWithoutAnUpstreamIsStillTheObservationItIs")
    func observationWithoutAnUpstreamIsStillTheObservationItIs() throws {
        let observation = try #require(
            ReflogFileReader.parse(Fixture.text("synthetic-reflog-push-and-fetch.txt")))

        let push = PushInfoDeriver.derive(
            observation: observation,
            upstream: nil,
            remoteTipOID: nil,
            remoteTipCommitDate: nil
        )

        #expect(push.source == .reflogObserved)
        #expect(push.observedPushAt == observation.pushedAt)
        #expect(push.observedPushOID == observation.newOID)
        #expect(push.hasUpstream == false, "there is still no tracking configuration")
        #expect(push.aheadOfLastKnownRemote == nil, "and so still nothing to be ahead of")
        #expect(push.originMovedSince == false, "no tip was handed in, so nothing can have moved")

        // With the candidate ref's tip the comparison means something again.
        let moved = PushInfoDeriver.derive(
            observation: observation,
            upstream: nil,
            remoteTipOID: String(repeating: "f", count: 40),
            remoteTipCommitDate: Date(timeIntervalSince1970: 1_788_310_842)
        )
        #expect(moved.originMovedSince)
        #expect(moved.remoteTipCommitDate == Date(timeIntervalSince1970: 1_788_310_842))
    }

    /// codex MAJOR 7, the label half: the fallback dates the **remote** tip's commit, not the
    /// local one. A branch whose local tip is months ahead of what origin holds used to report
    /// "newest commit dated" against a commit origin has never seen.
    @Test("fallbackLabelUsesRemoteTipCommitDateNotLocalTip")
    func fallbackLabelUsesRemoteTipCommitDateNotLocalTip() throws {
        let remoteTipCommitDate = Date(timeIntervalSince1970: 1_787_000_000)
        let localTipDate = Date(timeIntervalSince1970: 1_788_400_000)
        #expect(remoteTipCommitDate != localTipDate)

        let push = PushInfoDeriver.derive(
            observation: nil,
            upstream: Self.upstream("main"),
            remoteTipOID: Self.tip("origin/main")?.objectName,
            remoteTipCommitDate: remoteTipCommitDate
        )
        #expect(push.source == .tipCommitDate)
        #expect(push.remoteTipCommitDate == remoteTipCommitDate)

        let branch = Branch(
            name: "main",
            tipSHA: String(repeating: "1", count: 40),
            committerDate: localTipDate,
            upstream: Self.upstream("main"),
            prStatus: .none,
            push: push)
        let vm = SnapshotPresenter().present(
            UIFixtures.snapshot([UIFixtures.repo(branches: [branch])]),
            refreshState: .idle(lastRefreshedAt: UIClock.ago(12)),
            collapsedRepoIDs: [],
            scanResult: nil,
            appVersion: uiAppVersion,
            now: UIClock.now
        )
        let row = try #require(vm.sections.first?.active.first)

        #expect(row.pushLabel
            == Strings.pushUnknown(tipCommitDate: remoteTipCommitDate, now: UIClock.now))
        #expect(row.pushLabel
            != Strings.pushUnknown(tipCommitDate: localTipDate, now: UIClock.now))
    }

    /// codex MAJOR 7, the tooltip half: "last seen" is `FETCH_HEAD`'s modification date, which is
    /// something this Mac did, and it says so plainly when there is no `FETCH_HEAD` to read.
    @Test("lastSeenTooltipUsesFetchHeadMtime")
    func lastSeenTooltipUsesFetchHeadMtime() throws {
        let fetchedAt = UIClock.ago(3 * UIClock.hour)
        let ancientCommit = UIClock.ago(800 * UIClock.day)

        let ahead = try #require(Self.upstream("ahead-two"))
        let push = PushInfoDeriver.derive(
            observation: nil,
            upstream: ahead,
            remoteTipOID: Self.tip("origin/ahead-two")?.objectName,
            remoteTipCommitDate: ancientCommit,
            fetchHeadObservedAt: fetchedAt
        )
        #expect(push.remoteRefObservedAt == fetchedAt)

        func tooltip(_ push: PushInfo) throws -> String {
            let branch = Branch(
                name: "ahead-two",
                tipSHA: String(repeating: "1", count: 40),
                committerDate: UIClock.ago(UIClock.day),
                upstream: ahead,
                prStatus: .none,
                push: push)
            let vm = SnapshotPresenter().present(
                UIFixtures.snapshot([UIFixtures.repo(branches: [branch])]),
                refreshState: .idle(lastRefreshedAt: UIClock.ago(12)),
                collapsedRepoIDs: [],
                scanResult: nil,
                appVersion: uiAppVersion,
                now: UIClock.now
            )
            return try #require(vm.sections.first?.active.first?.pushTooltip)
        }

        let seen = try tooltip(push)
        // Was "last seen 3 hours ago" until codex round 2 MAJOR 5: `FETCH_HEAD` is rewritten by a
        // fetch of any remote and left alone by `--no-write-fetch-head`, so its date proves when
        // this repo last fetched and nothing about origin.
        #expect(seen.contains("This repo's last fetch changed FETCH_HEAD 3 hours ago"), "\(seen)")
        #expect(!seen.contains("last seen"), "\(seen)")
        #expect(!seen.contains("2 years ago"), "the remote tip's commit date is not an observation")

        // No FETCH_HEAD: the clone has never fetched, and the tooltip says that rather than
        // dropping the clause and letting the sentence read as if the date were merely omitted.
        var neverFetched = push
        neverFetched.remoteRefObservedAt = nil
        let unfetched = try tooltip(neverFetched)
        #expect(unfetched.contains(Strings.notFetchedYet), "\(unfetched)")
        #expect(!unfetched.contains("last seen"))
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
