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

        // codex round 2, MAJOR 3: one invocation per path. `rev-parse` separates its two paths
        // with a newline, and a directory name may legally contain one, so a combined answer
        // cannot be split back into the two paths that produced it.
        static let identityCommonDir = ["-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"]
        static let identityTopLevel = ["-C", repo, "rev-parse", "--path-format=absolute", "--show-toplevel"]
        static let remoteOriginURL = ["-C", repo, "config", "--get", "remote.origin.url"]
        static let branchRefs = ["-C", repo, "for-each-ref", headsFormat, "--", "refs/heads"]
        static let remoteRefs = ["-C", repo, "for-each-ref", remotesFormat, "--", "refs/remotes/"]
        static let worktrees = ["-C", repo, "worktree", "list", "--porcelain", "-z"]
    }

    private enum GH {
        static let path = "/opt/homebrew/bin/gh"
        static let slug = GitHubSlug(host: "github.com", owner: "tester", name: "demo")
        static var fields: String { GHClient.jsonFields }

        static let auth = ["auth", "status", "--hostname", "github.com"]

        static var recent: [String] {
            ["pr", "list", "--repo", slug.ghRepoArgument, "--state", "all", "--limit", "100", "--json", fields]
        }

        // `--limit 20` since codex round 4, MAJOR 1: five was low enough that ordinary fork
        // traffic filled the page, and a full page was then read as "nobody has a PR here".
        static func head(_ branch: String) -> [String] {
            ["pr", "list", "--repo", slug.ghRepoArgument, "--state", "all", "--head", branch,
             "--limit", "\(GHClient.perHeadQueryLimit)", "--json", fields]
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
        runner.stubGit(Argv.identityCommonDir, stdout: "\(Argv.commonDirectory)\n")
        runner.stubGit(Argv.identityTopLevel, stdout: "\(Argv.repo)\n")
        runner.stubGit(Argv.remoteOriginURL, stdout: "https://github.com/tester/demo.git\n")
        runner.stubGit(Argv.branchRefs, stdout: Fixture.text("synthetic-for-each-ref-heads-mixed.txt"))
        runner.stubGit(Argv.remoteRefs, stdout: Fixture.text("synthetic-for-each-ref-remotes.txt"))
        runner.stubGit(Argv.worktrees, stdout: Fixture.text("synthetic-worktree-list-multi.txt"))
    }

    private static func stubGH(_ runner: RecordedCommandRunner, recent: String? = nil) {
        // codex round 2, MAJOR 6: the host allow-list read that decides whether a host other than
        // github.com is GitHub at all. github.com never needs it, so most tests never see it run.
        runner.stub(.init(executableName: "gh", arguments: ["auth", "status"],
                          result: .stdout(Fixture.text("recorded-gh-auth-status-github.com.txt"))))
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
        policy: RefreshPolicy = .default,
        wireRemoteLookup: Bool = false
    ) -> RepoLoader {
        let fs = fileSystem ?? Self.fileSystem()
        return RepoLoader(
            git: GitClient(runner: runner, gitPath: "/usr/bin/git", timeout: policy.gitTimeout),
            gh: gh ?? GHClient(runner: runner, ghPath: GH.path, policy: policy),
            reflog: ReflogFileReader(fileSystem: fs),
            // The loader stats `FETCH_HEAD` for the "last seen" anchor (codex MAJOR 7), so the
            // same in-memory filesystem the reflog reads through is handed to it directly.
            fileSystem: fs,
            policy: policy,
            // `config --get remote.<name>.url` for every remote other than origin (codex round 2,
            // MAJOR 4). Off by default here so the rest of this file keeps asserting the exact
            // command list it was written against.
            runner: wireRemoteLookup ? runner : nil,
            gitPath: wireRemoteLookup ? "/usr/bin/git" : nil)
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
            ["-C", brokenPath, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            ["-C", brokenPath, "rev-parse", "--path-format=absolute", "--show-toplevel"],
            ["-C", brokenPath, "config", "--get", "remote.origin.url"],
            ["-C", brokenPath, "for-each-ref", Argv.headsFormat, "--", "refs/heads"],
            ["-C", brokenPath, "for-each-ref", Argv.remotesFormat, "--", "refs/remotes/"],
            ["-C", brokenPath, "worktree", "list", "--porcelain", "-z"],
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
        // codex round 5, MAJOR 1: a cache entry answers for the repository it names, so a warm
        // entry carries the slug and the common directory this refresh will re-resolve.
        let cached = PRCacheEntry(
            fetchedAt: fetchedAt,
            prs: try PRListDecoder.decode(Fixture.data("synthetic-gh-pr-list-mixed.json")),
            authorPRs: [],
            repoID: Self.discovered.id,
            slug: GH.slug)

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
            cachedPRs: PRCacheEntry(
                fetchedAt: Self.now.addingTimeInterval(-599),
                repoID: Self.discovered.id,
                slug: GH.slug),
            now: Self.now)
        #expect(Self.ghCalls(fresh).isEmpty)

        let stale = RecordedCommandRunner()
        Self.stubGitStages(stale)
        Self.stubGH(stale)
        let repo = await Self.loader(stale, policy: policy).load(
            Self.discovered,
            wantsPullRequests: true,
            cachedPRs: PRCacheEntry(
                fetchedAt: Self.now.addingTimeInterval(-601),
                repoID: Self.discovered.id,
                slug: GH.slug),
            now: Self.now)
        #expect(!Self.ghCalls(stale).isEmpty, "past the TTL the repo is asked again")
        #expect(repo.prFetchedAt == Self.now, "and the answer is dated now")
    }

    // MARK: - Packet F18 — codex round 5, MAJOR 1: an entry answers for one repository

    /// codex round 5, MAJOR 1. `prCache` is keyed by `RepoID`, which is a path. Point the same
    /// checkout at a second GitHub repository — `git remote set-url origin`, or delete and
    /// recreate the repo at that path — and a fresh entry fetched for the first one answered for
    /// the second: its pills, and an "Open PR" link into another repository. A warm entry is used
    /// only when it names the slug this refresh just read.
    @Test("prCacheForAnotherSlugIsIgnored")
    func prCacheForAnotherSlugIsIgnored() async throws {
        let runner = RecordedCommandRunner()
        Self.stubGitStages(runner)
        Self.stubGH(runner)

        // Fetched 60 s ago — well inside the TTL — for `tester/other`, while origin now reads
        // `tester/demo`.
        let cached = PRCacheEntry(
            fetchedAt: Self.now.addingTimeInterval(-60),
            prs: try PRListDecoder.decode(Fixture.data("synthetic-gh-pr-list-mixed.json")),
            authorPRs: [],
            repoID: Self.discovered.id,
            slug: GitHubSlug(host: "github.com", owner: "tester", name: "other"))

        let result = await Self.loader(runner).loadReportingPRCache(
            Self.discovered, wantsPullRequests: true, cachedPRs: cached, now: Self.now)

        #expect(!Self.ghCalls(runner).isEmpty, "another repository's answer was served as this one's")
        #expect(result.repo.branches.allSatisfy { $0.pr == nil },
                "no branch may wear a PR fetched for a different repository")
        #expect(result.prCache?.slug == GH.slug, "the entry kept is the one this refresh fetched")
        #expect(result.prCache?.repoID == Self.discovered.id)
    }

    /// The other half of the key. The identity revalidation resolved the current common directory
    /// and then used the cached entry anyway, so a `.git` that moved — a checkout replaced under
    /// the same path — kept answering with the old repository's PRs.
    @Test("prCacheForAnotherCommonDirIsIgnored")
    func prCacheForAnotherCommonDirIsIgnored() async throws {
        let runner = RecordedCommandRunner()
        Self.stubGitStages(runner)
        Self.stubGH(runner)

        let cached = PRCacheEntry(
            fetchedAt: Self.now.addingTimeInterval(-60),
            prs: try PRListDecoder.decode(Fixture.data("synthetic-gh-pr-list-mixed.json")),
            authorPRs: [],
            repoID: RepoID(commonDir: "/Users/tester/somewhere-else/.git"),
            slug: GH.slug)

        let result = await Self.loader(runner).loadReportingPRCache(
            Self.discovered, wantsPullRequests: true, cachedPRs: cached, now: Self.now)

        #expect(!Self.ghCalls(runner).isEmpty,
                "an entry fetched for another checkout answered for this one")
        #expect(result.prCache?.repoID == Self.discovered.id,
                "and the entry written back names the directory `rev-parse` just re-resolved")
    }

    /// An entry written before either field existed records neither, and "no slug recorded" is not
    /// "the slug you have": it is refetched rather than believed.
    @Test("prCacheWithNoRecordedIdentityIsIgnored")
    func prCacheWithNoRecordedIdentityIsIgnored() async throws {
        let runner = RecordedCommandRunner()
        Self.stubGitStages(runner)
        Self.stubGH(runner)

        let cached = PRCacheEntry(fetchedAt: Self.now.addingTimeInterval(-60))
        _ = await Self.loader(runner).load(
            Self.discovered, wantsPullRequests: true, cachedPRs: cached, now: Self.now)

        #expect(!Self.ghCalls(runner).isEmpty)
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

    // MARK: - Owner-keyed query coverage and host classification — codex round 2, MAJOR 4 and 6

    /// codex round 2, MAJOR 4. The recent-100 list answers for the heads **it** names, and a head
    /// name alone is not a head: `stranger:main` and `tester:main` are two different heads that
    /// share a name. Marking `main` queried because a stranger's PR mentioned it skipped the
    /// per-head query for the user's own `main`, the stranger's PR was then correctly rejected as
    /// a match, and the row read "No PR" beside an open one.
    @Test("strangersRecentSameNamedPRDoesNotSuppressThePerHeadQuery")
    func strangersRecentSameNamedPRDoesNotSuppressThePerHeadQuery() async throws {
        let strangerMain = """
        [
          {
            "baseRefName": "main",
            "headRefName": "main",
            "headRefOid": "5555555555555555555555555555555555555555",
            "headRepositoryOwner": { "id": "U_s", "name": "A Stranger", "login": "stranger" },
            "isDraft": false,
            "mergeCommit": null,
            "mergedAt": null,
            "number": 900,
            "reviewDecision": "",
            "state": "OPEN",
            "updatedAt": "2026-08-30T10:00:00Z",
            "url": "https://github.com/tester/demo/pull/900"
          }
        ]
        """
        let ownMain = """
        [
          {
            "baseRefName": "release",
            "headRefName": "main",
            "headRefOid": "7777777777777777777777777777777777777777",
            "headRepositoryOwner": { "id": "U_t", "name": "Tester Person", "login": "tester" },
            "isDraft": false,
            "mergeCommit": null,
            "mergedAt": null,
            "number": 901,
            "reviewDecision": "APPROVED",
            "state": "OPEN",
            "updatedAt": "2026-08-20T10:00:00Z",
            "url": "https://github.com/tester/demo/pull/901"
          }
        ]
        """

        let runner = RecordedCommandRunner()
        Self.stubGitStages(runner)
        // Registered before the batch stubs so the first match wins for `--head main`.
        runner.stub(.init(executableName: "gh", arguments: GH.head("main"), result: .stdout(ownMain)))
        Self.stubGH(runner, recent: strangerMain)

        let repo = await Self.loader(runner).load(
            Self.discovered, wantsPullRequests: true, cachedPRs: nil, now: Self.now)

        #expect(Self.ghCalls(runner).map(\.arguments).contains(GH.head("main")),
                "tester:main was never asked about, so the per-head query still owes an answer")

        let main = try #require(Self.branch(repo, "main"))
        #expect(main.pr?.number == 901, "the user's own PR, found by the per-head query")
        #expect(main.prStatus == .approved)
    }

    /// codex round 2, MAJOR 4. A branch tracking a fork has its head on the fork, and the only
    /// place that owner is written down is `remote.<name>.url`. Reading it is what stops the
    /// branch from being matched against the origin repository's owner — a different head that
    /// happens to share a name — and what lets the fork's own PR reach the row.
    ///
    /// New invocation, PLAN.md §5: `git -C <repo> config --get remote.<name>.url`, once per
    /// distinct upstream remote name that is not `origin`.
    @Test("perRemoteUpstreamOwnerIsResolvedFromThatRemotesURL")
    func perRemoteUpstreamOwnerIsResolvedFromThatRemotesURL() async throws {
        let unit = "\u{1f}"
        let heads = [
            "refs/heads/fork-feature", String(repeating: "d", count: 40), "1788300000",
            "fork/fork-feature", "fork", "", "*",
        ].joined(separator: unit) + "\n"
        let remotes = [
            "refs/remotes/fork/fork-feature", String(repeating: "d", count: 40), "1788300000",
        ].joined(separator: unit) + "\n"
        let forkURL = ["-C", Argv.repo, "config", "--get", "remote.fork.url"]

        let runner = RecordedCommandRunner()
        runner.stubGit(Argv.branchRefs, stdout: heads)
        runner.stubGit(Argv.remoteRefs, stdout: remotes)
        runner.stubGit(forkURL, stdout: "https://github.com/contributor/demo.git\n")
        Self.stubGitStages(runner)
        Self.stubGH(runner, recent: Fixture.text("synthetic-gh-pr-list-mixed.json"))

        let repo = await Self.loader(runner, wireRemoteLookup: true).load(
            Self.discovered, wantsPullRequests: true, cachedPRs: nil, now: Self.now)

        #expect(runner.calls(matchingExecutable: "git").map(\.arguments).contains(forkURL),
                "the fork's own remote URL is the only place its owner is written down")
        #expect(repo.errors.isEmpty)

        let branch = try #require(Self.branch(repo, "fork-feature"))
        #expect(branch.pr?.number == 110, "PR 110's head is contributor:fork-feature, which is this branch")
        #expect(branch.prStatus == .open)
        #expect(branch.push.remoteName == "fork")

        // One lookup per distinct remote name, however many branches track it, and never for
        // origin — stage 2 already read that one.
        #expect(runner.calls(matchingExecutable: "git")
            .filter { $0.arguments.contains("remote.fork.url") }.count == 1)
        #expect(!runner.calls(matchingExecutable: "git")
            .contains { $0.arguments.contains("remote.origin.url") && $0.arguments != Argv.remoteOriginURL })
    }

    /// codex round 2, MAJOR 6. A GitLab remote is a syntactically valid hostname, which is all the
    /// slug parser ever asked for, so the repo was preflighted with `gh auth status --hostname
    /// gitlab.com` and the UI offered `gh auth login --hostname gitlab.com`. That is a
    /// network-target and phishing path, and the honest answer is the one a `file://` remote gets.
    @Test("gitlabRemoteIsNotOfferedForGhSignIn")
    func gitlabRemoteIsNotOfferedForGhSignIn() async throws {
        let runner = RecordedCommandRunner()
        runner.stubGit(Argv.remoteOriginURL, stdout: "git@gitlab.com:team/tools.git\n")
        Self.stubGitStages(runner)
        Self.stubGH(runner)

        let repo = await Self.loader(runner).load(
            Self.discovered, wantsPullRequests: true, cachedPRs: nil, now: Self.now)

        if case .unavailable(let reason, _) = repo.prAvailability {
            #expect(reason == .notGitHubRemote)
            if case .ghNotAuthenticated = reason {
                Issue.record("a GitLab remote was offered as a GitHub sign-in target")
            }
        } else {
            Issue.record("expected notGitHubRemote, got \(repo.prAvailability)")
        }
        #expect(!Self.ghCalls(runner).contains { $0.arguments.contains("gitlab.com") },
                "no gh process may be pointed at a host the repo named and gh has never heard of")
    }

    // MARK: - Push history without tracking configuration — codex MAJOR 6

    /// `git push origin <branch>` without `-u` writes a real reflog line and leaves no upstream
    /// behind, and so does removing an upstream after a push. The loader used to skip the reflog
    /// for such a branch entirely and render "Never pushed", which the absence of tracking never
    /// proved. It now reads `origin/<branch>` whenever `for-each-ref -- refs/remotes/` listed it.
    @Test("branchWithoutUpstreamButMatchingRemoteRefReadsItsReflog")
    func branchWithoutUpstreamButMatchingRemoteRefReadsItsReflog() async throws {
        let runner = RecordedCommandRunner()
        // The shared remotes fixture has no `origin/no-upstream`; this one adds it, which is the
        // shape a `git push origin no-upstream` without `-u` leaves behind. Registered before
        // `stubGitStages`, since the first matching stub wins.
        runner.stub(.init(
            executableName: "git", arguments: Argv.remoteRefs,
            result: .stdout(Fixture.text("synthetic-for-each-ref-remotes.txt")
                + "refs/remotes/origin/no-upstream\u{1F}"
                + "cccccccccccccccccccccccccccccccccccccccc\u{1F}1787900000\n")))
        Self.stubGitStages(runner)

        // The heads fixture's `no-upstream` row has an empty `upstream:short`.
        let fs = Self.fileSystem()
        fs.addFile(
            ReflogFileReader.reflogPath(
                commonDirectory: Argv.commonDirectory, remote: "origin", branch: "no-upstream"),
            contents: Fixture.text("synthetic-reflog-push-and-fetch.txt"))

        let repo = await Self.loader(runner, fileSystem: fs).load(
            Self.discovered, wantsPullRequests: false, cachedPRs: nil, now: Self.now)

        let branch = try #require(Self.branch(repo, "no-upstream"))
        #expect(branch.upstream == nil, "it still tracks nothing")
        #expect(branch.push.source == .reflogObserved, "and it was still pushed from this Mac")
        #expect(branch.push.observedPushAt == Date(timeIntervalSince1970: 1_788_200_000))
        #expect(branch.push.hasUpstream == false)
        #expect(branch.push.aheadOfLastKnownRemote == nil, "nothing to be ahead of")
        #expect(repo.errors.isEmpty)
    }

    /// The other half: no upstream and no `origin/<branch>` either. There is nothing to read, so
    /// the row says BranchBar has not checked rather than claiming the branch never went out.
    @Test("branchWithoutUpstreamOrRemoteRefSaysHistoryNotChecked")
    func branchWithoutUpstreamOrRemoteRefSaysHistoryNotChecked() async throws {
        let runner = RecordedCommandRunner()
        // No remote-tracking refs at all, so `origin/no-upstream` is not a candidate.
        runner.stub(.init(executableName: "git", arguments: Argv.remoteRefs, result: .stdout("")))
        Self.stubGitStages(runner)

        let repo = await Self.loader(runner).load(
            Self.discovered, wantsPullRequests: false, cachedPRs: nil, now: Self.now)

        let branch = try #require(Self.branch(repo, "no-upstream"))
        #expect(branch.push.source == .none)
        #expect(branch.push.hasUpstream == false)

        let vm = SnapshotPresenter().present(
            Snapshot(repos: [repo], refreshedAt: Self.now, tools: ToolStatus(gitPath: "/usr/bin/git")),
            refreshState: .idle(lastRefreshedAt: Self.now),
            collapsedRepoIDs: [],
            scanResult: nil,
            appVersion: uiAppVersion,
            now: Self.now
        )
        let row = try #require(vm.sections.first?.active.first { $0.title == "no-upstream" })
        #expect(row.pushLabel == Strings.noTrackedRemoteBranch)
        #expect(row.pushTooltip == Strings.noTrackedRemoteBranchTooltip)
        #expect(row.pushLabel != "Never pushed", "the app cannot see what other machines pushed")
    }

    // MARK: - FETCH_HEAD is the "last seen" anchor — codex MAJOR 7

    /// `FETCH_HEAD` is rewritten by every fetch and by nothing else, so its modification date is
    /// something this Mac did. The remote tip's committer date, which used to fill this field, is
    /// a fact about a commit and could predate the fetch by years.
    @Test("loaderReadsFetchHeadModificationDateAsTheLastSeenAnchor")
    func loaderReadsFetchHeadModificationDateAsTheLastSeenAnchor() async throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_788_390_000)
        let runner = RecordedCommandRunner()
        Self.stubGitStages(runner)

        let fs = Self.fileSystem()
        fs.addFile(
            (Argv.commonDirectory as NSString).appendingPathComponent("FETCH_HEAD"),
            contents: "deadbeef\t\tbranch 'main' of github.com:tester/demo\n",
            modified: fetchedAt)

        let repo = await Self.loader(runner, fileSystem: fs).load(
            Self.discovered, wantsPullRequests: false, cachedPRs: nil, now: Self.now)

        let main = try #require(Self.branch(repo, "main"))
        #expect(main.push.remoteRefObservedAt == fetchedAt)
        #expect(main.push.remoteTipCommitDate != nil, "the tip's commit date travels separately")
        #expect(main.push.remoteRefObservedAt != main.push.remoteTipCommitDate)

        // A clone that has only ever been pushed from has no FETCH_HEAD, and that is not an error.
        let withoutFetchHead = await Self.loader(runner).load(
            Self.discovered, wantsPullRequests: false, cachedPRs: nil, now: Self.now)
        #expect(Self.branch(withoutFetchHead, "main")?.push.remoteRefObservedAt == nil)
        #expect(withoutFetchHead.errors.isEmpty, "an absent FETCH_HEAD is an answer, not a failure")
    }

    // MARK: - Unknown worktrees are not "no worktrees" — codex MAJOR 12

    /// The loader half of `worktreeEnumerationFailureSuppressesMergedGroup`: the failed stage is
    /// recorded, and the assembler is told the list is unknown rather than empty.
    @Test("worktreeStageFailureIsRecordedAndSuppressesTheMergedGroup")
    func worktreeStageFailureIsRecordedAndSuppressesTheMergedGroup() async throws {
        let merged = try PRListDecoder.decode(Fixture.data("synthetic-gh-pr-list-mixed.json"))
            .first { $0.number == 106 }
        let mergedPR = try #require(merged)

        func load(worktreesFail: Bool) async -> Repo {
            let runner = RecordedCommandRunner()
            if worktreesFail {
                runner.stub(.init(executableName: "git", arguments: Argv.worktrees,
                                  result: .exit(128, stderr: "fatal: not a git repository")))
            }
            // Registered before `stubGitStages`: the first matching stub wins. `shipped`'s tip is
            // the merged PR's head, and no worktree in the fixture holds it.
            runner.stub(.init(
                executableName: "git", arguments: Argv.branchRefs,
                result: .stdout("refs/heads/shipped\u{1F}\(mergedPR.headRefOid)\u{1F}1788310842"
                    + "\u{1F}origin/shipped\u{1F}origin\u{1F}\u{1F}*\n")))
            Self.stubGitStages(runner)
            let cached = PRCacheEntry(
                fetchedAt: Self.now, prs: [mergedPR], authorPRs: [], queriedHeads: ["shipped"],
                // codex round 5, MAJOR 1: the repository this answer was fetched for.
                repoID: Self.discovered.id, slug: GH.slug)
            return await Self.loader(runner).load(
                Self.discovered, wantsPullRequests: true, cachedPRs: cached, now: Self.now)
        }

        let ok = await load(worktreesFail: false)
        #expect(Self.branch(ok, "shipped")?.group == .merged, "the baseline: worktrees were listed")

        let failed = await load(worktreesFail: true)
        #expect(failed.worktrees.isEmpty)
        #expect(failed.errors.map(\.stage).contains(.worktrees), "the stage says it failed")
        #expect(Self.branch(failed, "shipped")?.prStatus == .merged)
        #expect(Self.branch(failed, "shipped")?.group == .active,
                "unknown worktrees may not be read as no worktrees")
    }
}

