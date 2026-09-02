import Foundation
import Testing

@testable import BranchBarCore

/// Acceptance tests for `RepoLoader`, packet 3.1, written from PLAN.md §3 (per-stage isolation),
/// §5 (the frozen invocations and their order), the §7 named invariants, and the OWNER comment on
/// the stub.
///
/// Everything runs through `RecordedCommandRunner` and `InMemoryFileSystem`, so no git or gh
/// process starts and no reflog file is read off disk. The runner records an Issue for any
/// command it was not told about, which is what makes "issues no gh calls" a real assertion
/// rather than a hopeful one.
///
/// API this packet's implementer adds beyond the frozen stub, and nothing else: one defaulted
/// trailing parameter on `load` carrying the repo from the previous refresh —
///
///     previous: Repo? = nil
///
/// — because PLAN.md §3 says a total failure of `for-each-ref` returns the previous repo marked
/// stale, and the frozen signature has nowhere else to get it from.
@Suite("RepoLoader — one repo, every stage isolated")
struct RepoLoaderTests {

    // MARK: The frozen argv (PLAN.md §5, verbatim)

    private enum Argv {
        static let repo = "/Users/tester/monorepo"
        static let commonDirectory = "/Users/tester/monorepo/.git"

        static let headsFormat =
            "--format=%(refname)%1f%(objectname)%1f%(committerdate:unix)%1f%(upstream:short)%1f%(upstream:remotename)%1f%(upstream:track,nobracket)%1f%(HEAD)"
        static let remotesFormat = "--format=%(refname)%1f%(objectname)%1f%(committerdate:unix)"

        static let identity = ["-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel"]
        static let remoteOriginURL = ["-C", repo, "config", "--get", "remote.origin.url"]
        static let branchRefs = ["-C", repo, "for-each-ref", headsFormat, "--", "refs/heads"]
        static let remoteRefs = ["-C", repo, "for-each-ref", remotesFormat, "--", "refs/remotes/"]
        static let worktrees = ["-C", repo, "worktree", "list", "--porcelain"]
    }

    private enum GH {
        static let path = "/opt/homebrew/bin/gh"
        static let slug = GitHubSlug(host: "github.com", owner: "tester", name: "demo")
        static var fields: String { GHClient.jsonFields }

        static let auth = ["auth", "status", "--hostname", "github.com"]

        static var recent: [String] {
            ["pr", "list", "--repo", slug.ghRepoArgument, "--state", "all", "--limit", "100", "--json", fields]
        }

        static func head(_ branch: String) -> [String] {
            ["pr", "list", "--repo", slug.ghRepoArgument, "--state", "all", "--head", branch, "--limit", "5",
             "--json", fields]
        }

        static var author: [String] {
            ["pr", "list", "--repo", slug.ghRepoArgument, "--state", "open", "--author", "@me", "--limit", "100",
             "--json", fields]
        }
    }

    /// The seven `refs/heads` rows of the mixed fixture, newest committer date first — the order
    /// the per-head fallback spends its cap in.
    private static let branchNamesByRecency = [
        "main", "ahead-two", "behind-three", "diverged", "upstream-gone", "no-upstream", "feature/nested name",
    ]

    private static let discovered = DiscoveredRepo(
        path: Argv.repo,
        id: RepoID(commonDir: Argv.commonDirectory))

    private static let now = Date(timeIntervalSince1970: 1_788_400_000)

    // MARK: Builders

    /// Every git stage stubbed with the recorded and synthetic fixtures, so a test only has to
    /// say which stage it wants to break. `RecordedCommandRunner` answers with the **first**
    /// matching stub, so a test that breaks a stage registers its failure stub before calling
    /// this.
    private static func stubGitStages(_ runner: RecordedCommandRunner) {
        runner.stubGit(Argv.identity, stdout: "\(Argv.commonDirectory)\n\(Argv.repo)\n")
        runner.stubGit(Argv.remoteOriginURL, stdout: "https://github.com/tester/demo.git\n")
        runner.stubGit(Argv.branchRefs, stdout: Fixture.text("synthetic-for-each-ref-heads-mixed.txt"))
        runner.stubGit(Argv.remoteRefs, stdout: Fixture.text("synthetic-for-each-ref-remotes.txt"))
        runner.stubGit(Argv.worktrees, stdout: Fixture.text("synthetic-worktree-list-multi.txt"))
    }

