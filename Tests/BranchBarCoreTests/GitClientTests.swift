import Foundation
import Testing

@testable import BranchBarCore

/// Acceptance tests for `GitClient`, packet 2.1, written from the frozen contract (PLAN.md §5
/// "Exact invocations", §7 named invariants, and the OWNER comments on the stub) by an agent that
/// does not write the implementation.
///
/// Every assertion here is about the **argv, environment, working directory, and timeout** the
/// client hands the `CommandRunner` seam. PLAN.md §7: "Every §5 invocation is executed verbatim
/// against `/usr/bin/git` 2.39.5 … A frozen command that returns nothing on a live repo is a
/// packet 1.1 failure." `LiveRepoSanityTests` proves those argv arrays still work against real
/// git; these prove `GitClient` sends exactly them.
@Suite("GitClient — the frozen git invocations")
struct GitClientTests {

    private static let repo = Argv.repo
    private static let defaultGitPath = "/usr/bin/git"

    /// PLAN.md §5, verbatim. `--` appears only where git was verified to accept it
    /// (`for-each-ref`) and never on `reflog show`, which silently returns zero rows and exit 0
    /// when one is present.
    private enum Argv {
        static let repo = "/Users/tester/monorepo"

        static let headsFormat =
            "--format=%(refname)%1f%(objectname)%1f%(committerdate:unix)%1f%(upstream:short)%1f%(upstream:remotename)%1f%(upstream:track,nobracket)%1f%(HEAD)"
        static let remotesFormat = "--format=%(refname)%1f%(objectname)%1f%(committerdate:unix)"
        static let reflogFormat = "--format=%gd%x1f%gs%x1f%H"

        static let branchRefs = ["-C", repo, "for-each-ref", headsFormat, "--", "refs/heads"]
        static let remoteRefs = ["-C", repo, "for-each-ref", remotesFormat, "--", "refs/remotes/"]
        static let worktrees = ["-C", repo, "worktree", "list", "--porcelain", "-z"]
        // codex round 2, MAJOR 3: two invocations, not one. `rev-parse` separates its two paths
        // with a newline, and a directory may legally contain one, so a single response cannot be
        // split back into the two paths it came from.
        static let commonDir = ["-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"]
        static let topLevel = ["-C", repo, "rev-parse", "--path-format=absolute", "--show-toplevel"]
        static let remoteOriginURL = ["-C", repo, "config", "--get", "remote.origin.url"]

        static func reflogShow(_ ref: String) -> [String] {
            ["-C", repo, "reflog", "show", "--date=unix", reflogFormat, ref]
        }
    }

    private static func client(_ runner: RecordedCommandRunner, gitPath: String = defaultGitPath) -> GitClient {
        GitClient(runner: runner, gitPath: gitPath)
    }