// MARK: - Packet F13 — codex round 3, BLOCKER 1, BLOCKER 2, MAJOR 6

/// The loader half of the round-3 findings: it is the only place that can decide whether a
/// worktree path or the repo's own folder is a folder at all, whether `FETCH_HEAD` is a regular
/// file, and whether a remote read answered or failed.
@Suite("RepoLoader establishes what it reports, and reports nothing else")
struct RepoLoaderRoundThreeTests {

    private enum Argv {
        static let repo = "/Users/tester/monorepo"
        static let commonDirectory = "/Users/tester/monorepo/.git"
        static let headsFormat =
            "--format=%(refname)%1f%(objectname)%1f%(committerdate:unix)%1f%(upstream:short)%1f%(upstream:remotename)%1f%(upstream:track,nobracket)%1f%(HEAD)"
        static let remotesFormat = "--format=%(refname)%1f%(objectname)%1f%(committerdate:unix)"
        static let identityCommonDir = ["-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"]
        static let identityTopLevel = ["-C", repo, "rev-parse", "--path-format=absolute", "--show-toplevel"]
        static let remoteOriginURL = ["-C", repo, "config", "--get", "remote.origin.url"]
        static let branchRefs = ["-C", repo, "for-each-ref", headsFormat, "--", "refs/heads"]
        static let remoteRefs = ["-C", repo, "for-each-ref", remotesFormat, "--", "refs/remotes/"]
        static let worktrees = ["-C", repo, "worktree", "list", "--porcelain", "-z"]
    }

