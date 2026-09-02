import Foundation
import Testing

@testable import BranchBarCore

/// Acceptance tests for `WorktreeListParser`, packet 2.1, written from the frozen contract
/// (PLAN.md §5 invocation `git worktree list --porcelain -z`, §7 named invariants, and the OWNER
/// comment on the stub) by an agent that does not write the implementation.
///
/// Porcelain shape: NUL-terminated fields, a record closed by an empty field, each field `key` or
/// `key value`, and only the **first** space separates key from value, because paths and branch
/// names carry spaces. The invocation and the fixtures moved to `-z` after the codex pre-ship
/// review (MAJOR 12), so the input is `Data` rather than `String`.
@Suite("WorktreeListParser — the porcelain records")
struct WorktreeListParserTests {

    /// The first record git prints is the primary worktree, and every later record is linked.
    /// PLAN.md §5a orders rows under the repo, so "which one is the repo itself" cannot be guessed
    /// from the path.
    @Test("firstStanzaIsPrimary")
    func firstStanzaIsPrimary() throws {
        let worktrees = try WorktreeListParser.parse(
            Fixture.data("synthetic-worktree-list-multi.txt"))

        #expect(worktrees.count == 7, "the fixture holds seven records")

        let primary = try #require(worktrees.first)
        #expect(primary.isPrimary)
        #expect(primary.path == "/Users/tester/monorepo")
        #expect(primary.headSHA == "1111111111111111111111111111111111111111")
        #expect(primary.branch == "refs/heads/main", "branch is the full ref, per the Worktree contract")
        #expect(worktrees.dropFirst().allSatisfy { !$0.isPrimary },
                "exactly one record is the primary worktree")