    private static func stubGH(_ runner: RecordedCommandRunner, recent: String? = nil) {
        runner.stub(.init(executableName: "gh", arguments: GH.auth,
                          result: .stdout(Fixture.text("recorded-gh-auth-status-github.com.txt"))))
        runner.stub(.init(executableName: "gh", arguments: GH.recent,
                          result: .stdout(recent ?? Fixture.text("synthetic-gh-pr-list-empty.json"))))
        runner.stub(.init(executableName: "gh", arguments: GH.author,
                          result: .stdout(Fixture.text("synthetic-gh-pr-list-empty.json"))))
        for name in branchNamesByRecency {
            runner.stub(.init(executableName: "gh", arguments: GH.head(name),
                              result: .stdout(Fixture.text("synthetic-gh-pr-list-empty.json"))))
        }
    }

    /// A filesystem holding one reflog file, for `origin/main`.
    private static func fileSystem(withMainReflog: Bool = true) -> InMemoryFileSystem {
        let fs = InMemoryFileSystem()
        if withMainReflog {
            fs.addFile(
                ReflogFileReader.reflogPath(commonDirectory: Argv.commonDirectory, remote: "origin", branch: "main"),
                contents: Fixture.text("synthetic-reflog-push-and-fetch.txt"))
        }
        return fs
    }

    private static func loader(
        _ runner: RecordedCommandRunner,
        fileSystem: FileSystem? = nil,
        gh: GHClient? = nil,
        policy: RefreshPolicy = .default
    ) -> RepoLoader {
        RepoLoader(
            git: GitClient(runner: runner, gitPath: "/usr/bin/git", timeout: policy.gitTimeout),
            gh: gh ?? GHClient(runner: runner, ghPath: GH.path, policy: policy),
            reflog: ReflogFileReader(fileSystem: fileSystem ?? Self.fileSystem()),
            policy: policy)
    }

    private static func branch(_ repo: Repo, _ name: String) -> Branch? {
        repo.branches.first { $0.name == name }
    }

    private static func ghCalls(_ runner: RecordedCommandRunner) -> [Command] {
        runner.calls(matchingExecutable: "gh")
    }

    // MARK: - Per-stage isolation — PLAN.md §7 `oneStageFailingLeavesOtherStagesPopulated`