    /// PLAN.md §5: git env `LC_ALL=C` (so the output stays parseable under any locale) and
    /// `GIT_OPTIONAL_LOCKS=0` (so a read never takes `index.lock` while the user is mid-commit in
    /// another tool), `-C <repo>` as the first two arguments, the repo as the working directory,
    /// and the 10 s git timeout.
    private static func expectFrozenShape(
        _ command: Command,
        arguments: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(command.arguments == arguments,
                "argv must be PLAN.md §5 verbatim", sourceLocation: sourceLocation)
        #expect((command.executable as NSString).lastPathComponent == "git",
                "the executable is the resolved git, never a shell", sourceLocation: sourceLocation)
        #expect(command.arguments.first == "-C", sourceLocation: sourceLocation)
        #expect(command.arguments.dropFirst().first == repo, sourceLocation: sourceLocation)
        #expect(command.workingDirectory == repo,
                "the working directory is the repo path", sourceLocation: sourceLocation)
        #expect(command.environment?["LC_ALL"] == "C", sourceLocation: sourceLocation)
        #expect(command.environment?["GIT_OPTIONAL_LOCKS"] == "0", sourceLocation: sourceLocation)
        #expect(command.timeout == 10, "PLAN.md §5 freezes the git timeout at 10 s", sourceLocation: sourceLocation)
    }

    // MARK: rev-parse

    @Test("identityRunsTheFrozenRevParseInvocation")
    func identityRunsTheFrozenRevParseInvocation() async throws {
        let runner = RecordedCommandRunner()
        runner.stubGit(Argv.commonDir, stdout: Fixture.text("recorded-branchbar-rev-parse-common-dir.txt"))
        runner.stubGit(Argv.topLevel, stdout: Fixture.text("recorded-branchbar-rev-parse-toplevel.txt"))

        let identity = try await Self.client(runner).identity(at: Self.repo)
        #expect(identity.commonDirectory == "/Users/hannahstulberg/branchbar/.git")
        #expect(identity.topLevel == "/Users/hannahstulberg/branchbar")

        let calls = runner.calls
        Self.expectFrozenShape(try #require(calls.first), arguments: Argv.commonDir)
        Self.expectFrozenShape(try #require(calls.dropFirst().first), arguments: Argv.topLevel)
        for call in calls {
            #expect(call.arguments.contains("--path-format=absolute"),
                    "without it git prints a relative common dir and the reflog path breaks")
        }
        // codex round 2, MAJOR 3. This used to read "one invocation returns both paths", which is
        // exactly the defect: the two paths came back newline-separated, and a folder named
        // `project\narchive` shifted the fields, so dedupe keyed on the wrong id and later
        // commands ran with a fragment as their working directory.
        #expect(runner.callCount == 2, "one invocation per path, so a newline cannot shift them")
    }

    // MARK: config

    /// PLAN.md §5: an unset key is git exit 1 with empty stdout, which is
    /// `PRUnavailableReason.noRemote` — not a command failure and not a throw.
    @Test("remoteOriginURLIsTrimmedAndNilWhenTheKeyIsUnset")
    func remoteOriginURLIsTrimmedAndNilWhenTheKeyIsUnset() async throws {
        let present = RecordedCommandRunner()
        present.stubGit(Argv.remoteOriginURL,
                        stdout: Fixture.text("recorded-branchbar-config-remote-origin-url.txt"))

        let url = try await Self.client(present).remoteOriginURL(at: Self.repo)
        #expect(url == "https://github.com/hannahstulberg/branchbar.git",
                "the recorded fixture's trailing newline is trimmed off")
        Self.expectFrozenShape(try #require(present.calls.first), arguments: Argv.remoteOriginURL)

        let unset = RecordedCommandRunner()
        unset.stub(.init(executableName: "git",
                         arguments: Argv.remoteOriginURL,
                         result: .exit(1, stdout: "", stderr: "")))

        let missing = try await Self.client(unset).remoteOriginURL(at: Self.repo)
        #expect(missing == nil, "no remote is an answer, not a failure")
    }

    // MARK: for-each-ref

    /// `--` is used **only** where it was verified to work. `refs/heads` is the operand after it.
    @Test("branchRefsRunsForEachRefWithTheFrozenSeparatorAndFormat")
    func branchRefsRunsForEachRefWithTheFrozenSeparatorAndFormat() async throws {
        let runner = RecordedCommandRunner()
        runner.stubGit(Argv.branchRefs,
                       stdout: Fixture.text("recorded-hannah-personal-agent-for-each-ref-heads.txt"))

        let rows = try await Self.client(runner).branchRefs(at: Self.repo)
        #expect(rows.count == 3, "the client returns ForEachRefParser.parseBranches of stdout")
        #expect(rows.first?.refName == "refs/heads/main")

        let call = try #require(runner.calls.first)
        Self.expectFrozenShape(call, arguments: Argv.branchRefs)
        #expect(call.arguments.dropLast().last == "--", "`--` sits immediately before the pattern")
        #expect(call.arguments.last == "refs/heads")
        #expect(call.arguments.contains(Argv.headsFormat), "all seven atoms, in the frozen order")
        #expect(call.arguments.filter { $0.hasPrefix("--format=") }.count == 1,
                "the format is one argument, never a `--format` / value pair")
    }

    @Test("remoteRefsRunsForEachRefOverRefsRemotes")
    func remoteRefsRunsForEachRefOverRefsRemotes() async throws {
        let runner = RecordedCommandRunner()
        runner.stubGit(Argv.remoteRefs,
                       stdout: Fixture.text("recorded-branchbar-for-each-ref-remotes.txt"))

        let rows = try await Self.client(runner).remoteRefs(at: Self.repo)
        #expect(rows.first?.shortName == "origin/main")

        let call = try #require(runner.calls.first)
        Self.expectFrozenShape(call, arguments: Argv.remoteRefs)
        #expect(call.arguments.dropLast().last == "--")
        #expect(call.arguments.last == "refs/remotes/", "the trailing slash is part of the frozen pattern")
        #expect(call.arguments.contains(Argv.remotesFormat), "three atoms here, not seven")
    }

    // MARK: worktree list

    @Test("worktreesRunsWorktreeListPorcelain")
    func worktreesRunsWorktreeListPorcelain() async throws {
        let runner = RecordedCommandRunner()
        runner.stubGit(Argv.worktrees, stdout: Fixture.text("recorded-branchbar-worktree-list.txt"))

        let worktrees = try await Self.client(runner).worktrees(at: Self.repo)
        #expect(worktrees.count == 1)
        #expect(worktrees.first?.isPrimary == true)

        let call = try #require(runner.calls.first)
        Self.expectFrozenShape(call, arguments: Argv.worktrees)
        #expect(!call.arguments.contains("--"), "`worktree list` takes no separator in the frozen list")
        // Was `!contains("-z")` until the codex pre-ship review (MAJOR 12): git 2.39.5 prints a
        // path containing a newline raw under the newline-delimited porcelain, so one record
        // splits into several and the whole stage throws. `-z` is now part of the frozen argv.
        #expect(call.arguments.contains("-z"), "the porcelain is NUL-delimited, as recorded")
    }

    // MARK: reflog show

    /// CLAUDE.md's rule from a real bug, pinned live in `LiveRepoSanityTests`: with a `--`
    /// separator `git reflog show` returns zero rows and exit 0 on 2.39.5 and 2.52, so a client
    /// that adds one reports "never pushed" for every branch and nothing fails loudly.
    @Test("reflogShowCarriesNoDoubleDashSeparator")
    func reflogShowCarriesNoDoubleDashSeparator() async throws {
        let ref = "refs/remotes/origin/main"
        let runner = RecordedCommandRunner()
        runner.stubGit(Argv.reflogShow(ref),
                       stdout: Fixture.text("recorded-branchbar-reflog-show-origin-main.txt"))

        let entries = try await Self.client(runner).reflogShow(at: Self.repo, ref: ref)
        #expect(entries.count == 4, "the client returns ReflogParser.parse of stdout")
        #expect(entries.first?.message == "update by push")

        let call = try #require(runner.calls.first)
        Self.expectFrozenShape(call, arguments: Argv.reflogShow(ref))
        #expect(!call.arguments.contains("--"),
                "`reflog show --` is silently empty with exit 0; the separator must never be sent")
        #expect(call.arguments.contains("--date=unix"), "%gd carries a unix time only under --date=unix")
        #expect(call.arguments.contains(Argv.reflogFormat), "%x1f here, because %1f is a for-each-ref atom")
        #expect(!call.arguments.contains("--format=%gd%1f%gs%1f%H"), "%1f would be printed literally")
        #expect(call.arguments.last == ref, "the ref is the last operand")
    }

    /// An empty reflog with exit 0 is an empty list, not an error: a remote-tracking ref this
    /// clone has never seen move has no rows to print.
    @Test("reflogShowEmptyStdoutWithExitZeroIsAnEmptyList")
    func reflogShowEmptyStdoutWithExitZeroIsAnEmptyList() async throws {
        let ref = "refs/remotes/origin/quiet"
        let runner = RecordedCommandRunner()
        runner.stubGit(Argv.reflogShow(ref), stdout: "")

        let entries = try await Self.client(runner).reflogShow(at: Self.repo, ref: ref)
        #expect(entries.isEmpty)
        #expect(runner.callCount == 1)
    }

    /// PLAN.md §7 and §6: "branch names are argv operands and displayed text, never executed."
    /// `Command` holds an array, so a ref whose name begins with `-` reaches git as the last
    /// operand rather than being mangled into a flag or quoted into a shell string.
    @Test("branchNameBeginningWithDashIsPassedAsOperandNotFlag")
    func branchNameBeginningWithDashIsPassedAsOperandNotFlag() async throws {
        let ref = "refs/remotes/origin/-weird"
        let runner = RecordedCommandRunner()
        runner.stubGit(Argv.reflogShow(ref), stdout: "")

        _ = try await Self.client(runner).reflogShow(at: Self.repo, ref: ref)

        let call = try #require(runner.calls.first)
        #expect(call.arguments == Argv.reflogShow(ref))
        #expect(call.arguments.last == ref, "the ref arrives verbatim, dash included")
        #expect(!call.arguments.contains("--"),
                "the fix is the argument array, never a `--` that would empty this command")
        #expect(!call.arguments.contains(where: { $0.contains("'") || $0.contains("\"") }),
                "no shell quoting is added; there is no shell")

        // The same for a branch whose name starts with a dash on the for-each-ref path: the
        // pattern operand is fixed, so a hostile branch name can never become a flag.
        let refs = RecordedCommandRunner()
        refs.stubGit(Argv.branchRefs, stdout: "")
        _ = try await Self.client(refs).branchRefs(at: Self.repo)
        #expect(refs.calls.first?.arguments.last == "refs/heads")
    }

    /// codex MAJOR 1. PLAN.md §6 promises BranchBar stores no secret, but the whole
    /// `remote.origin.url` was retained on every `Repo` and serialized into `cache.json`, and an
    /// HTTPS remote can carry a personal access token as its user info. The URL is sanitized at
    /// the one place it enters the app, so nothing downstream has to remember to.
    @Test("remoteURLUserinfoIsStrippedBeforeStorage")
    func remoteURLUserinfoIsStrippedBeforeStorage() async throws {
        let runner = RecordedCommandRunner()
        runner.stubGit(Argv.remoteOriginURL, stdout: "https://user:token@github.com/o/r.git\n")

        let url = try await Self.client(runner).remoteOriginURL(at: Self.repo)
        #expect(url == "https://github.com/o/r.git")
        #expect(!(url ?? "").contains("token"))
        #expect(!(url ?? "").contains("@"))
        // And the sanitized form still names the same repository.
        #expect(GitHubSlug(remoteURL: try #require(url))
            == GitHubSlug(host: "github.com", owner: "o", name: "r"))

        // Bare user info is how a GitHub token is written, so it goes too — a username and a
        // token are the same shape and cannot be told apart.
        #expect(GitClient.sanitize(remoteURL: "https://ghp_deadbeef@github.com/o/r.git")
            == "https://github.com/o/r.git")
        #expect(GitClient.sanitize(remoteURL: "ssh://git@github.com:22/o/r.git")
            == "ssh://github.com:22/o/r.git")
        #expect(GitClient.sanitize(remoteURL: "git@github.com:o/r.git") == "github.com:o/r.git")
        // A query or fragment is never part of a remote's identity and is the other place a
        // credential arrives.
        #expect(GitClient.sanitize(remoteURL: "https://github.com/o/r.git?access_token=abc#frag")
            == "https://github.com/o/r.git")
        // A remote with nothing to strip is returned byte for byte.
        #expect(GitClient.sanitize(remoteURL: "https://github.com/o/r.git")
            == "https://github.com/o/r.git")
        #expect(GitClient.sanitize(remoteURL: "/Users/tester/mirrors/archive.git")
            == "/Users/tester/mirrors/archive.git")
    }

    // MARK: Environment, working directory, and tool path

    /// One test that walks every frozen invocation, because the environment and the working
    /// directory are the two things a per-command copy-paste gets wrong exactly once.
    @Test("everyGitInvocationCarriesTheFrozenEnvironmentAndWorkingDirectory")
    func everyGitInvocationCarriesTheFrozenEnvironmentAndWorkingDirectory() async throws {
        // The GUI PATH has no Homebrew, so `ToolLocator` may hand the client any absolute path;
        // the stub matches on the basename, the way a machine-independent fixture must.
        let runner = RecordedCommandRunner()
        let client = Self.client(runner, gitPath: "/opt/homebrew/bin/git")

        runner.stubGit(Argv.commonDir, stdout: Fixture.text("recorded-branchbar-rev-parse-common-dir.txt"))
        runner.stubGit(Argv.topLevel, stdout: Fixture.text("recorded-branchbar-rev-parse-toplevel.txt"))
        runner.stubGit(Argv.remoteOriginURL, stdout: Fixture.text("recorded-branchbar-config-remote-origin-url.txt"))
        runner.stubGit(Argv.branchRefs, stdout: Fixture.text("recorded-branchbar-for-each-ref-heads.txt"))
        runner.stubGit(Argv.remoteRefs, stdout: Fixture.text("recorded-branchbar-for-each-ref-remotes.txt"))
        runner.stubGit(Argv.worktrees, stdout: Fixture.text("recorded-branchbar-worktree-list.txt"))
        runner.stubGit(Argv.reflogShow("refs/remotes/origin/main"),
                       stdout: Fixture.text("recorded-branchbar-reflog-show-origin-main.txt"))

        _ = try await client.identity(at: Self.repo)
        _ = try await client.remoteOriginURL(at: Self.repo)
        _ = try await client.branchRefs(at: Self.repo)
        _ = try await client.remoteRefs(at: Self.repo)
        _ = try await client.worktrees(at: Self.repo)
        _ = try await client.reflogShow(at: Self.repo, ref: "refs/remotes/origin/main")

        // Seven since codex round 2 MAJOR 3 split `rev-parse` into one invocation per path.
        #expect(runner.callCount == 7, "seven frozen invocations, no extras")
        #expect(runner.calls(matchingExecutable: "git").count == 7, "GitClient runs git and nothing else")

        for call in runner.calls {
            #expect(call.executable == "/opt/homebrew/bin/git", "the resolved path is used, never bare `git`")
            #expect(call.workingDirectory == Self.repo)
            #expect(call.environment?["LC_ALL"] == "C")
            #expect(call.environment?["GIT_OPTIONAL_LOCKS"] == "0")
            #expect(call.environment?["GIT_NO_LAZY_FETCH"] == "1")
            #expect(call.timeout == 10)
            #expect(Array(call.arguments.prefix(2)) == ["-C", Self.repo], "`-C <repo>` leads every invocation")
        }

        // Two until the codex pre-ship review (MAJOR 13, the git half): `GIT_NO_LAZY_FETCH=1` stops
        // a partial clone from reaching the network behind a read that is contracted never to
        // fetch, and stops the fetch helper that read would spawn from outliving cancellation.
        #expect(
            GitClient.frozenEnvironment
                == ["LC_ALL": "C", "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_LAZY_FETCH": "1"],
            "the frozen set is exactly these three; PLAN.md §5 plus codex MAJOR 13")

        // The one `--` rule, across the whole session: for-each-ref only.
        let withSeparator = runner.calls.filter { $0.arguments.contains("--") }
        #expect(withSeparator.count == 2, "only the two for-each-ref invocations carry a separator")
        #expect(withSeparator.allSatisfy { $0.arguments.contains("for-each-ref") })
    }

    /// A repo whose path carries spaces is one argv element, not two — the arm that a shell string
    /// would break and an array cannot.
    @Test("repoPathWithSpacesStaysOneArgument")
    func repoPathWithSpacesStaysOneArgument() async throws {
        let spaced = "/Users/tester/Developer/repos with spaces/design tokens"
        let arguments = ["-C", spaced, "worktree", "list", "--porcelain", "-z"]

        let runner = RecordedCommandRunner()
        runner.stubGit(arguments, stdout: Fixture.text("recorded-branchbar-worktree-list.txt"))

        _ = try await Self.client(runner).worktrees(at: spaced)

        let call = try #require(runner.calls.first)
        #expect(call.arguments == arguments)
        // Six, not five, since codex MAJOR 12 added `-z` to the frozen argv.
        #expect(call.arguments.count == 6, "the path is one element, spaces and all")
        #expect(call.workingDirectory == spaced)
    }
}

