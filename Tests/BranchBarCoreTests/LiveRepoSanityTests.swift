import Foundation
import Testing

@testable import BranchBarCore

/// The only two tests allowed to touch real git. PLAN.md §7: "Every §5 invocation is executed
/// verbatim against `/usr/bin/git` 2.39.5 … before packet 1.1 closes. A frozen command that
/// returns nothing on a live repo is a packet 1.1 failure."
///
/// `make record-fixtures` proves that once, on Hannah's machine, at record time. These two run
/// in the suite, so a frozen invocation that silently stops returning rows — the way
/// `git reflog show --` does — fails a build rather than waiting for a re-record.
///
/// They run `/usr/bin/git` (2.39.5, what NYT will have) against this repo, located from
/// `#filePath` so the test works from any checkout, and skip with a recorded reason when the
/// binary is absent or the checkout has no observed push (a CI clone fetches, it never pushes).
enum LiveRepo {
    /// `<repo root>`, from Tests/BranchBarCoreTests/LiveRepoSanityTests.swift.
    static let path: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .path

    static let gitPath = "/usr/bin/git"

    static var hasSystemGit: Bool {
        FileManager.default.isExecutableFile(atPath: gitPath)
    }

    /// True when this checkout's own `origin/main` reflog holds a push line. False in CI, where
    /// `actions/checkout` fetches and never pushes.
    static var hasObservedPush: Bool {
        guard hasSystemGit else { return false }
        guard let commonDir = try? run(["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !commonDir.isEmpty
        else { return false }
        let reflog = (commonDir as NSString).appendingPathComponent("logs/refs/remotes/origin/main")
        guard let contents = try? String(contentsOfFile: reflog, encoding: .utf8) else { return false }
        return contents.contains("update by push")
    }

    /// Runs `/usr/bin/git` with the environment PLAN.md §5 freezes.
    @discardableResult
    static func run(_ arguments: [String]) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in GitClient.frozenEnvironment { environment[key] = value }
        process.environment = environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Small, bounded outputs on this repo; the concurrent-draining requirement belongs to
        // `ProcessCommandRunner` (packet 2.5) and is tested there with a > 1 MB stdout.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self),
            process.terminationStatus
        )
    }
}

@Suite("Live-repo sanity: the frozen invocations still return rows")
struct LiveRepoSanityTests {

    @Test(
        "everyFrozenGitInvocationReturnsOutputOnThisRepo",
        .enabled(if: LiveRepo.hasSystemGit, "/usr/bin/git is not present on this machine")
    )
    func everyFrozenGitInvocationReturnsOutputOnThisRepo() throws {
        let repo = LiveRepo.path

        // Every git invocation in PLAN.md §5, verbatim, in the order the refresh runs them.
        // `for-each-ref` is the one command git verifiably accepts `--` on; `reflog show` is not
        // in this list because it has its own test below, and it must never carry `--`.
        let invocations: [(name: String, arguments: [String])] = [
            (
                "for-each-ref refs/heads",
                ["-C", repo, "for-each-ref",
                 "--format=%(refname)%1f%(objectname)%1f%(committerdate:unix)%1f%(upstream:short)%1f%(upstream:remotename)%1f%(upstream:track,nobracket)%1f%(HEAD)",
                 "--", "refs/heads"]
            ),
            ("worktree list --porcelain", ["-C", repo, "worktree", "list", "--porcelain"]),
            (
                "for-each-ref refs/remotes/",
                ["-C", repo, "for-each-ref",
                 "--format=%(refname)%1f%(objectname)%1f%(committerdate:unix)",
                 "--", "refs/remotes/"]
            ),
            (
                "rev-parse --git-common-dir --show-toplevel",
                ["-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel"]
            ),
            ("config --get remote.origin.url", ["-C", repo, "config", "--get", "remote.origin.url"]),
        ]

        for invocation in invocations {
            let result = try LiveRepo.run(invocation.arguments)
            #expect(result.exitCode == 0, "\(invocation.name) exited \(result.exitCode): \(result.stderr)")
            #expect(
                !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(invocation.name) returned no rows on \(repo); a frozen command that stops returning rows is a contract failure"
            )
        }