        let recorded = try WorktreeListParser.parse(
            Fixture.data("recorded-branchbar-worktree-list.txt"))
        #expect(recorded.count == 1)
        #expect(recorded.first?.isPrimary == true, "a single-worktree repo's only record is the primary")
        #expect(recorded.first?.path == "/Users/hannahstulberg/branchbar")
        #expect(recorded.first?.branch == "refs/heads/main")
    }

    /// PLAN.md §7, parser half. A `detached` record has `HEAD` and no `branch` line, and a `bare`
    /// record has neither. Both must carry `branch == nil` so the join rules (PLAN.md §5,
    /// "worktrees without a branch never join") can never attach them to a branch row.
    @Test("noBranchWorktreeAppearsUnderRepoAndNoBranchClaimsIt")
    func noBranchWorktreeAppearsUnderRepoAndNoBranchClaimsIt() throws {
        let worktrees = try WorktreeListParser.parse(
            Fixture.data("synthetic-worktree-list-multi.txt"))

        let detached = try #require(worktrees.first {
            $0.path == "/Users/tester/monorepo/.claude/worktrees/detached-review"
        })
        #expect(detached.branch == nil, "a detached checkout claims no branch")
        #expect(detached.headSHA == "3333333333333333333333333333333333333333",
                "the commit is still known; the row reads `at commit 3333333 (no branch)`")
        #expect(detached.isPrimary == false)
        #expect(detached.isBare == false)

        let bare = try #require(worktrees.first { $0.path == "/Users/tester/mirrors/archive.git" })
        #expect(bare.isBare)
        #expect(bare.branch == nil)
        #expect(bare.headSHA.isEmpty, "a bare record prints no HEAD line")

        // Every branch a worktree does claim is a real head ref, so the join key is unambiguous.
        #expect(worktrees.compactMap(\.branch).allSatisfy { $0.hasPrefix("refs/heads/") })
        #expect(worktrees.filter { $0.branch == nil }.count == 3,
                "detached, prunable-detached, and bare records claim no branch")
    }

    /// The three flag lines `git worktree list --porcelain` can print. `bare` and `detached` are
    /// bare keys; `locked` and `prunable` may or may not carry a reason.
    @Test("bareLockedAndPrunableFlagsParse")
    func bareLockedAndPrunableFlagsParse() throws {
        let worktrees = try WorktreeListParser.parse(
            Fixture.data("synthetic-worktree-list-multi.txt"))

        let locked = try #require(worktrees.first { $0.path == "/Users/tester/monorepo/.claude/worktrees/held" })
        #expect(locked.isLocked)
        #expect(locked.isPrunable == false)
        #expect(locked.branch == "refs/heads/worktree-held")

        let prunable = try #require(worktrees.first { $0.path == "/Users/tester/monorepo/.claude/worktrees/gone" })
        #expect(prunable.isPrunable)
        #expect(prunable.isLocked == false)
        #expect(prunable.branch == nil, "the prunable record is also detached")

        let bare = try #require(worktrees.first { $0.isBare })
        #expect(bare.path == "/Users/tester/mirrors/archive.git")
        #expect(bare.isLocked == false)
        #expect(bare.isPrunable == false)

        // Flags are per record, never smeared across the file.
        #expect(worktrees.filter(\.isLocked).count == 1)
        #expect(worktrees.filter(\.isPrunable).count == 1)
        #expect(worktrees.filter(\.isBare).count == 1)
        #expect(worktrees.first?.isLocked == false, "the primary carries none of the flags")
    }

    /// `locked` can be printed bare or with a reason after one space. The reason is the text after
    /// `locked `, whole, spaces included — nothing about it is a key.
    @Test("lockReasonIsCapturedWhenPresent")
    func lockReasonIsCapturedWhenPresent() throws {
        let worktrees = try WorktreeListParser.parse(
            Fixture.data("synthetic-worktree-list-multi.txt"))

        let locked = try #require(worktrees.first { $0.isLocked })
        #expect(locked.lockReason == "waiting on the NYT tester to confirm Gate 0b")

        #expect(worktrees.filter { $0.lockReason != nil }.count == 1)
        #expect(worktrees.first { !$0.isLocked }?.lockReason == nil,
                "an unlocked record carries no reason")
    }

    /// Paths and branch names both carry spaces, which is the whole reason the porcelain is
    /// key-then-rest-of-line and not whitespace-separated fields.
    @Test("pathWithSpacesParses")
    func pathWithSpacesParses() throws {
        let worktrees = try WorktreeListParser.parse(
            Fixture.data("synthetic-worktree-list-multi.txt"))

        let spaced = try #require(worktrees.first { $0.path.contains("repos with spaces") })
        #expect(spaced.path == "/Users/tester/Developer/repos with spaces/design tokens")
        #expect(spaced.branch == "refs/heads/feature/spacing scale",
                "only the first space separates key from value, so the branch name keeps its space")
        #expect(spaced.headSHA == "4444444444444444444444444444444444444444")
        #expect(spaced.isPrimary == false)
    }

    /// codex MAJOR 12. Under the newline-delimited porcelain git 2.39.5 prints a path containing
    /// a newline raw, so the record splits and `parse` throws
    /// `recordWithoutWorktreePath` — which `RepoLoader` turns into `worktrees = []`, and an empty
    /// worktree list quietly moves a checked-out merged branch into the Merged group. Under `-z`
    /// nothing but a NUL ends a field, so the bytes git wrote come back verbatim.
    @Test("worktreePathWithNewlineParsesUnderZ")
    func worktreePathWithNewlineParsesUnderZ() throws {
        let worktrees = try WorktreeListParser.parse(
            Fixture.data("synthetic-worktree-list-z-newline-path.txt"))

        #expect(worktrees.count == 3, "three records, whatever bytes their paths carry")

        let newline = try #require(worktrees.first { $0.path.contains("\n") })
        #expect(newline.path == "/Users/tester/Developer/we\nird path")
        #expect(newline.branch == "refs/heads/feature/new\nline",
                "a branch name's own newline does not end its field either")
        #expect(newline.headSHA == String(repeating: "2", count: 40))
        #expect(newline.isPrimary == false)

        let tabbed = try #require(worktrees.first { $0.path.contains("\t") })
        #expect(tabbed.path == "/Users/tester/monorepo/.claude/worktrees/tabbed\tname")
        #expect(tabbed.branch == nil, "the tabbed record is detached")

        #expect(worktrees.first?.isPrimary == true)
        #expect(worktrees.filter(\.isPrimary).count == 1,
                "a newline inside record 2 must not start a fourth record")
    }

    /// PLAN.md §3: recorded fixtures are ground truth. Both recorded repos hold a single primary
    /// worktree, and both must parse.
    @Test("everyRecordedFixtureParsesWithoutError")
    func everyRecordedFixtureParsesWithoutError() throws {
        let names = Fixture.allNames().filter {
            $0.hasPrefix("recorded-") && $0.hasSuffix("worktree-list.txt")
        }
        #expect(names.count >= 2, "the inventory records worktree list for two repos")

        for name in names {
            let worktrees = try WorktreeListParser.parse(Fixture.data(name))
            #expect(!worktrees.isEmpty, "\(name) parsed to no records")
            #expect(worktrees.first?.isPrimary == true, "\(name) did not mark its first record primary")
            #expect(worktrees.allSatisfy { $0.path.hasPrefix("/") }, "\(name) yielded a relative path")
            #expect(worktrees.filter(\.isPrimary).count == 1, "\(name) marked more than one record primary")
        }
    }
}