    private static let discovered = DiscoveredRepo(
        path: Argv.repo, id: RepoID(commonDir: Argv.commonDirectory))
    private static let now = Date(timeIntervalSince1970: 1_788_400_000)

    /// `git worktree list --porcelain -z`: every line is NUL-terminated and every record carries
    /// one more NUL.
    private static func porcelain(_ records: [[String]]) -> String {
        records.map { $0.map { "\($0)\0" }.joined() + "\0" }.joined()
    }

    private static func stubGit(
        _ runner: RecordedCommandRunner,
        worktrees: String,
        heads: String = "refs/heads/main\u{1f}1111111111111111111111111111111111111111\u{1f}1788300000\u{1f}origin/main\u{1f}origin\u{1f}\u{1f}*\n"
    ) {
        runner.stubGit(Argv.identityCommonDir, stdout: "\(Argv.commonDirectory)\n")
        runner.stubGit(Argv.identityTopLevel, stdout: "\(Argv.repo)\n")
        runner.stubGit(Argv.remoteOriginURL, stdout: "https://github.com/tester/demo.git\n")
        runner.stubGit(Argv.branchRefs, stdout: heads)
        runner.stubGit(Argv.remoteRefs, stdout: "")
        runner.stubGit(Argv.worktrees, stdout: worktrees)
    }