// MARK: - Packet F6 — codex round 2, MAJOR 3

/// "Repository paths containing newlines still corrupt identity and actions." `rev-parse` prints
/// its two paths newline-separated, and a directory name may legally contain a newline, so the
/// response cannot be split back into the two paths that produced it. Worktree output was moved to
/// NUL framing in the first round (MAJOR 12); repo identity was not.
@Suite("A newline inside a repo path stays inside it")
struct GitClientNewlinePathTests {

    private static let path = "/Users/tester/project\narchive"

    @Test("repoPathWithNewlineKeepsItsIdentity")
    func repoPathWithNewlineKeepsItsIdentity() async throws {
        let path = Self.path
        let runner = RecordedCommandRunner()
        runner.stubGit(
            ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            stdout: path + "/.git\n")
        runner.stubGit(
            ["-C", path, "rev-parse", "--path-format=absolute", "--show-toplevel"],
            stdout: path + "\n")

        let identity = try await GitClient(runner: runner, gitPath: "/usr/bin/git").identity(at: Self.path)

        #expect(identity.commonDirectory == Self.path + "/.git")
        #expect(identity.topLevel == Self.path)
        // The reflog path is built from the common directory, so a shifted field sends the reader
        // somewhere else entirely.
        #expect(ReflogFileReader.reflogPath(
            commonDirectory: identity.commonDirectory, remote: "origin", branch: "main")
                == Self.path + "/.git/logs/refs/remotes/origin/main")
    }

    /// Exactly one trailing record newline goes, and only from the end: a path that really ends
    /// in a newline keeps the rest of it, and a response without one is still read.
    @Test("exactlyOneTrailingNewlineIsStripped")
    func exactlyOneTrailingNewlineIsStripped() async throws {
        let runner = RecordedCommandRunner()
        runner.stubGit(
            ["-C", "/r", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            stdout: "/tmp/trailing\n\n")
        runner.stubGit(
            ["-C", "/r", "rev-parse", "--path-format=absolute", "--show-toplevel"],
            stdout: "/tmp/no-newline")

        let identity = try await GitClient(runner: runner, gitPath: "/usr/bin/git").identity(at: "/r")
        #expect(identity.commonDirectory == "/tmp/trailing\n")
        #expect(identity.topLevel == "/tmp/no-newline")
    }

    /// An empty answer is still a failure, so a git that prints nothing cannot become a repo whose
    /// common directory is the empty string.
    @Test("anEmptyRevParseAnswerStillThrows")
    func emptyRevParseAnswerThrows() async throws {
        let runner = RecordedCommandRunner()
        runner.stubGit(
            ["-C", "/r", "rev-parse", "--path-format=absolute", "--git-common-dir"], stdout: "\n")
        runner.stubGit(
            ["-C", "/r", "rev-parse", "--path-format=absolute", "--show-toplevel"], stdout: "/r\n")

        await #expect(throws: CommandError.self) {
            _ = try await GitClient(runner: runner, gitPath: "/usr/bin/git").identity(at: "/r")
        }
    }
}
