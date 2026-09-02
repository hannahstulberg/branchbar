import Foundation
import Testing

@testable import BranchBarCore

/// Acceptance tests for `ForEachRefParser`, packet 2.1, written from the frozen contract
/// (PLAN.md §5 formats, §7 named invariants, and the OWNER comments on the stub) by an agent that
/// does not write the implementation.
///
/// The two frozen formats:
///
/// ```
/// refs/heads   %(refname)%1f%(objectname)%1f%(committerdate:unix)%1f%(upstream:short)%1f%(upstream:remotename)%1f%(upstream:track,nobracket)%1f%(HEAD)
/// refs/remotes %(refname)%1f%(objectname)%1f%(committerdate:unix)
/// ```
@Suite("ForEachRefParser — the frozen refs/heads and refs/remotes formats")
struct ForEachRefParserTests {

    /// `%1f` emits U+001F; a parser that split on the literal text `%1f` would return one field.
    private static let unitSeparator: Character = "\u{1F}"

    // MARK: refs/heads

    /// The recorded output of `hannah-personal-agent` on 2026-09-01: `main` in sync and checked
    /// out, `notes-store-a1` with no upstream, `updates-3-29-26` with an upstream and an empty
    /// track field. `refName` stays whole (PLAN.md §7 tag-collision rule) and `branchName` is the
    /// stripped form the join rules use.
    @Test("parsesThreeBranchesWithFullRefnameStripped")
    func parsesThreeBranchesWithFullRefnameStripped() throws {
        let rows = try ForEachRefParser.parseBranches(
            Fixture.text("recorded-hannah-personal-agent-for-each-ref-heads.txt"))

        #expect(rows.count == 3, "the recorded fixture holds three local branches")
        #expect(rows.map(\.refName) == [
            "refs/heads/main",
            "refs/heads/notes-store-a1",
            "refs/heads/updates-3-29-26",
        ], "rows come back in the order git printed them, refname whole")
        #expect(rows.map(\.branchName) == ["main", "notes-store-a1", "updates-3-29-26"])

        let main = try #require(rows.first)
        #expect(main.objectName == "bf8508404ad5abe161d9dba8b61385c7425726af")
        #expect(main.committerDate == Date(timeIntervalSince1970: 1_788_310_842),
                "field 3 is a unix timestamp, not a formatted date")
        #expect(main.upstreamShort == "origin/main")
        #expect(main.upstreamRemoteName == "origin")
        #expect(main.track.isEmpty)
    }

    /// PLAN.md §5: `%(upstream:track,nobracket)` can carry both clauses on one line. `behind` is
    /// parsed here and never presented (§3), which is why it has to be read correctly.
    @Test("parsesAheadAndBehindTogether")
    func parsesAheadAndBehindTogether() throws {
        let rows = try ForEachRefParser.parseBranches(
            Fixture.text("synthetic-for-each-ref-heads-mixed.txt"))

        let diverged = try #require(rows.first { $0.branchName == "diverged" })
        #expect(diverged.track == "ahead 1, behind 4")
        let divergedUpstream = try #require(ForEachRefParser.upstream(from: diverged))
        #expect(divergedUpstream.ahead == 1)
        #expect(divergedUpstream.behind == 4)
        #expect(divergedUpstream.isGone == false)

        let ahead = try #require(rows.first { $0.branchName == "ahead-two" })
        let aheadUpstream = try #require(ForEachRefParser.upstream(from: ahead))
        #expect(aheadUpstream.ahead == 2)
        #expect(aheadUpstream.behind == 0)

        let behind = try #require(rows.first { $0.branchName == "behind-three" })
        let behindUpstream = try #require(ForEachRefParser.upstream(from: behind))
        #expect(behindUpstream.ahead == 0)
        #expect(behindUpstream.behind == 3)
    }

    /// `gone` is a track value, not an absence of upstream: the ref is still named, and the copy
    /// says "Upstream missing from last-known origin" (PLAN.md §3).
    @Test("goneUpstreamSetsIsGone")
    func goneUpstreamSetsIsGone() throws {
        let rows = try ForEachRefParser.parseBranches(
            Fixture.text("synthetic-for-each-ref-heads-mixed.txt"))

        let row = try #require(rows.first { $0.branchName == "upstream-gone" })
        #expect(row.track == "gone")

        let upstream = try #require(ForEachRefParser.upstream(from: row),
                                    "a gone upstream is still an upstream; only upstream:short can say there is none")
        #expect(upstream.isGone)
        #expect(upstream.ref == "origin/upstream-gone")
        #expect(upstream.remote == "origin")
        #expect(upstream.ahead == 0)
        #expect(upstream.behind == 0)
    }

    /// PLAN.md §7. The track field is empty for `main` (in sync) **and** for `no-upstream`; only
    /// `%(upstream:short)` separates them, and getting this backwards renders "never pushed" on a
    /// branch that is up to date.
    @Test("inSyncAndNoUpstreamAreDistinguishedByUpstreamShortNotTrack")
    func inSyncAndNoUpstreamAreDistinguishedByUpstreamShortNotTrack() throws {
        let rows = try ForEachRefParser.parseBranches(
            Fixture.text("synthetic-for-each-ref-heads-mixed.txt"))

        let inSync = try #require(rows.first { $0.branchName == "main" })
        let none = try #require(rows.first { $0.branchName == "no-upstream" })

        #expect(inSync.track.isEmpty)
        #expect(none.track.isEmpty)
        #expect(inSync.track == none.track, "the track field cannot tell these two apart")

        #expect(inSync.upstreamShort == "origin/main")
        #expect(none.upstreamShort.isEmpty)

        let inSyncUpstream = try #require(ForEachRefParser.upstream(from: inSync),
                                          "an empty track with a non-empty upstream:short is in sync, not upstream-less")
        #expect(inSyncUpstream.ref == "origin/main")
        #expect(inSyncUpstream.remote == "origin")
        #expect(inSyncUpstream.ahead == 0)
        #expect(inSyncUpstream.behind == 0)
        #expect(inSyncUpstream.isGone == false)

        #expect(ForEachRefParser.upstream(from: none) == nil,
                "no upstream:short means no upstream")
    }

    /// Branch names carry slashes and spaces. Only the U+001F separator delimits fields, so a
    /// space inside a name is data, and the full ref survives the strip-and-rejoin.
    @Test("branchNameWithSlashesSurvivesRoundTrip")
    func branchNameWithSlashesSurvivesRoundTrip() throws {
        let rows = try ForEachRefParser.parseBranches(
            Fixture.text("synthetic-for-each-ref-heads-mixed.txt"))

        let nested = try #require(rows.first { $0.refName == "refs/heads/feature/nested name" })
        #expect(nested.branchName == "feature/nested name")

        let upstream = try #require(ForEachRefParser.upstream(from: nested))
        #expect(upstream.ref == "origin/feature/nested name")
        #expect(upstream.remote == "origin")
        #expect(upstream.branchName == "feature/nested name",
                "Upstream.branchName strips only the remote name, so slashes below it survive")
    }

    /// `%(HEAD)` is `*` for the branch checked out in the worktree git was run in, and a single
    /// space otherwise. `Branch.isCheckedOutInPrimary` is derived from this by `RepoAssembler`
    /// (packet 3.1); the parser's job is to read the marker without trimming it away.
    @Test("headMarkerSetsIsCheckedOutInPrimary")
    func headMarkerSetsIsCheckedOutInPrimary() throws {
        let recorded = try ForEachRefParser.parseBranches(
            Fixture.text("recorded-hannah-personal-agent-for-each-ref-heads.txt"))
        #expect(recorded.map(\.isHead) == [true, false, false],
                "only `main` carries the `*` marker in the recorded fixture")

        let synthetic = try ForEachRefParser.parseBranches(
            Fixture.text("synthetic-for-each-ref-heads-mixed.txt"))
        #expect(synthetic.filter(\.isHead).map(\.branchName) == ["main"])
        #expect(synthetic.filter { !$0.isHead }.count == 7,
                "the seven non-checked-out rows carry a space, which is not a marker")
    }

    /// PLAN.md §5 freezes seven fields. "Not fatal" is the point of the name: a short row raises a
    /// recoverable Swift error (the OWNER comment: "throwing on a line whose field count is not
    /// seven"), never a trap that takes the whole refresh process down, and blank lines are simply
    /// ignored rather than treated as rows.
    @Test("malformedLineIsSkippedNotFatal")
    func malformedLineIsSkippedNotFatal() throws {
        let raw = Fixture.text("synthetic-for-each-ref-heads-malformed.txt")

        // Blank lines are not rows: with the short row filtered out, the two good rows parse.
        let withoutShortRow = raw
            .components(separatedBy: "\n")
            .filter { $0.isEmpty || $0.split(separator: Self.unitSeparator, omittingEmptySubsequences: false).count == 7 }
            .joined(separator: "\n")
        let rows = try ForEachRefParser.parseBranches(withoutShortRow)
        #expect(rows.map(\.branchName) == ["main", "second"],
                "blank lines between rows are ignored, not parsed into empty branches")

        // The short row is a contract violation, and it surfaces as a thrown error.
        #expect(throws: (any Error).self) {
            _ = try ForEachRefParser.parseBranches(raw)
        }
    }

    /// PLAN.md §7. A repo can hold `refs/tags/main` and `refs/heads/main` at once. The frozen
    /// invocation asks for `refs/heads` only, but the refname is kept whole so a tag can never
    /// masquerade as the branch it shares a name with.
    @Test("tagNameCollisionDoesNotBreakRefnameParsing")
    func tagNameCollisionDoesNotBreakRefnameParsing() throws {
        let rows = try ForEachRefParser.parseBranches(
            Fixture.text("synthetic-for-each-ref-heads-mixed.txt"))

        let tag = try #require(rows.first { $0.refName == "refs/tags/main" })
        #expect(tag.branchName == "refs/tags/main",
                "a non-refs/heads refname is never stripped down to a branch name")
        #expect(ForEachRefParser.upstream(from: tag) == nil)

        let namedMain = rows.filter { $0.branchName == "main" }
        #expect(namedMain.count == 1, "exactly one row may claim the branch name `main`")
        #expect(namedMain.first?.refName == "refs/heads/main")
    }

    // MARK: refs/remotes

    /// `refs/remotes/origin/HEAD` is a symbolic ref git really prints (the recorded fixture proves
    /// it) and is not a remote-tracking branch; the OWNER comment has the parser skip it. A second
    /// remote is present so remote-name handling cannot be hard-coded to `origin`.
    @Test("remoteHeadSymbolicRefIsSkipped")
    func remoteHeadSymbolicRefIsSkipped() throws {
        let synthetic = try ForEachRefParser.parseRemoteRefs(
            Fixture.text("synthetic-for-each-ref-remotes.txt"))

        #expect(!synthetic.contains { $0.refName.hasSuffix("/HEAD") },
                "the symbolic ref is skipped, not returned as a branch called HEAD")
        #expect(synthetic.count == 6, "seven recorded rows minus the origin/HEAD symbolic ref")
        #expect(synthetic.map(\.shortName) == [
            "origin/main",
            "origin/ahead-two",
            "origin/behind-three",
            "origin/diverged",
            "origin/feature/nested name",
            "upstream/main",
        ])

        let tip = try #require(synthetic.first { $0.shortName == "origin/main" })
        #expect(tip.objectName == "7777777777777777777777777777777777777777")
        #expect(tip.committerDate == Date(timeIntervalSince1970: 1_788_310_842))

        let recorded = try ForEachRefParser.parseRemoteRefs(
            Fixture.text("recorded-hannah-personal-agent-for-each-ref-remotes.txt"))
        #expect(recorded.count == 18, "19 recorded rows minus the origin/HEAD symbolic ref")
        #expect(!recorded.contains { $0.refName == "refs/remotes/origin/HEAD" })
    }

    // MARK: Every recorded fixture

    /// PLAN.md §3: recorded fixtures are ground truth from `/usr/bin/git` 2.39.5. Every one of
    /// them must parse, so a re-record on another machine cannot quietly introduce a row shape the
    /// parser rejects.
    @Test("everyRecordedFixtureParsesWithoutError")
    func everyRecordedFixtureParsesWithoutError() throws {
        let heads = Fixture.allNames().filter {
            $0.hasPrefix("recorded-") && $0.hasSuffix("for-each-ref-heads.txt")
        }
        #expect(heads.count >= 2, "the inventory records refs/heads for two repos")

        for name in heads {
            let rows = try ForEachRefParser.parseBranches(Fixture.text(name))
            #expect(!rows.isEmpty, "\(name) parsed to no rows")
            #expect(rows.allSatisfy { $0.refName.hasPrefix("refs/heads/") }, "\(name) yielded a non-head ref")
            #expect(rows.allSatisfy { $0.objectName.count == 40 }, "\(name) yielded a malformed OID")
            #expect(rows.allSatisfy { $0.committerDate.timeIntervalSince1970 > 0 }, "\(name) yielded a zero date")
        }

        let remotes = Fixture.allNames().filter {
            $0.hasPrefix("recorded-") && $0.hasSuffix("for-each-ref-remotes.txt")
        }
        #expect(remotes.count >= 2, "the inventory records refs/remotes for two repos")

        for name in remotes {
            let rows = try ForEachRefParser.parseRemoteRefs(Fixture.text(name))
            #expect(!rows.isEmpty, "\(name) parsed to no rows")
            #expect(rows.allSatisfy { $0.refName.hasPrefix("refs/remotes/") }, "\(name) yielded a non-remote ref")
            #expect(!rows.contains { $0.refName.hasSuffix("/HEAD") }, "\(name) kept the symbolic HEAD ref")
        }
    }
}