    private static func loader(_ runner: RecordedCommandRunner, fileSystem: FileSystem) -> RepoLoader {
        RepoLoader(
            git: GitClient(runner: runner, gitPath: "/usr/bin/git"),
            gh: nil,
            reflog: ReflogFileReader(fileSystem: fileSystem),
            fileSystem: fileSystem)
    }

    /// codex round 3, BLOCKER 1, and the exact shape the finding describes: a `.git/worktrees`
    /// record naming `/tmp/payload.command`. Terminal executes a `.command` document, and Terminal
    /// is the last editor in the row's fallback chain.
    @Test("worktreePathThatIsARegularFileGetsNoRowAction")
    func worktreePathThatIsARegularFileGetsNoRowAction() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addDirectory(Argv.repo)
        fs.addFile("/tmp/payload.command", contents: "#!/bin/sh\ntouch /tmp/pwned\n")

        let runner = RecordedCommandRunner()
        Self.stubGit(runner, worktrees: Self.porcelain([
            ["worktree \(Argv.repo)", "HEAD 1111111111111111111111111111111111111111", "branch refs/heads/main"],
            ["worktree /tmp/payload.command", "HEAD 2222222222222222222222222222222222222222", "detached"],
        ]))

        let repo = await Self.loader(runner, fileSystem: fs).load(
            Self.discovered, wantsPullRequests: false, cachedPRs: nil, now: Self.now)

        let payload = try #require(repo.worktrees.first { $0.path == "/tmp/payload.command" })
        #expect(payload.isPrunable, "a path that will not open as a directory was accepted verbatim")
        #expect(repo.pathIsDirectory, "the repo's own folder really is one")