        // Shape, not just presence: fields split on U+001F, and the separator is a real control
        // character rather than the literal text `%1f`.
        let heads = try LiveRepo.run(invocations[0].arguments).stdout
        #expect(!heads.contains("%1f"), "the format atom was printed literally instead of emitting U+001F")
        let firstRow = try #require(heads.split(separator: "\n").first)
        #expect(firstRow.split(separator: "\u{1F}", omittingEmptySubsequences: false).count == 7)
        #expect(firstRow.hasPrefix("refs/heads/"))

        let worktrees = try LiveRepo.run(invocations[1].arguments).stdout
        #expect(worktrees.hasPrefix("worktree "))

        let revParse = try LiveRepo.run(invocations[3].arguments).stdout
        let paths = revParse.split(separator: "\n").map(String.init)
        #expect(paths.count == 2, "rev-parse must print the common dir and the top level")
        #expect(paths.allSatisfy { $0.hasPrefix("/") }, "--path-format=absolute must yield absolute paths")

        let remoteURL = try LiveRepo.run(invocations[4].arguments).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = try #require(GitHubSlug(remoteURL: remoteURL), "this repo's remote must parse as a slug")
        #expect(slug.host == "github.com")
        #expect(slug.name == "branchbar")
    }

    /// The secondary fallback, and the reason CLAUDE.md carries a rule about it: with a `--`
    /// separator, `git reflog show` returns zero rows and exit 0 on both 2.39.5 and 2.52. This
    /// test runs it the frozen way (no separator) and asserts rows, then runs it the wrong way
    /// and asserts the silent-empty behavior is still what git does, so the footgun is pinned.
    @Test(
        "reflogShowFallbackReturnsRowsForARefThatHasPushes",
        .enabled(if: LiveRepo.hasObservedPush, "this checkout's origin/main reflog holds no `update by push` line (a CI clone fetches, it never pushes)")
    )
    func reflogShowFallbackReturnsRowsForARefThatHasPushes() throws {
        let frozen = ["-C", LiveRepo.path, "reflog", "show", "--date=unix",
                      "--format=%gd%x1f%gs%x1f%H", "refs/remotes/origin/main"]

        let result = try LiveRepo.run(frozen)
        #expect(result.exitCode == 0, "reflog show exited \(result.exitCode): \(result.stderr)")

        let rows = result.stdout.split(separator: "\n").map(String.init)
        #expect(!rows.isEmpty, "reflog show returned no rows for a ref that has pushes")

        let fields = try #require(rows.first).split(separator: "\u{1F}", omittingEmptySubsequences: false)
        #expect(fields.count == 3, "expected %gd, %gs and %H separated by U+001F")
        // `%x1f`, not `%1f`: the latter is a for-each-ref atom and reflog prints it literally.
        #expect(!result.stdout.contains("%1f"), "the separator atom was printed literally")
        // `%gd` under --date=unix is `origin/main@{<unixtime>}`; the timestamp is inside the braces.
        #expect(fields[0].hasPrefix("origin/main@{"))
        #expect(fields[0].hasSuffix("}"))
        let timestamp = fields[0].dropFirst("origin/main@{".count).dropLast()
        #expect(Int(timestamp) != nil, "the %gd selector must carry a parseable unix timestamp")
        #expect(rows.contains { $0.contains("update by push") })

        // The footgun, pinned: the same command with `--` is silently empty and still exits 0.
        let withSeparator = ["-C", LiveRepo.path, "reflog", "show", "--date=unix",
                             "--format=%gd%x1f%gs%x1f%H", "--", "refs/remotes/origin/main"]
        let separatorResult = try LiveRepo.run(withSeparator)
        #expect(
            separatorResult.stdout.isEmpty && separatorResult.exitCode == 0,
            "git changed behavior: `reflog show --` no longer returns zero rows with exit 0, so the CLAUDE.md rule needs revisiting"
        )
    }
}
