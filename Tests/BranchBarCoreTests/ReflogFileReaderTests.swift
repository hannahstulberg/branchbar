import Foundation
import Testing

@testable import BranchBarCore

/// Acceptance tests for `ReflogFileReader`, packet 2.1, written from the frozen contract
/// (PLAN.md §5 "Last push observed", §7 named invariants, and the OWNER comments on the stub) by
/// an agent that does not write the implementation.
///
/// Line format, oldest line first, as git appends them:
///
/// ```
/// <old OID> <new OID> <author> <email> <unixtime> <tz>\t<message>
/// ```
///
/// The rule: walk **newest-first**, stop at the first line whose **new** OID is all zeros (the
/// deletion boundary), and report the first `update by push` line above it. Nothing else is a
/// push, and no other date is ever presented as one.
@Suite("ReflogFileReader — the file this clone wrote")
struct ReflogFileReaderTests {

    private static let zeroOID = String(repeating: "0", count: 40)

    /// A reader over an in-memory tree holding one reflog file for `origin/<branch>`.
    private static func reader(
        commonDirectory: String = "/Users/tester/monorepo/.git",
        remote: String = "origin",
        branch: String = "main",
        contents: String
    ) -> (ReflogFileReader, InMemoryFileSystem) {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addFile(
            ReflogFileReader.reflogPath(commonDirectory: commonDirectory, remote: remote, branch: branch),
            contents: contents)
        return (ReflogFileReader(fileSystem: fs), fs)
    }

    // MARK: The usable push line

    /// PLAN.md §7 and §5: the timestamp is **field 5** — after the two OIDs, the author name, and
    /// the email — and the OID is field 2, the new one. Reading field 6 gives the timezone and
    /// reading field 1 gives the OID the ref pointed at *before* the push.
    @Test("reflogFileLastUsablePushLineParsesUnixTimestampFromField5")
    func reflogFileLastUsablePushLineParsesUnixTimestampFromField5() throws {
        let contents = Fixture.text("recorded-reflog-hannah-personal-agent-origin-main.txt")
        let observation = try #require(ReflogFileReader.parse(contents),
                                       "a file full of `update by push` lines must yield an observation")