        let section = try #require(SnapshotPresenter().present(
            Snapshot(repos: [repo], refreshedAt: Self.now),
            refreshState: .idle(lastRefreshedAt: Self.now),
            collapsedRepoIDs: [],
            scanResult: nil,
            appVersion: "0.9.0",
            now: Self.now).sections.first)

        let row = try #require(section.active.first { $0.title == "payload.command" })
        #expect(row.primaryAction == nil,
                "clicking this row handed a .command file to Terminal: \(String(describing: row.primaryAction))")
    }

    /// The same rule applied to a record that claims a branch: the branch keeps its row and stops
    /// claiming a worktree nobody can open.
    @Test("aBranchNeverClaimsAWorktreeWhosePathIsNotADirectory")
    func branchNeverClaimsAnUnopenableWorktree() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addDirectory(Argv.repo)
        fs.addFile("/tmp/payload.command", contents: "")

        let runner = RecordedCommandRunner()
        Self.stubGit(
            runner,
            worktrees: Self.porcelain([
                ["worktree \(Argv.repo)", "HEAD 1111111111111111111111111111111111111111", "branch refs/heads/main"],
                ["worktree /tmp/payload.command", "HEAD 2222222222222222222222222222222222222222",
                 "branch refs/heads/spike"],
            ]),
            heads: "refs/heads/main\u{1f}1111111111111111111111111111111111111111\u{1f}1788300000\u{1f}origin/main\u{1f}origin\u{1f}\u{1f}*\n"
                + "refs/heads/spike\u{1f}2222222222222222222222222222222222222222\u{1f}1788300000\u{1f}\u{1f}\u{1f}\u{1f}\n")

        let repo = await Self.loader(runner, fileSystem: fs).load(
            Self.discovered, wantsPullRequests: false, cachedPRs: nil, now: Self.now)

        let spike = try #require(repo.branches.first { $0.name == "spike" })
        #expect(spike.worktreePath == nil, "a branch claimed a worktree at a path that is not a folder")
    }

    /// codex round 3, BLOCKER 2. `FETCH_HEAD`'s date used to come from a URL resource-value read,
    /// which follows a symlink and blocks in `open()` on a named pipe — on the repo-loading path,
    /// outside the killable helper. This runs against the real filesystem because the bug is in
    /// the syscalls, not in the seam.
    @Test("fifoFetchHeadDoesNotBlockAndYieldsNoObservation")
    func fifoFetchHeadDoesNotBlockAndYieldsNoObservation() async throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }

        let repoPath = temp.url.appendingPathComponent("monorepo").path
        let commonDirectory = repoPath + "/.git"
        try FileManager.default.createDirectory(atPath: commonDirectory, withIntermediateDirectories: true)
        let fetchHead = commonDirectory + "/FETCH_HEAD"
        #expect(mkfifo(fetchHead, 0o600) == 0, "mkfifo failed: \(String(cString: strerror(errno)))")

        let runner = RecordedCommandRunner()
        runner.stubGit(["-C", repoPath, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                       stdout: "\(commonDirectory)\n")
        runner.stubGit(["-C", repoPath, "rev-parse", "--path-format=absolute", "--show-toplevel"],
                       stdout: "\(repoPath)\n")
        runner.stubGit(["-C", repoPath, "config", "--get", "remote.origin.url"],
                       stdout: "https://github.com/tester/demo.git\n")
        runner.stubGit(["-C", repoPath, "for-each-ref", Argv.headsFormat, "--", "refs/heads"], stdout: "")
        runner.stubGit(["-C", repoPath, "for-each-ref", Argv.remotesFormat, "--", "refs/remotes/"], stdout: "")
        runner.stubGit(["-C", repoPath, "worktree", "list", "--porcelain", "-z"], stdout: "")

        let started = Date()
        let repo = await Self.loader(runner, fileSystem: RealFileSystem()).load(
            DiscoveredRepo(path: repoPath, id: RepoID(commonDir: commonDirectory)),
            wantsPullRequests: false, cachedPRs: nil, now: Self.now)

        #expect(Date().timeIntervalSince(started) < 10, "the refresh blocked reading a FIFO FETCH_HEAD")
        #expect(repo.branches.isEmpty)
        #expect(repo.pathIsDirectory)
    }

    /// codex round 3, MAJOR 6. `git config --get remote.origin.url` exiting non-zero and the key
    /// being unset both left `remoteURL == nil`, and "No origin for this repo" is a claim only the
    /// second of the two supports.
    @Test("failedRemoteURLQueryDoesNotClaimNoOrigin")
    func failedRemoteURLQueryDoesNotClaimNoOrigin() async throws {
        func availability(originURL: RecordedCommandRunner.StubResult) async -> Repo {
            let fs = InMemoryFileSystem(home: "/Users/tester")
            fs.addDirectory(Argv.repo)
            let runner = RecordedCommandRunner()
            runner.stub(.init(executableName: "git", arguments: Argv.remoteOriginURL, result: originURL))
            Self.stubGit(runner, worktrees: "")
            let loader = RepoLoader(
                git: GitClient(runner: runner, gitPath: "/usr/bin/git"),
                gh: GHClient(runner: runner, ghPath: "/opt/homebrew/bin/gh"),
                reflog: ReflogFileReader(fileSystem: fs),
                fileSystem: fs)
            return await loader.load(
                Self.discovered, wantsPullRequests: true, cachedPRs: nil, now: Self.now)
        }

        // Exit 128 is a failure: the read did not happen, so nothing is known about origin.
        let failed = await availability(originURL: .exit(128, stderr: "fatal: not a git repository"))
        #expect(failed.remoteURL == nil)
        #expect(failed.prAvailability == .available,
                "a failed read of origin was reported as a fact about origin: \(failed.prAvailability)")
        #expect(failed.errors.map(\.stage).contains(.remotes), "and the stage that failed is named")
        #expect(try #require(failed.branches.first).prStatus == .notChecked,
                "no head was queried, so `none` is not reachable")

        // Exit 1 with no output is git saying the key is unset, which really is no origin.
        let unset = await availability(originURL: .exit(1))
        #expect(unset.prAvailability == .unavailable(.noRemote, detail: nil))
    }

    /// codex round 3, MAJOR 6, the second read. A failed `for-each-ref -- refs/remotes/` produces
    /// no tip for a reason that says nothing about the branch, and the row used to render "No
    /// tracked remote branch" over a tertiary line claiming it was in sync with that same remote.
    @Test("failedRemoteRefListingDoesNotClaimInSyncOrNoTrackedBranch")
    func failedRemoteRefListingDoesNotClaimInSyncOrNoTrackedBranch() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addDirectory(Argv.repo)
        let runner = RecordedCommandRunner()
        runner.stub(.init(executableName: "git", arguments: Argv.remoteRefs,
                          result: .exit(128, stderr: "fatal: bad object")))
        Self.stubGit(runner, worktrees: "")

        let repo = await Self.loader(runner, fileSystem: fs).load(
            Self.discovered, wantsPullRequests: false, cachedPRs: nil, now: Self.now)

        let main = try #require(repo.branches.first { $0.name == "main" })
        #expect(!main.push.remoteRefsKnown, "a failed listing was recorded as an answered one")
        #expect(repo.errors.map(\.stage).contains(.remotes))

        let row = try #require(SnapshotPresenter().present(
            Snapshot(repos: [repo], refreshedAt: Self.now),
            refreshState: .idle(lastRefreshedAt: Self.now),
            collapsedRepoIDs: [],
            scanResult: nil,
            appVersion: "0.9.0",
            now: Self.now).sections.first?.active.first)

        // codex round 5, MAJOR 3 sharpened this line. The remote listing failed, and separately
        // this branch's record of pushes was read and held nothing — which is a fact about this
        // Mac, not about the listing, and is what the row now says. Both prohibitions stand: it
        // still may not claim there is no tracked remote branch and may not claim it is in sync.
        #expect(row.pushLabel == Strings.noPushRecorded(
            remoteRef: "origin/main", remoteTipCommitDate: nil, now: Self.now))
        #expect(!row.pushLabel.contains("No tracked remote branch"))
        #expect(row.aheadLabel?.contains("In sync") != true, "\(row.aheadLabel ?? "nil")")
    }

    // MARK: - Packet F18 — codex round 5, MAJOR 3: what the read did travels with the row

    /// codex round 5, MAJOR 3. `git push origin feature` without `-u` leaves no tracking
    /// configuration and a real `origin/feature`, so the loader reads that ref's record of pushes.
    /// When it holds nothing the row used to read "No tracked remote branch · push history not
    /// checked", under a tooltip saying BranchBar only reads push history for tracking branches —
    /// about a file this loop had just opened.
    @Test("checkedOriginBranchWithNoObservationDoesNotSayNotChecked")
    func checkedOriginBranchWithNoObservationDoesNotSayNotChecked() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addDirectory(Argv.repo)
        // No reflog file for `origin/feature`: read, and nothing in it.
        let runner = RecordedCommandRunner()
        runner.stubGit(
            Argv.remoteRefs,
            stdout: "refs/remotes/origin/feature\u{1f}2222222222222222222222222222222222222222\u{1f}1788200000\n")
        Self.stubGit(
            runner,
            worktrees: "",
            heads: "refs/heads/feature\u{1f}1111111111111111111111111111111111111111\u{1f}1788300000\u{1f}\u{1f}\u{1f}\u{1f}*\n")

        let repo = await Self.loader(runner, fileSystem: fs).load(
            Self.discovered, wantsPullRequests: false, cachedPRs: nil, now: Self.now)

        let branch = try #require(repo.branches.first { $0.name == "feature" })
        #expect(branch.upstream == nil, "the branch tracks nothing")
        #expect(branch.push.source == .checkedNoObservation,
                "the record was read and held nothing, which is not `none`")

        let row = try #require(SnapshotPresenter().present(
            Snapshot(repos: [repo], refreshedAt: Self.now),
            refreshState: .idle(lastRefreshedAt: Self.now),
            collapsedRepoIDs: [],
            scanResult: nil,
            appVersion: "0.9.0",
            now: Self.now).sections.first?.active.first)

        #expect(row.pushLabel.contains("No push from this Mac recorded for origin/feature"),
                "\(row.pushLabel)")
        #expect(!row.pushLabel.lowercased().contains("not checked"), "\(row.pushLabel)")
        #expect(!row.pushTooltip.contains(Strings.noTrackedRemoteBranchTooltip),
                "the tooltip claimed BranchBar had not checked a file it read: \(row.pushTooltip)")
        // The remote tip's commit date may ride along, and only as a commit date.
        #expect(!row.pushLabel.contains("Pushed from this Mac"), "\(row.pushLabel)")
    }

    /// The same finding on a gone upstream: the ref is missing, so there is no tip date to fall
    /// back to, and the row collapsed to the same "not checked" sentence about a record that had
    /// been read.
    @Test("goneUpstreamWordingDoesNotClaimNotChecked")
    func goneUpstreamWordingDoesNotClaimNotChecked() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addDirectory(Argv.repo)
        let runner = RecordedCommandRunner()
        Self.stubGit(
            runner,
            worktrees: "",
            heads: "refs/heads/feature\u{1f}1111111111111111111111111111111111111111\u{1f}1788300000"
                + "\u{1f}origin/feature\u{1f}origin\u{1f}gone\u{1f}*\n")

        let repo = await Self.loader(runner, fileSystem: fs).load(
            Self.discovered, wantsPullRequests: false, cachedPRs: nil, now: Self.now)

        let branch = try #require(repo.branches.first { $0.name == "feature" })
        #expect(branch.push.upstreamGone)
        #expect(branch.push.source == .checkedNoObservation)

        let row = try #require(SnapshotPresenter().present(
            Snapshot(repos: [repo], refreshedAt: Self.now),
            refreshState: .idle(lastRefreshedAt: Self.now),
            collapsedRepoIDs: [],
            scanResult: nil,
            appVersion: "0.9.0",
            now: Self.now).sections.first?.active.first)

        #expect(row.pushLabel == Strings.noPushRecorded(
            remoteRef: "origin/feature", remoteTipCommitDate: nil, now: Self.now))
        #expect(!row.pushLabel.lowercased().contains("not checked"), "\(row.pushLabel)")
        #expect(row.aheadLabel?.contains(Strings.upstreamMissing) == true,
                "the tertiary line still says the upstream is missing: \(row.aheadLabel ?? "nil")")
    }
}