    /// PLAN.md §3: "a stage that fails is recorded as a `RepoError` and the other stages still
    /// run". The worktree stage exits 128; the branches, remote refs, remote URL, and reflog
    /// facts all survive, and nothing throws.
    @Test("oneStageFailingLeavesOtherStagesPopulated")
    func oneStageFailingLeavesOtherStagesPopulated() async throws {
        let runner = RecordedCommandRunner()
        // Registered first: the first matching stub wins.
        runner.stub(.init(executableName: "git", arguments: Argv.worktrees,
                          result: .exit(128, stderr: "fatal: not a git repository")))
        Self.stubGitStages(runner)

        let repo = await Self.loader(runner).load(
            Self.discovered, wantsPullRequests: false, cachedPRs: nil, now: Self.now)

        #expect(repo.worktrees.isEmpty, "the stage that failed contributes nothing")
        #expect(repo.errors.map(\.stage).contains(.worktrees), "and says so")
        #expect(repo.errors.count == 1, "only the failing stage is recorded")

        #expect(repo.branches.count == 7, "the seven refs/heads rows of the fixture")
        #expect(repo.remoteURL == "https://github.com/tester/demo.git")
        #expect(repo.githubSlug == GH.slug)
        #expect(Self.branch(repo, "main")?.push.source == .reflogObserved,
                "the reflog stage still ran")
        #expect(Self.branch(repo, "ahead-two")?.push.aheadOfLastKnownRemote == 2)
        #expect(repo.isStale == false, "one stage failing is not a stale repo")
    }

    /// The reflog stage is per branch: an unreadable file for one branch is a `RepoError(.reflog)`
    /// and every other branch still derives its push facts. Reporting it matters — silently
    /// swallowing the read would render "Last push unknown" for a branch that has been pushed.
    @Test("unreadableReflogFileIsReportedAndOtherBranchesStillDerive")
    func unreadableReflogFileIsReportedAndOtherBranchesStillDerive() async throws {
        let runner = RecordedCommandRunner()
        Self.stubGitStages(runner)

        let fs = Self.fileSystem()
        let aheadTwoPath = ReflogFileReader.reflogPath(
            commonDirectory: Argv.commonDirectory, remote: "origin", branch: "ahead-two")
        fs.addFile(aheadTwoPath, contents: Fixture.text("synthetic-reflog-push-and-fetch.txt"))
        fs.markUnreadable(aheadTwoPath)

        let repo = await Self.loader(runner, fileSystem: fs).load(
            Self.discovered, wantsPullRequests: false, cachedPRs: nil, now: Self.now)

        #expect(repo.errors.map(\.stage).contains(.reflog))
        #expect(repo.errors.contains { $0.message.contains("ahead-two") }, "the error names the file it could not read")
        #expect(Self.branch(repo, "main")?.push.source == .reflogObserved,
                "one unreadable file does not blank the other branches")
        #expect(repo.branches.count == 7)
    }

    /// `RepoLoader.load` is `async -> Repo` with no `throws`, which is what makes
    /// `oneRepoFailingLeavesOthersPopulated` hold one level up: a repo whose every git stage fails
    /// still returns a `Repo` carrying its errors, so the coordinator's other repos are untouched.
    @Test("oneRepoFailingLeavesOthersPopulated")
    func oneRepoFailingLeavesOthersPopulated() async throws {
        let runner = RecordedCommandRunner()
        Self.stubGitStages(runner)

        let brokenPath = "/Users/tester/broken"
        let broken = DiscoveredRepo(path: brokenPath, id: RepoID(commonDir: brokenPath + "/.git"))
        for arguments in [
            ["-C", brokenPath, "rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel"],
            ["-C", brokenPath, "config", "--get", "remote.origin.url"],
            ["-C", brokenPath, "for-each-ref", Argv.headsFormat, "--", "refs/heads"],
            ["-C", brokenPath, "for-each-ref", Argv.remotesFormat, "--", "refs/remotes/"],
            ["-C", brokenPath, "worktree", "list", "--porcelain"],
        ] {
            runner.stub(.init(executableName: "git", arguments: arguments,
                              result: .failure(.launchFailed(executable: "/usr/bin/git", message: "no such file"))))
        }

        let loader = Self.loader(runner)
        let failed = await loader.load(broken, wantsPullRequests: false, cachedPRs: nil, now: Self.now)
        let healthy = await loader.load(Self.discovered, wantsPullRequests: false, cachedPRs: nil, now: Self.now)

        #expect(failed.branches.isEmpty)
        #expect(!failed.errors.isEmpty, "the failing repo reports rather than throwing")
        #expect(failed.name == "broken", "and still renders as a section")

        #expect(healthy.branches.count == 7, "the healthy repo is untouched by its neighbour")
        #expect(healthy.errors.isEmpty)
    }

    // MARK: - PLAN.md §7 `forEachRefFailureReturnsPreviousRepoMarkedStale`

    /// The branch list is the repo. When `for-each-ref -- refs/heads` fails there is nothing
    /// honest to render, so the previous refresh's repo comes back marked stale with the error
    /// attached — the rows go grey, they do not vanish.
    @Test("forEachRefFailureReturnsPreviousRepoMarkedStale")
    func forEachRefFailureReturnsPreviousRepoMarkedStale() async throws {
        let runner = RecordedCommandRunner()
        runner.stub(.init(executableName: "git", arguments: Argv.branchRefs,
                          result: .exit(128, stderr: "fatal: bad revision")))
        Self.stubGitStages(runner)

        let previous = Repo(
            id: Self.discovered.id,
            name: "monorepo",
            path: Argv.repo,
            branches: [
                Branch(name: "main", tipSHA: String(repeating: "7", count: 40),
                       committerDate: Date(timeIntervalSince1970: 1_788_310_842)),
                Branch(name: "ahead-two", tipSHA: String(repeating: "8", count: 40),
                       committerDate: Date(timeIntervalSince1970: 1_788_300_000)),
            ],
            lastActivity: Date(timeIntervalSince1970: 1_788_310_842))

        let repo = await Self.loader(runner).load(
            Self.discovered, wantsPullRequests: false, cachedPRs: nil, now: Self.now, previous: previous)

        #expect(repo.branches.map(\.name) == ["main", "ahead-two"], "the previous rows, unchanged")
        #expect(repo.isStale, "and marked stale")
        #expect(repo.errors.map(\.stage).contains(.branches))

        // With no previous refresh there is nothing to keep, but the failure is still reported.
        let cold = await Self.loader(runner).load(
            Self.discovered, wantsPullRequests: false, cachedPRs: nil, now: Self.now)
        #expect(cold.branches.isEmpty)
        #expect(cold.isStale)
        #expect(cold.errors.map(\.stage).contains(.branches))
    }

    // MARK: - Laziness — PLAN.md §7 `prCacheWithinTTLIssuesNoGhCalls`

    /// PLAN.md §3: `gh` runs only when the repo is expanded or in the 5 most recently active. A
    /// coordinator that did not ask for PRs gets git facts and not one `gh` process — and every
    /// branch reads `notLoaded`, which is the honest "PR status loads when expanded".
    @Test("loaderIssuesNoGhCallsWhenNotEager")
    func loaderIssuesNoGhCallsWhenNotEager() async throws {
        let runner = RecordedCommandRunner()
        Self.stubGitStages(runner)
        Self.stubGH(runner)

        let repo = await Self.loader(runner).load(
            Self.discovered, wantsPullRequests: false, cachedPRs: nil, now: Self.now)

        #expect(Self.ghCalls(runner).isEmpty, "not even `gh auth status`")
        #expect(repo.branches.count == 7, "git still ran")
        #expect(repo.prLoadState == .notLoaded)
        #expect(repo.branches.allSatisfy { $0.prStatus == .notLoaded })
        #expect(repo.prFetchedAt == nil)
    }

    /// "The cache exists for latency, not quota" — but a warm cache still means no process. A
    /// cache entry inside `prCacheTTL` answers the PR question outright.
    @Test("loaderIssuesNoGhCallsWhenPRCacheIsFresh")
    func loaderIssuesNoGhCallsWhenPRCacheIsFresh() async throws {
        let runner = RecordedCommandRunner()
        Self.stubGitStages(runner)
        Self.stubGH(runner)

        let fetchedAt = Self.now.addingTimeInterval(-60)
        let cached = PRCacheEntry(
            fetchedAt: fetchedAt,
            prs: try PRListDecoder.decode(Fixture.data("synthetic-gh-pr-list-mixed.json")),
            authorPRs: [])

        let repo = await Self.loader(runner).load(
            Self.discovered, wantsPullRequests: true, cachedPRs: cached, now: Self.now)

        #expect(Self.ghCalls(runner).isEmpty, "60 s into a 600 s TTL, nothing is asked")
        #expect(repo.prLoadState == .loaded)
        #expect(repo.prFetchedAt == fetchedAt, "the answer is as old as the cache says it is")
        #expect(repo.branches.count == 7)
    }

    /// The same invariant under its PLAN.md §7 name, and its other half: past the TTL the loader
    /// does ask, so a warm cache never becomes a permanently frozen one.
    @Test("prCacheWithinTTLIssuesNoGhCalls")
    func prCacheWithinTTLIssuesNoGhCalls() async throws {
        let policy = RefreshPolicy(prCacheTTL: 600)

        let fresh = RecordedCommandRunner()
        Self.stubGitStages(fresh)
        Self.stubGH(fresh)
        _ = await Self.loader(fresh, policy: policy).load(
            Self.discovered,
            wantsPullRequests: true,
            cachedPRs: PRCacheEntry(fetchedAt: Self.now.addingTimeInterval(-599)),
            now: Self.now)
        #expect(Self.ghCalls(fresh).isEmpty)

        let stale = RecordedCommandRunner()
        Self.stubGitStages(stale)
        Self.stubGH(stale)
        let repo = await Self.loader(stale, policy: policy).load(
            Self.discovered,
            wantsPullRequests: true,
            cachedPRs: PRCacheEntry(fetchedAt: Self.now.addingTimeInterval(-601)),
            now: Self.now)
        #expect(!Self.ghCalls(stale).isEmpty, "past the TTL the repo is asked again")
        #expect(repo.prFetchedAt == Self.now, "and the answer is dated now")
    }

    // MARK: - The eager path

    /// The three frozen `gh pr list` invocations, in PLAN.md §5's order, once the coordinator asks
    /// and the cache is cold: the recent-100 list, a per-head query for every branch it did not
    /// match, and the author-@me list. Every queried head that came back empty is `none`; nothing
    /// is left `notChecked` when the cap was not reached.
    @Test("eagerColdCacheRunsTheThreeFrozenGhInvocations")
    func eagerColdCacheRunsTheThreeFrozenGhInvocations() async throws {
        let runner = RecordedCommandRunner()
        Self.stubGitStages(runner)
        Self.stubGH(runner)

        let repo = await Self.loader(runner).load(
            Self.discovered, wantsPullRequests: true, cachedPRs: nil, now: Self.now)

        let gh = Self.ghCalls(runner).map(\.arguments)
        #expect(gh.contains(GH.auth), "the per-host preflight")
        #expect(gh.contains(GH.recent))
        #expect(gh.contains(GH.author))
        for name in Self.branchNamesByRecency {
            #expect(gh.contains(GH.head(name)), "\(name) was unmatched, so its head is queried")
        }

        #expect(repo.prAvailability == .available)
        #expect(repo.prLoadState == .loaded)
        #expect(repo.prFetchedAt == Self.now)
        #expect(repo.branches.allSatisfy { $0.prStatus == PRStatus.none },
                "queried and answered with nothing, on every branch")
    }

    /// The cap is per repo per refresh, and what it protects is honesty: PLAN.md §5 says branches
    /// past it render `notChecked`, never `none`. The cap is spent on the most recently active
    /// branches, because those are the ones a PR is likely to exist for.
    @Test("perHeadFallbackCapLeavesTheRestNotChecked")
    func perHeadFallbackCapLeavesTheRestNotChecked() async throws {
        let runner = RecordedCommandRunner()
        Self.stubGitStages(runner)
        Self.stubGH(runner)

        let repo = await Self.loader(runner, policy: RefreshPolicy(perHeadFallbackCap: 3)).load(
            Self.discovered, wantsPullRequests: true, cachedPRs: nil, now: Self.now)

        let queried = Self.ghCalls(runner).filter { $0.arguments.contains("--head") }
        #expect(queried.count == 3, "the cap, not the branch count")

        let asked = Array(Self.branchNamesByRecency.prefix(3))
        for name in asked {
            let branch = try #require(Self.branch(repo, name))
            #expect(branch.prStatus == PRStatus.none, "\(name) was queried and has no PR")
        }
        for name in Self.branchNamesByRecency.dropFirst(3) {
            let branch = try #require(Self.branch(repo, name))
            #expect(branch.prStatus == .notChecked, "\(name) was never asked about")
        }
    }

    /// A `gh` that is not installed is a repo-wide answer, not a crash and not an empty PR list:
    /// the recent-100 call fails to launch, the availability carries `ghNotInstalled`, every
    /// branch reads `unavailable`, and the loader never issues the follow-up calls.
    @Test("ghFailureMakesEveryBranchUnavailableAndSkipsTheFollowUpCalls")
    func ghFailureMakesEveryBranchUnavailableAndSkipsTheFollowUpCalls() async throws {
        let runner = RecordedCommandRunner()
        Self.stubGitStages(runner)
        runner.stub(.init(executableName: "gh", arguments: GH.auth,
                          result: .failure(.launchFailed(executable: GH.path, message: "gh: command not found"))))

        let repo = await Self.loader(runner).load(
            Self.discovered, wantsPullRequests: true, cachedPRs: nil, now: Self.now)

        #expect(repo.branches.count == 7, "git facts survive a missing gh")
        #expect(repo.branches.allSatisfy { $0.prStatus == .unavailable })
        if case .unavailable(let reason, _) = repo.prAvailability {
            #expect(reason == .ghNotInstalled)
        } else {
            Issue.record("expected an unavailable PRAvailability, got \(repo.prAvailability)")
        }
        #expect(repo.errors.map(\.stage).contains(.github))
        #expect(!Self.ghCalls(runner).contains { $0.arguments.contains("--head") },
                "no point querying heads on a host that cannot answer")
    }

    /// PLAN.md §5: `noRemote` and `notGitHubRemote` are answers about the repo, reached without a
    /// `gh` process. A repo with no `remote.origin.url` never runs one.
    @Test("repoWithNoRemoteIsUnavailableWithoutRunningGh")
    func repoWithNoRemoteIsUnavailableWithoutRunningGh() async throws {
        let runner = RecordedCommandRunner()
        // git exit 1 with empty stdout is "the key is unset", which is an answer.
        runner.stub(.init(executableName: "git", arguments: Argv.remoteOriginURL, result: .exit(1)))
        Self.stubGitStages(runner)
        Self.stubGH(runner)

        let repo = await Self.loader(runner).load(
            Self.discovered, wantsPullRequests: true, cachedPRs: nil, now: Self.now)

        #expect(Self.ghCalls(runner).isEmpty)
        #expect(repo.remoteURL == nil)
        #expect(repo.githubSlug == nil)
        if case .unavailable(let reason, _) = repo.prAvailability {
            #expect(reason == .noRemote)
        } else {
            Issue.record("expected noRemote, got \(repo.prAvailability)")
        }
        #expect(repo.branches.allSatisfy { $0.prStatus == .unavailable })
        #expect(repo.errors.isEmpty, "an unset remote is not a stage failure")
    }
}