        #expect(observation.pushedAt == Date(timeIntervalSince1970: 1_788_310_851),
                "the newest line's field 5, not its timezone and not an older line")
        #expect(observation.newOID == "bf8508404ad5abe161d9dba8b61385c7425726af",
                "field 2 is the OID the push landed on; field 1 is where the ref was before it")

        // The same file, read through the seam at the path the reader owns.
        let (reader, _) = Self.reader(contents: contents)
        let viaFile = try #require(try reader.observation(
            commonDirectory: "/Users/tester/monorepo/.git", remote: "origin", branch: "main"))
        #expect(viaFile == observation)
    }

    /// The recorded `branchbar` file opens with an all-zero **old** OID, which is a branch
    /// creation and not a deletion. Only the new OID (field 2) is a boundary.
    @Test("creationLineWithAllZeroOldOIDIsNotADeletionBoundary")
    func creationLineWithAllZeroOldOIDIsNotADeletionBoundary() throws {
        let contents = Fixture.text("recorded-reflog-branchbar-origin-main.txt")
        #expect(contents.hasPrefix(Self.zeroOID), "the fixture's first line is a creation")

        let observation = try #require(ReflogFileReader.parse(contents))
        #expect(observation.pushedAt == Date(timeIntervalSince1970: 1_788_317_856))
        #expect(observation.newOID == "9c866eb0614a34c48edd29a4cb3cdf0358a1ac69")
    }

    // MARK: No usable line

    /// PLAN.md §7, reader half: a zero-byte reflog file yields **no observation**, which is what
    /// sends `PushInfoDeriver` (packet 2.2) to `source = .tipCommitDate`. Reflog files really can
    /// exist and be empty — `recorded-reflog-hannah-personal-agent-origin-updates-3-29-26.txt` is
    /// 0 bytes on Hannah's machine, and that observation is why this rule exists.
    @Test("emptyReflogFileFallsBackToTipCommitDate")
    func emptyReflogFileFallsBackToTipCommitDate() throws {
        #expect(ReflogFileReader.parse(Fixture.text("synthetic-reflog-empty.txt")) == nil)
        #expect(ReflogFileReader.parse(
            Fixture.text("recorded-reflog-hannah-personal-agent-origin-updates-3-29-26.txt")) == nil)
        #expect(ReflogFileReader.parse("") == nil)

        // Present and empty is not the same as absent, and neither is an error.
        let (reader, _) = Self.reader(branch: "updates-3-29-26", contents: "")
        #expect(try reader.observation(
            commonDirectory: "/Users/tester/monorepo/.git",
            remote: "origin",
            branch: "updates-3-29-26") == nil)
    }

    /// `git push --delete` writes a line whose **new** OID is all zeros, and whose message is
    /// still `update by push`. Walking newest-first hits that boundary immediately, so the two
    /// genuine pushes below it are never reported: the remote branch is gone and this clone has no
    /// current push to claim.
    @Test("pushDeletionLineIsNotTreatedAsAPush")
    func pushDeletionLineIsNotTreatedAsAPush() throws {
        let contents = Fixture.text("synthetic-reflog-deletion-line.txt")
        let newest = try #require(contents.split(separator: "\n").last)
        #expect(newest.contains("update by push"), "the deletion line's message says push; only the OID says delete")
        #expect(newest.split(separator: " ")[1] == Substring(Self.zeroOID))

        #expect(ReflogFileReader.parse(contents) == nil,
                "an all-zero new OID is a deletion boundary, not the newest push")

        let (reader, _) = Self.reader(branch: "deleted-upstream", contents: contents)
        #expect(try reader.observation(
            commonDirectory: "/Users/tester/monorepo/.git",
            remote: "origin",
            branch: "deleted-upstream") == nil)
    }

    /// PLAN.md §7. Push, delete, then a push of a **new** branch reusing the name: the walk stops
    /// at the boundary, so the observation is the newer incarnation's push (1788300000, OID d…)
    /// and the older push (1788000000, OID a…) is never attributed to it.
    @Test("pushBeforeADeletionBoundaryIsNotAttributedToTheRecreatedBranch")
    func pushBeforeADeletionBoundaryIsNotAttributedToTheRecreatedBranch() throws {
        let contents = Fixture.text("synthetic-reflog-delete-then-recreate.txt")
        let observation = try #require(ReflogFileReader.parse(contents))

        #expect(observation.pushedAt == Date(timeIntervalSince1970: 1_788_300_000),
                "the push of the current incarnation")
        #expect(observation.newOID == String(repeating: "d", count: 40))

        #expect(observation.pushedAt != Date(timeIntervalSince1970: 1_788_000_000),
                "the pre-deletion push belongs to a branch that no longer exists")
        #expect(observation.newOID != String(repeating: "a", count: 40))
    }

    /// Fetch and pull lines record what this clone **received**, never what it sent. A file with
    /// only those falls back, which is how a branch someone else pushed reads honestly.
    @Test("reflogFileWithOnlyFetchLinesFallsBack")
    func reflogFileWithOnlyFetchLinesFallsBack() throws {
        let contents = Fixture.text("synthetic-reflog-fetch-only.txt")
        #expect(!contents.contains("update by push"))
        #expect(contents.split(separator: "\n").count == 3, "three lines, all of them received")

        #expect(ReflogFileReader.parse(contents) == nil)

        let (reader, _) = Self.reader(branch: "from-elsewhere", contents: contents)
        #expect(try reader.observation(
            commonDirectory: "/Users/tester/monorepo/.git",
            remote: "origin",
            branch: "from-elsewhere") == nil)
    }

    /// PLAN.md §7 and the DECISION-LOG wording rule: the reflog says nothing about other machines.
    /// A branch pushed from a laptop this clone only ever fetched from must yield **no**
    /// observation — never the fetch's timestamp dressed up as a push date.
    @Test("pushFromAnotherMachineYieldsNoObservationNotAFakeDate")
    func pushFromAnotherMachineYieldsNoObservationNotAFakeDate() throws {
        let contents = Fixture.text("synthetic-reflog-fetch-only.txt")
        let observation = ReflogFileReader.parse(contents)

        #expect(observation == nil, "no push was observed, so there is no push date to report")
        #expect(observation?.pushedAt != Date(timeIntervalSince1970: 1_788_200_000),
                "the newest fetch's timestamp is not a push")
        #expect(observation?.pushedAt != Date(timeIntervalSince1970: 1_788_000_000))
    }

    /// PLAN.md §7, reader half: the reader's job is to expose the observed **OID**;
    /// `PushInfoDeriver` (packet 2.2) compares it with the remote-tracking tip and sets
    /// `originMovedSince`. This asserts the input that comparison needs — an OID that is really
    /// the push's, and really different from the tip in `synthetic-for-each-ref-remotes.txt`.
    @Test("observedPushWhoseOIDIsNotTheRemoteTipSetsOriginMovedSince")
    func observedPushWhoseOIDIsNotTheRemoteTipSetsOriginMovedSince() throws {
        let observation = try #require(ReflogFileReader.parse(
            Fixture.text("synthetic-reflog-push-oid-differs-from-tip.txt")))

        #expect(observation.newOID == String(repeating: "b", count: 40),
                "the newest push landed on b…, not on the older a…")
        #expect(observation.pushedAt == Date(timeIntervalSince1970: 1_788_100_000))

        // The remote-tracking tip for origin/main in the paired fixture, read without a parser so
        // this test fails for one reason only.
        let tipLine = try #require(Fixture.text("synthetic-for-each-ref-remotes.txt")
            .split(separator: "\n")
            .first { $0.hasPrefix("refs/remotes/origin/main\u{1F}") })
        let tipOID = String(tipLine.split(separator: "\u{1F}", omittingEmptySubsequences: false)[1])

        #expect(observation.newOID != tipOID,
                "observed OID != remote tip is the condition that appends `(origin has moved since)`")
        #expect(tipOID == String(repeating: "7", count: 40))
    }

    // MARK: Reading through the seam

    /// A push made from a linked worktree lands in the **primary's** reflog file: linked worktrees
    /// share `refs/remotes/` through the common directory, which is why the reader is given the
    /// common dir and never a worktree path. (The Cursor push in spike item 10 is this case.)
    @Test("pushFromLinkedWorktreeIsObserved")
    func pushFromLinkedWorktreeIsObserved() throws {
        let commonDirectory = "/Users/tester/monorepo/.git"
        let expectedPath = "/Users/tester/monorepo/.git/logs/refs/remotes/origin/worktree-spike"
        #expect(ReflogFileReader.reflogPath(
            commonDirectory: commonDirectory, remote: "origin", branch: "worktree-spike") == expectedPath,
                "the reflog lives under the common dir, not under the linked worktree")

        let fs = InMemoryFileSystem(home: "/Users/tester")
        // The linked worktree itself holds only a `gitdir:` pointer; the refs live in the common dir.
        fs.addGitFile(at: "/Users/tester/monorepo/.claude/worktrees/spike",
                      gitdir: "/Users/tester/monorepo/.git/worktrees/spike")
        fs.addFile(expectedPath, contents: Fixture.text("synthetic-reflog-push-and-fetch.txt"))

        let reader = ReflogFileReader(fileSystem: fs)
        let observation = try #require(try reader.observation(
            commonDirectory: commonDirectory, remote: "origin", branch: "worktree-spike"),
                                       "a push from a linked worktree is observed like any other")
        #expect(observation.pushedAt == Date(timeIntervalSince1970: 1_788_200_000),
                "the newest usable line is the push, not the fetch below it")
        #expect(observation.newOID == String(repeating: "c", count: 40))
    }

    /// The OWNER comment splits the two failure modes: an absent file is nil and never throws
    /// (a branch that was never pushed has no reflog), while a file that exists and cannot be read
    /// throws so `RepoLoader` can report it as a `RepoError(stage: .reflog)`.
    @Test("absentReflogIsNilAndUnreadableReflogThrows")
    func absentReflogIsNilAndUnreadableReflogThrows() throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addDirectory("/Users/tester/monorepo/.git")
        let reader = ReflogFileReader(fileSystem: fs)

        #expect(try reader.observation(
            commonDirectory: "/Users/tester/monorepo/.git",
            remote: "origin",
            branch: "never-pushed") == nil,
                "no file means no observation, not an error")

        let denied = ReflogFileReader.reflogPath(
            commonDirectory: "/Users/tester/monorepo/.git", remote: "origin", branch: "denied")
        fs.addFile(denied, contents: Fixture.text("synthetic-reflog-push-and-fetch.txt"))
        fs.markUnreadable(denied)

        #expect(throws: (any Error).self) {
            _ = try reader.observation(
                commonDirectory: "/Users/tester/monorepo/.git", remote: "origin", branch: "denied")
        }
    }

    // MARK: Every recorded fixture

    /// PLAN.md §3: recorded fixtures are ground truth from real `.git/logs/refs/remotes/…` files.
    /// Every one parses to either an observation or an honest nil, and never to a fabricated date.
    @Test("everyRecordedFixtureParsesWithoutError")
    func everyRecordedFixtureParsesWithoutError() throws {
        let names = Fixture.allNames().filter {
            $0.hasPrefix("recorded-reflog-") && $0.hasSuffix(".txt")
        }
        #expect(names.count >= 3, "the inventory records three reflog files")

        let hexDigits = CharacterSet(charactersIn: "0123456789abcdef")

        for name in names {
            let contents = Fixture.text(name)
            let observation = ReflogFileReader.parse(contents)

            if contents.contains("\tupdate by push") {
                let found = try #require(observation, "\(name) holds push lines but yielded no observation")
                #expect(found.newOID.count == 40, "\(name) yielded a malformed OID")
                #expect(CharacterSet(charactersIn: found.newOID).isSubset(of: hexDigits),
                        "\(name) yielded a non-hex OID")
                #expect(found.newOID != Self.zeroOID, "\(name) reported a deletion as a push")
                #expect(found.pushedAt.timeIntervalSince1970 > 1_700_000_000,
                        "\(name) yielded a timestamp that is not field 5")
                #expect(contents.contains(found.newOID), "\(name) yielded an OID that is not in the file")
            } else {
                #expect(observation == nil, "\(name) holds no push line but yielded an observation")
            }
        }
    }
}