// MARK: - Packet F15 — codex round 4, BLOCKER 3 (the cheap half) and MAJOR 1

/// BLOCKER 3: "The claimed 'nonblocking FD reads' remain blockable through pathname resolution."
/// `O_NONBLOCK` makes the **open** return for a FIFO; it does nothing for VFS pathname lookup, so
/// a repo sitting on a disconnected network mount blocks the reflog and `FETCH_HEAD` reads
/// uninterruptibly — in the app's own process, outside the killable scan helper.
///
/// The bound this packet can honestly draw is at the volume: a repo under `/Volumes` whose volume
/// root will not answer `statfs`, or answers with a network filesystem type, is loaded from git
/// command output alone. Those run in a child the deadline can kill; a direct `open()` does not.
@Suite("A repo on a volume that cannot be trusted to answer is read through git only")
struct RepoOnUntrustedVolumeTests {

    private enum Argv {
        static let repo = "/Volumes/nas/monorepo"
        static let commonDirectory = "/Volumes/nas/monorepo/.git"

        static let headsFormat =
            "--format=%(refname)%1f%(objectname)%1f%(committerdate:unix)%1f%(upstream:short)%1f%(upstream:remotename)%1f%(upstream:track,nobracket)%1f%(HEAD)"
        static let remotesFormat = "--format=%(refname)%1f%(objectname)%1f%(committerdate:unix)"

        static let identityCommonDir = ["-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"]
        static let identityTopLevel = ["-C", repo, "rev-parse", "--path-format=absolute", "--show-toplevel"]
        static let remoteOriginURL = ["-C", repo, "config", "--get", "remote.origin.url"]
        static let branchRefs = ["-C", repo, "for-each-ref", headsFormat, "--", "refs/heads"]
        static let remoteRefs = ["-C", repo, "for-each-ref", remotesFormat, "--", "refs/remotes/"]
        static let worktrees = ["-C", repo, "worktree", "list", "--porcelain", "-z"]
    }

    private static func runner() -> RecordedCommandRunner {
        let runner = RecordedCommandRunner()
        runner.stubGit(Argv.identityCommonDir, stdout: "\(Argv.commonDirectory)\n")
        runner.stubGit(Argv.identityTopLevel, stdout: "\(Argv.repo)\n")
        runner.stubGit(Argv.remoteOriginURL, stdout: "https://github.com/tester/demo.git\n")
        runner.stubGit(Argv.branchRefs, stdout: Fixture.text("synthetic-for-each-ref-heads-mixed.txt"))
        runner.stubGit(Argv.remoteRefs, stdout: Fixture.text("synthetic-for-each-ref-remotes.txt"))
        runner.stubGit(Argv.worktrees, stdout: Fixture.text("synthetic-worktree-list-multi.txt"))
        return runner
    }

    /// A reflog that would answer, on a volume nobody should be opening files on.
    private static func fileSystem(volume: VolumeKind) -> InMemoryFileSystem {
        let fs = InMemoryFileSystem()
        fs.addFile(
            ReflogFileReader.reflogPath(
                commonDirectory: Argv.commonDirectory, remote: "origin", branch: "main"),
            contents: Fixture.text("synthetic-reflog-push-and-fetch.txt"))
        fs.addFile("\(Argv.commonDirectory)/FETCH_HEAD", contents: "")
        fs.setVolumeKind(volume, for: "/Volumes/nas")
        return fs
    }

    private static func loader(_ runner: RecordedCommandRunner, _ fs: InMemoryFileSystem) -> RepoLoader {
        RepoLoader(
            git: GitClient(runner: runner, gitPath: "/usr/bin/git"),
            gh: nil,
            reflog: ReflogFileReader(fileSystem: fs),
            fileSystem: fs)
    }

    @Test("repoOnANetworkVolumeSkipsDirectFileReads")
    func repoOnANetworkVolumeSkipsDirectFileReads() async throws {
        let runner = Self.runner()
        let fs = Self.fileSystem(volume: .network(type: "smbfs"))

        let repo = await Self.loader(runner, fs).load(
            DiscoveredRepo(path: Argv.repo, id: RepoID(commonDir: Argv.commonDirectory)),
            wantsPullRequests: false,
            cachedPRs: nil,
            now: Date(timeIntervalSince1970: 1_788_400_000))

        // git still ran: its output arrives through a child process the deadline can kill.
        #expect(repo.branches.count == 7, "the branch list comes from git, and git still ran")
        #expect(repo.remoteURL == "https://github.com/tester/demo.git")

        #expect(fs.statRegularFileCallCount == 0,
                "the loader opened \(fs.statRegularFileCallCount) descriptors on a volume whose server may never answer")
        #expect(fs.readFileCallCount == 0)

        // The reflog would have said "pushed"; without it the row falls back rather than lying,
        // and the skipped stage is reported against `.reflog` so the row can say why.
        let main = try #require(repo.branches.first { $0.name == "main" })
        #expect(main.push.source != .reflogObserved)
        let reflogErrors = repo.errors.filter { $0.stage == .reflog }
        #expect(reflogErrors.count == 1, "the skip is recorded, not silent: \(repo.errors)")
        #expect(reflogErrors.first?.message.contains("/Volumes/nas") == true)
        #expect(reflogErrors.first?.message.contains("smbfs") == true)
    }

    /// A mount point that will not describe itself has already stopped answering; that is the
    /// same skip, arrived at through `statfs` failing rather than through a filesystem type.
    // MARK: - Packet F18 — codex round 5, MAJOR 4

    /// codex round 5, MAJOR 4. F15 refuses the `FETCH_HEAD` read on a network volume on purpose,
    /// and the refusal arrived at the presenter as the same `nil` an absent file produces — so an
    /// ahead branch on a company file share told the user "This repo has not fetched yet" about a
    /// repo that fetches every day. Only an open that answered `ENOENT` may say that.
    @Test("refusedFetchHeadReadIsNotReportedAsNeverFetched")
    func refusedFetchHeadReadIsNotReportedAsNeverFetched() async throws {
        let runner = Self.runner()
        let fs = Self.fileSystem(volume: .network(type: "smbfs"))
        let now = Date(timeIntervalSince1970: 1_788_400_000)

        let repo = await Self.loader(runner, fs).load(
            DiscoveredRepo(path: Argv.repo, id: RepoID(commonDir: Argv.commonDirectory)),
            wantsPullRequests: false,
            cachedPRs: nil,
            now: now)

        let ahead = try #require(repo.branches.first { $0.name == "ahead-two" })
        #expect(ahead.push.fetchHead == .unavailable,
                "a read this app refused to make was recorded as an absent file")
        #expect(ahead.push.source == .unavailable,
                "and the same refusal covers the record of pushes")

        let row = try #require(SnapshotPresenter().present(
            Snapshot(repos: [repo], refreshedAt: now),
            refreshState: .idle(lastRefreshedAt: now),
            collapsedRepoIDs: [],
            scanResult: nil,
            appVersion: "0.9.0",
            now: now).sections.first?.active.first { $0.title == "ahead-two" })

        #expect(row.pushTooltip.contains(Strings.fetchTimeNotChecked), "\(row.pushTooltip)")
        #expect(!row.pushTooltip.contains(Strings.notFetchedYet),
                "the tooltip claimed the repo has never fetched: \(row.pushTooltip)")
    }

    @Test("repoOnAVolumeThatCannotBeStattedSkipsDirectFileReads")
    func repoOnAVolumeThatCannotBeStattedSkipsDirectFileReads() async throws {
        let runner = Self.runner()
        let fs = Self.fileSystem(volume: .unreachable(code: ENOTCONN))

        let repo = await Self.loader(runner, fs).load(
            DiscoveredRepo(path: Argv.repo, id: RepoID(commonDir: Argv.commonDirectory)),
            wantsPullRequests: false,
            cachedPRs: nil,
            now: Date(timeIntervalSince1970: 1_788_400_000))

        #expect(repo.branches.count == 7)
        #expect(fs.statRegularFileCallCount == 0)
        #expect(repo.errors.contains { $0.stage == .reflog })
    }

    /// The gate is the volume, not the prefix: a repo on a local external disk reads its own
    /// reflog exactly as a repo in the home folder does.
    @Test("repoOnALocalVolumeStillReadsItsReflog")
    func repoOnALocalVolumeStillReadsItsReflog() async throws {
        let runner = Self.runner()
        let fs = Self.fileSystem(volume: .local)

        let repo = await Self.loader(runner, fs).load(
            DiscoveredRepo(path: Argv.repo, id: RepoID(commonDir: Argv.commonDirectory)),
            wantsPullRequests: false,
            cachedPRs: nil,
            now: Date(timeIntervalSince1970: 1_788_400_000))

        let main = try #require(repo.branches.first { $0.name == "main" })
        #expect(main.push.source == .reflogObserved)
        #expect(fs.statRegularFileCallCount > 0)
        #expect(repo.errors.isEmpty)
    }
}

/// MAJOR 1: "A capped per-head query can falsely render 'No PR'."
///
/// `gh pr list --head <name> --limit 5` was asked for five results and any success was then
/// recorded as covering **every** owner of that head. Five newer PRs from other forks push the
/// local owner's PR off the page, the owner-aware match correctly rejects the five strangers, and
/// the row renders "No PR" beside an open one. A page that came back full is not evidence of
/// absence.
@Suite("A per-head page that filled up is not an absence proof")
struct PerHeadQueryExhaustivenessTests {

    private enum Argv {
        static let repo = "/Users/tester/monorepo"
        static let commonDirectory = "/Users/tester/monorepo/.git"

        static let headsFormat =
            "--format=%(refname)%1f%(objectname)%1f%(committerdate:unix)%1f%(upstream:short)%1f%(upstream:remotename)%1f%(upstream:track,nobracket)%1f%(HEAD)"
        static let remotesFormat = "--format=%(refname)%1f%(objectname)%1f%(committerdate:unix)"

        static let identityCommonDir = ["-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"]
        static let identityTopLevel = ["-C", repo, "rev-parse", "--path-format=absolute", "--show-toplevel"]
        static let remoteOriginURL = ["-C", repo, "config", "--get", "remote.origin.url"]
        static let branchRefs = ["-C", repo, "for-each-ref", headsFormat, "--", "refs/heads"]
        static let remoteRefs = ["-C", repo, "for-each-ref", remotesFormat, "--", "refs/remotes/"]
        static let worktrees = ["-C", repo, "worktree", "list", "--porcelain", "-z"]
    }

    private static let slug = GitHubSlug(host: "github.com", owner: "tester", name: "demo")

    private static func headArgv(_ branch: String) -> [String] {
        ["pr", "list", "--repo", slug.ghRepoArgument, "--state", "all", "--head", branch,
         "--limit", "\(GHClient.perHeadQueryLimit)", "--json", GHClient.jsonFields]
    }

    /// `count` PRs on the same head, every one of them owned by somebody else — the fork traffic
    /// that pushes the user's own PR off a capped page.
    private static func strangerPRs(head: String, count: Int) -> String {
        let rows = (0..<count).map { index in
            """
            {
              "baseRefName": "main",
              "headRefName": "\(head)",
              "headRefOid": "\(String(repeating: "\(index % 10)", count: 40))",
              "headRepositoryOwner": { "id": "U_\(index)", "name": "Stranger", "login": "stranger-\(index)" },
              "isDraft": false,
              "mergeCommit": null,
              "mergedAt": null,
              "number": \(1000 + index),
              "reviewDecision": "",
              "state": "OPEN",
              "updatedAt": "2026-08-2\(index % 10)T10:00:00Z",
              "url": "https://github.com/tester/demo/pull/\(1000 + index)"
            }
            """
        }
        return "[\n" + rows.joined(separator: ",\n") + "\n]"
    }

    private static func runner(headResults: [String: String]) -> RecordedCommandRunner {
        let runner = RecordedCommandRunner()
        runner.stubGit(Argv.identityCommonDir, stdout: "\(Argv.commonDirectory)\n")
        runner.stubGit(Argv.identityTopLevel, stdout: "\(Argv.repo)\n")
        runner.stubGit(Argv.remoteOriginURL, stdout: "https://github.com/tester/demo.git\n")
        runner.stubGit(Argv.branchRefs, stdout: Fixture.text("synthetic-for-each-ref-heads-mixed.txt"))
        runner.stubGit(Argv.remoteRefs, stdout: Fixture.text("synthetic-for-each-ref-remotes.txt"))
        runner.stubGit(Argv.worktrees, stdout: Fixture.text("synthetic-worktree-list-multi.txt"))

        let empty = Fixture.text("synthetic-gh-pr-list-empty.json")
        runner.stub(.init(executableName: "gh", arguments: ["auth", "status"],
                          result: .stdout(Fixture.text("recorded-gh-auth-status-github.com.txt"))))
        runner.stub(.init(executableName: "gh", arguments: ["auth", "status", "--hostname", "github.com"],
                          result: .stdout(Fixture.text("recorded-gh-auth-status-github.com.txt"))))
        runner.stub(.init(
            executableName: "gh",
            arguments: ["pr", "list", "--repo", slug.ghRepoArgument, "--state", "all", "--limit", "100",
                        "--json", GHClient.jsonFields],
            result: .stdout(empty)))
        runner.stub(.init(
            executableName: "gh",
            arguments: ["pr", "list", "--repo", slug.ghRepoArgument, "--state", "open", "--author", "@me",
                        "--limit", "100", "--json", GHClient.jsonFields],
            result: .stdout(empty)))
        for name in [
            "main", "ahead-two", "behind-three", "diverged", "upstream-gone", "no-upstream",
            "feature/nested name",
        ] {
            runner.stub(.init(executableName: "gh", arguments: headArgv(name),
                              result: .stdout(headResults[name] ?? empty)))
        }
        return runner
    }

    private static func load(_ runner: RecordedCommandRunner) async -> Repo {
        let fs = InMemoryFileSystem()
        return await RepoLoader(
            git: GitClient(runner: runner, gitPath: "/usr/bin/git"),
            gh: GHClient(runner: runner, ghPath: "/opt/homebrew/bin/gh"),
            reflog: ReflogFileReader(fileSystem: fs),
            fileSystem: fs
        ).load(
            DiscoveredRepo(path: Argv.repo, id: RepoID(commonDir: Argv.commonDirectory)),
            wantsPullRequests: true,
            cachedPRs: nil,
            now: Date(timeIntervalSince1970: 1_788_400_000))
    }

    @Test("perHeadResultAtTheLimitIsNotTreatedAsExhaustive")
    func perHeadResultAtTheLimitIsNotTreatedAsExhaustive() async throws {
        // A full page of strangers' PRs on `main`: the local owner's own PR, if any, is on a page
        // nobody asked for.
        let full = Self.strangerPRs(head: "main", count: GHClient.perHeadQueryLimit)
        let repo = await Self.load(Self.runner(headResults: ["main": full]))

        // The limit is the first half of the fix: five was low enough that ordinary fork traffic
        // filled it (codex round 4, MAJOR 1).
        #expect(GHClient.perHeadQueryLimit == 20)

        let main = try #require(repo.branches.first { $0.name == "main" })
        #expect(main.prStatus == .notChecked,
                "a page that filled up was read as \"nobody has a PR on this head\": \(main.prStatus)")

        // Every other branch came back short, so those really were answered.
        let ahead = try #require(repo.branches.first { $0.name == "ahead-two" })
        #expect(ahead.prStatus == PRStatus.none)
    }

    /// The owners the full page *did* name are still covered: they were seen, and what was seen is
    /// what coverage records.
    @Test("aFullPageStillCoversTheOwnersItNamed")
    func fullPageStillCoversTheOwnersItNamed() async {
        var rows = GHClient.perHeadQueryLimit
        rows -= 1
        // One short of the limit is a page that ended, so the head is covered for every owner.
        let short = Self.strangerPRs(head: "main", count: rows)
        let repo = await Self.load(Self.runner(headResults: ["main": short]))

        let main = repo.branches.first { $0.name == "main" }
        #expect(main?.prStatus == PRStatus.none,
                "a page that ended before the limit answered for every owner of that head")
    }
}
