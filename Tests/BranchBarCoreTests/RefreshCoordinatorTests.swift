import Foundation
import Testing

@testable import BranchBarCore

// Acceptance tests for packet 3.2's deadline, cancellation, coalescing, order, lazy-PR, and
// persistence semantics, written before the implementation from the OWNER comments on
// `RefreshCoordinator`, PLAN.md §3 (Refresh), §4 (refresh lifecycle), §5 (`RefreshPolicy`,
// `CacheFile`), §7 (named invariants), and docs/TEST-PLAN.md's "Refresh lifecycle — packet 3.2"
// rows.
//
// Everything is driven through the three frozen seams: `RecordedCommandRunner` (per-stub delays
// and the opt-in peak-in-flight probe), `InMemoryFileSystem` (the tree `RepoScanner` walks), and
// `InMemoryCacheStore` (load and save counts). No test touches the real home folder, a real repo,
// git, gh, or the network, and an unstubbed command fails the test by itself — so a coordinator
// that starts issuing an invocation PLAN.md §5 never froze is caught here rather than at Gate 3.
//
// The three repos are the two recorded ones (`recorded-branchbar-*`,
// `recorded-hannah-personal-agent-*`) plus one synthetic third (`synthetic-refresh-charlie-*`),
// because a stable order needs a middle element and a cap of 2 needs a third repo to hold back.
// Their paths are the paths inside the recorded fixtures, so `rev-parse`'s recorded output is
// truthful for the stubbed repo; the tree those paths live in is `InMemoryFileSystem`, never disk.
//
// ---------------------------------------------------------------------------------------------
// Readings this file pins, where the frozen contract left a choice
// ---------------------------------------------------------------------------------------------
//
// 1. **`force` is the manual reason.** The frozen `refresh(force:expandedRepoIDs:tools:onProgress:)`
//    has no `reason` parameter, so `force: false` is the debounced popover-open reason and
//    `force: true` is manual Refresh, which bypasses the debounce
//    (`manualRefreshBypassesDebounce`, `popoverOpenWithinDebounceIssuesNoWork`). Coalescing is a
//    separate rule from debouncing: `force: true` still coalesces into an in-flight refresh
//    (`secondRefreshWhileRunningCoalesces`), because PLAN.md §3 says an in-flight refresh is
//    returned, not queued, and says it about refreshes rather than about popover opens.
//
// 2. **The debounce clock is the injected `now`.** A refresh inside `policy.debounce` of the last
//    finished refresh issues no commands and returns the previous snapshot unchanged. Tests move
//    the clock rather than sleeping.
//
// 3. **`onProgress` is the only emit channel.** The frozen stub has no `AsyncStream` property, so
//    the launch behavior in PLAN.md §4 ("load cache → show stale rows → refresh") is observable
//    as the **first** snapshot handed to `onProgress` on the first refresh: the cached
//    `lastSnapshot`, every repo `isStale = true`, before any repo has been reloaded
//    (`launchEmitsStaleCachedSnapshotBeforeRefreshing`).
//
// 4. **Every emit carries every repo.** "Emit a Snapshot after each repo completes without
//    reordering" is pinned as: each emitted snapshot lists the whole repo set in the order
//    computed once at the start, with not-yet-loaded repos present as their previous (or empty)
//    row. Rows fill in; the list never grows, shrinks, or reorders mid-refresh
//    (`rowOrderIsStableAcrossProgressiveEmits`).
//
// 5. **Stable order is previous-snapshot `lastActivity` first, then alphabetical by `Repo.name`.**
//    PLAN.md §3 says "most recent first; new repos appended alphabetically"; these tests read
//    "new" as "absent from the previous snapshot" and "alphabetically" as by `Repo.name`
//    (`newReposAreAppendedAlphabeticallyAfterThePreviousSnapshotsOrder`).
//
// 6. **The repo list comes from the scan, never from the filesystem directly.** The coordinator is
//    handed a `RepoScanner` and a `CacheStore` and nothing else that can see files, so a repo is
//    present because the cached scan or a fresh scan lists it. A repo in the previous snapshot
//    whose path is no longer discoverable is dropped and never has a command issued against it
//    (`repoWhosePathVanishedIsDroppedWithNote`; the user-facing note is `SnapshotPresenter`'s job,
//    packet 2.2, and is not observable through this API). **Do not add a filesystem existence gate
//    on a real `FileSystem`**: these repos exist only in `InMemoryFileSystem`, which reaches the
//    coordinator solely inside the `RepoScanner` it is given.
//
// 7. **The `ScanPolicy` comes from the cache.** The frozen init carries no home root, so the
//    policy for a rescan is `CacheFile.scan?.policy` with `CacheFile.manuallyAddedRepos` as extra
//    roots. Every test here seeds a cached `ScanResult` so the home root is explicit; the
//    first-ever-launch case (no cached scan at all) needs a default home root the frozen init
//    cannot express and is therefore left to the implementer (see the parameter list below).
//    "The cache has none" is exercised as a cached scan whose `repos` is empty.
//
// 8. **Preflight results are reported, not re-derived.** `refresh` is handed a `ToolStatus`; the
//    returned snapshot carries it. With `tools.gitPath == nil` the refresh returns a snapshot and
//    issues no command at all rather than trapping
//    (`missingGitFailsRefreshWithUserFacingFailureNotCrash`); the `UserFacingFailure` copy itself
//    belongs to `Strings.swift` (packet 4.0) and `RefreshState` has no channel in this API.
//
// 9. **The cap is on repos.** The peak-in-flight probe counts overlapping `CommandRunner.run`
//    calls, and `RepoLoader` runs its stages as the ordered sequence its OWNER comment describes,
//    so peak in-flight equals the number of repos in flight
//    (`peakConcurrencyNeverExceedsCap`).
//
// 10. **`cancel()` is observable at the runner.** The coordinator half of
//    `cancelledRepoTasksTerminateTheirChildProcesses` is that cancellation reaches
//    `CommandRunner.run` — `ProcessCommandRunner` turning that into a terminated child is packet
//    2.5's half, already covered by `ProcessCommandRunnerTests`. A local probe runner wraps
//    `RecordedCommandRunner` and records which commands were cancelled, because the shared double
//    (owned by packet 1.1) does not record that and is outside this packet's write boundary.
//
// ---------------------------------------------------------------------------------------------
// Additional **defaulted** initializer parameters the implementer may add
// ---------------------------------------------------------------------------------------------
//
// The frozen `RefreshCoordinator.init(scanner:loader:cache:policy:now:)` and the frozen
// `refresh(force:expandedRepoIDs:tools:onProgress:)` / `cancel()` signatures are what every call
// site below uses. Each parameter listed here may be added **with a default**, so that no test in
// this file needs an edit; anything without a default, or any change to an existing parameter's
// name, type, or order, breaks the merge criterion.
//
//   - `makeLoader: (@Sendable (DiscoveredRepo) -> RepoLoader)? = nil` — a per-repo loader factory.
//     The frozen init takes one `RepoLoader`, and these tests make a repo fail or run long through
//     `RecordedCommandRunner` stubs keyed on the `-C <path>` argument instead, so the factory is
//     optional and must fall back to the single `loader` when nil.
//   - `scanPolicy: ScanPolicy? = nil` — the policy for a scan when `CacheFile.scan` carries none.
//     Its default must be reached only in that case (reading 7); every test here seeds a cached
//     scan whose policy names the in-memory home root.
//   - `fileSystem: FileSystem = RealFileSystem()` — only if the cache or reflog paths need one.
//     It must not gate which repos appear (reading 6).
//   - `sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(...) }` — a
//     deadline seam. These tests shrink `policy.overallDeadline` instead and wait in real time, so
//     the default must behave like `Task.sleep`.
//   - `refresh(force:expandedRepoIDs:tools:onProgress:)` may gain trailing defaulted parameters
//     for the reasons the frozen signature cannot express: `rescan: Bool = false` (PLAN.md §3's
//     rescan reason, which forces a scan) and `bypassPRCache: Bool = false` (the `manualPRs`
//     reason, "Refresh PRs now").

// MARK: - The three repos and their frozen invocations

/// One repo's stubs. `path` is what the scanner discovers and what `-C` names; the fixtures hold
/// what git prints for it.
private struct RepoStub: Sendable {
    var path: String
    var slug: String
    var revParse: String
    var heads: String
    var remotes: String
    var config: String
    var worktrees: String

    var name: String { (path as NSString).lastPathComponent }
    /// `RepoScanner` without a `CommandRunner` derives the common dir from the `.git` directory,
    /// and each `rev-parse` fixture prints the same path, so both routes agree.
    var id: RepoID { RepoID(commonDir: path + "/.git") }
    var discovered: DiscoveredRepo { DiscoveredRepo(path: path, id: id) }

    static let home = "/Users/hannahstulberg"

    /// Newest `lastActivity` of the three (committer date 1788317855).
    static let branchbar = RepoStub(
        path: home + "/branchbar",
        slug: "github.com/hannahstulberg/branchbar",
        revParse: "recorded-branchbar-rev-parse.txt",
        heads: "recorded-branchbar-for-each-ref-heads.txt",
        remotes: "recorded-branchbar-for-each-ref-remotes.txt",
        config: "recorded-branchbar-config-remote-origin-url.txt",
        worktrees: "recorded-branchbar-worktree-list.txt"
    )

    /// Middle `lastActivity` (1788310842), three branches.
    static let personalAgent = RepoStub(
        path: home + "/hannah-personal-agent",
        slug: "github.com/hannahstulberg/hannah-personal-agent",
        revParse: "recorded-hannah-personal-agent-rev-parse.txt",
        heads: "recorded-hannah-personal-agent-for-each-ref-heads.txt",
        remotes: "recorded-hannah-personal-agent-for-each-ref-remotes.txt",
        config: "recorded-hannah-personal-agent-config-remote-origin-url.txt",
        worktrees: "recorded-hannah-personal-agent-worktree-list.txt"
    )

    /// Oldest `lastActivity` (1788000000), and alphabetically between the other two.
    static let charlie = RepoStub(
        path: home + "/code/charlie",
        slug: "github.com/hannahstulberg/charlie",
        revParse: "synthetic-refresh-charlie-rev-parse.txt",
        heads: "synthetic-refresh-charlie-for-each-ref-heads.txt",
        remotes: "synthetic-refresh-charlie-for-each-ref-remotes.txt",
        config: "synthetic-refresh-charlie-config-remote-origin-url.txt",
        worktrees: "synthetic-refresh-charlie-worktree-list.txt"
    )

    static let all: [RepoStub] = [.branchbar, .personalAgent, .charlie]
}

/// The five git stages `RepoLoader`'s OWNER comment names, as the argument arrays `GitClient`
/// builds. Taken from `GitClient`'s own format constants rather than retyped, so a format drift is
/// a compile error and not a silently unstubbed command.
private enum Stage: CaseIterable, Sendable {
    case revParse, config, heads, remotes, worktrees

    func arguments(_ path: String) -> [String] {
        switch self {
        case .revParse:
            return ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel"]
        case .config:
            return ["-C", path, "config", "--get", "remote.origin.url"]
        case .heads:
            return ["-C", path, "for-each-ref", GitClient.headsFormat, "--", "refs/heads"]
        case .remotes:
            return ["-C", path, "for-each-ref", GitClient.remotesFormat, "--", "refs/remotes/"]
        case .worktrees:
            return ["-C", path, "worktree", "list", "--porcelain"]
        }
    }

    func fixture(_ repo: RepoStub) -> String {
        switch self {
        case .revParse: return repo.revParse
        case .config: return repo.config
        case .heads: return repo.heads
        case .remotes: return repo.remotes
        case .worktrees: return repo.worktrees
        }
    }
}

private let gitPath = "/opt/homebrew/bin/git"
private let ghPath = "/opt/homebrew/bin/gh"

private let healthyTools = ToolStatus(
    gitPath: gitPath,
    gitVersion: "git version 2.39.5 (Apple Git-154)",
    ghPath: ghPath,
    ghAuthByHost: ["github.com": true]
)

/// Stubs every frozen git invocation for one repo. `delay` is applied to each stage, so a repo
/// that must outlive the deadline or hold a concurrency slot is one parameter away.
private func stubGit(
    _ repo: RepoStub,
    into runner: RecordedCommandRunner,
    delay: TimeInterval = 0,
    failing: Set<Stage> = []
) {
    for stage in Stage.allCases {
        let result: RecordedCommandRunner.StubResult
        if failing.contains(stage) {
            result = .failure(.nonZeroExit(exitCode: 128, standardError: "fatal: not a git repository"))
        } else {
            result = .stdout(Fixture.text(stage.fixture(repo)))
        }
        runner.stub(
            RecordedCommandRunner.Stub(
                executableName: "git",
                arguments: stage.arguments(repo.path),
                workingDirectory: repo.path,
                result: result,
                delay: delay
            )
        )
    }
}

/// The three frozen `gh` invocations, all answering honestly-empty. A repo the eager set skipped
/// simply never reaches them, and an unstubbed one would fail the test, so "no gh calls" is
/// asserted on the recorded call list rather than on a missing stub.
private func stubGH(_ repo: RepoStub, into runner: RecordedCommandRunner) {
    runner.stubGH(["auth", "status", "--hostname", "github.com"],
                  stdout: Fixture.text("recorded-gh-auth-status-github.com.txt"))
    let empty = Fixture.text("synthetic-gh-pr-list-empty.json")
    runner.stubGH(
        ["pr", "list", "--repo", repo.slug, "--state", "all", "--limit", "100", "--json", GHClient.jsonFields],
        stdout: empty)
    runner.stubGH(
        ["pr", "list", "--repo", repo.slug, "--state", "open", "--author", "@me", "--limit", "100",
         "--json", GHClient.jsonFields],
        stdout: empty)
}

// MARK: - Test-local helpers

/// A settable clock for the injected `now` closure, so the debounce is tested by moving time
/// rather than by waiting 30 s.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) { self.value = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value = value.addingTimeInterval(seconds)
    }

    var closure: @Sendable () -> Date { { [self] in self.now } }
}

/// Collects every progressive emit in order.
private final class Emits: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Snapshot] = []

    var all: [Snapshot] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    var handler: @Sendable (Snapshot) -> Void {
        { [self] snapshot in
            self.lock.lock(); defer { self.lock.unlock() }
            self.storage.append(snapshot)
        }
    }
}

/// Wraps the shared double to record which commands were cancelled. `RecordedCommandRunner` is
/// packet 1.1's file and outside this packet's write boundary, so the probe lives here.
private final class CancellationProbeRunner: CommandRunner, @unchecked Sendable {
    let base: RecordedCommandRunner
    private let lock = NSLock()
    private var storage: [Command] = []

    init(_ base: RecordedCommandRunner) { self.base = base }

    var cancelledCommands: [Command] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    /// Synchronous on purpose: `NSLock` is unavailable from an async context.
    private func record(_ command: Command) {
        lock.lock(); defer { lock.unlock() }
        storage.append(command)
    }

    func run(_ command: Command) async throws -> CommandOutput {
        do {
            return try await base.run(command)
        } catch {
            if error is CancellationError || (error as? CommandError) == .cancelled {
                record(command)
            }
            throw error
        }
    }
}

/// Polls until `condition` holds or `timeout` elapses. Used only to sequence a second call against
/// an in-flight first one; every assertion is made after the refresh has returned.
private func waitUntil(_ timeout: TimeInterval = 5, _ condition: @Sendable () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// A cached `ScanResult` naming the in-memory home root, so a rescan walks the test's tree and the
/// coordinator never needs a home root the frozen init cannot give it (reading 7).
private func scanResult(_ repos: [RepoStub], scannedAt: Date) -> ScanResult {
    ScanResult(
        policy: ScanPolicy(homeRoot: RepoStub.home),
        scannedAt: scannedAt,
        repos: repos.map(\.discovered),
        candidatesExamined: repos.count
    )
}

/// A previous snapshot, used both as the launch payload and as the source of the stable order.
/// `lastActivity` is given explicitly so an order test does not depend on a fixture's dates.
private func previousSnapshot(_ ordered: [(RepoStub, Date)], refreshedAt: Date) -> Snapshot {
    Snapshot(
        repos: ordered.map { repo, activity in
            Repo(id: repo.id, name: repo.name, path: repo.path, lastActivity: activity)
        },
        refreshedAt: refreshedAt,
        tools: healthyTools
    )
}

private struct Harness {
    var fileSystem: InMemoryFileSystem
    var runner: RecordedCommandRunner
    var cache: InMemoryCacheStore
    var clock: Clock
    var coordinator: RefreshCoordinator

    /// Every `git … -C <path>` argument list the runner was asked for, by repo path.
    func gitCalls(for repo: RepoStub) -> [Command] {
        runner.calls(matchingExecutable: "git").filter { $0.arguments.dropFirst().first == repo.path }
    }

    /// `gh pr list` calls only; `gh auth status` is preflight and is asserted separately.
    var prListCalls: [Command] {
        runner.calls(matchingExecutable: "gh").filter { $0.arguments.first == "pr" }
    }

    func prListCalls(for repo: RepoStub) -> [Command] {
        prListCalls.filter { $0.arguments.contains(repo.slug) }
    }
}

/// Builds the whole world: an in-memory tree holding `repos`, git and gh stubs for each, a cache,
/// a clock, and the coordinator over the frozen init.
private func makeHarness(
    repos: [RepoStub] = RepoStub.all,
    policy: RefreshPolicy = .default,
    cacheFile: CacheFile? = nil,
    now: Date = Date(timeIntervalSince1970: 1_788_400_000),
    delays: [String: TimeInterval] = [:],
    failing: [String: Set<Stage>] = [:],
    stubPullRequests: Bool = true,
    loaderRunner: (any CommandRunner)? = nil,
    runner sharedRunner: RecordedCommandRunner = RecordedCommandRunner()
) -> Harness {
    let fileSystem = InMemoryFileSystem(home: RepoStub.home)
    for repo in repos {
        fileSystem.addRepository(at: repo.path)
        stubGit(repo, into: sharedRunner, delay: delays[repo.path] ?? 0, failing: failing[repo.path] ?? [])
        if stubPullRequests { stubGH(repo, into: sharedRunner) }
    }

    let clock = Clock(now)
    let cache = InMemoryCacheStore(initial: cacheFile)
    let processRunner: any CommandRunner = loaderRunner ?? sharedRunner

    let loader = RepoLoader(
        git: GitClient(runner: processRunner, gitPath: gitPath),
        gh: GHClient(runner: processRunner, ghPath: ghPath, policy: policy),
        reflog: ReflogFileReader(fileSystem: fileSystem),
        policy: policy
    )

    let coordinator = RefreshCoordinator(
        scanner: RepoScanner(fileSystem: fileSystem),
        loader: loader,
        cache: cache,
        policy: policy,
        now: clock.closure
    )

    return Harness(
        fileSystem: fileSystem,
        runner: sharedRunner,
        cache: cache,
        clock: clock,
        coordinator: coordinator
    )
}

// MARK: - Coalescing and the debounce

@Suite("A refresh coalesces into the one already running and honours the 30 s debounce", .serialized)
struct RefreshCoordinatorCoalescingTests {

    /// PLAN.md §3 and §7 `secondRefreshWhileRunningCoalesces`: "an in-flight refresh is returned,
    /// not queued". The second caller gets the first refresh's snapshot and the repos are walked
    /// once — a queued second pass would double every `rev-parse`.
    @Test("secondRefreshWhileRunningCoalesces")
    func secondRefreshWhileRunningCoalesces() async throws {
        let cached = CacheFile(scan: scanResult(RepoStub.all, scannedAt: Date(timeIntervalSince1970: 1_788_399_000)))
        let harness = makeHarness(
            policy: RefreshPolicy(debounce: 30, overallDeadline: 30),
            cacheFile: cached,
            delays: Dictionary(uniqueKeysWithValues: RepoStub.all.map { ($0.path, 0.15) })
        )

        let first = Task { await harness.coordinator.refresh(force: false, expandedRepoIDs: [], tools: healthyTools, onProgress: { _ in }) }
        await waitUntil { harness.runner.callCount > 0 }
        // `force: true` so that the debounce cannot be the reason the second call did no work.
        let second = Task { await harness.coordinator.refresh(force: true, expandedRepoIDs: [], tools: healthyTools, onProgress: { _ in }) }

        let a = await first.value
        let b = await second.value

        #expect(a == b)
        for repo in RepoStub.all {
            let revParses = harness.gitCalls(for: repo).filter { $0.arguments.contains("rev-parse") }
            #expect(revParses.count == 1, "\(repo.name) was walked \(revParses.count) times, not once")
        }
    }

    /// `popoverOpenWithinDebounceIssuesNoWork`. The second open is 5 s after the first refresh
    /// finished, inside the 30 s debounce, so it issues nothing and hands back what is already
    /// known.
    @Test("popoverOpenWithinDebounceIssuesNoWork")
    func popoverOpenWithinDebounceIssuesNoWork() async throws {
        let cached = CacheFile(scan: scanResult(RepoStub.all, scannedAt: Date(timeIntervalSince1970: 1_788_399_000)))
        let harness = makeHarness(policy: RefreshPolicy(debounce: 30, overallDeadline: 30), cacheFile: cached)

        let first = await harness.coordinator.refresh(force: false, expandedRepoIDs: [], tools: healthyTools, onProgress: { _ in })
        let afterFirst = harness.runner.callCount
        #expect(afterFirst > 0)

        harness.clock.advance(5)
        let emits = Emits()
        let second = await harness.coordinator.refresh(force: false, expandedRepoIDs: [], tools: healthyTools, onProgress: emits.handler)

        #expect(harness.runner.callCount == afterFirst)
        #expect(second == first)
        #expect(emits.all.isEmpty, "a debounced open emitted \(emits.all.count) snapshots")
    }

    /// `manualRefreshBypassesDebounce`. Same 5 s gap, `force: true`, and the repos are walked again.
    @Test("manualRefreshBypassesDebounce")
    func manualRefreshBypassesDebounce() async throws {
        let cached = CacheFile(scan: scanResult(RepoStub.all, scannedAt: Date(timeIntervalSince1970: 1_788_399_000)))
        let harness = makeHarness(policy: RefreshPolicy(debounce: 30, overallDeadline: 30), cacheFile: cached)

        _ = await harness.coordinator.refresh(force: false, expandedRepoIDs: [], tools: healthyTools, onProgress: { _ in })
        let afterFirst = harness.runner.callCount

        harness.clock.advance(5)
        let second = await harness.coordinator.refresh(force: true, expandedRepoIDs: [], tools: healthyTools, onProgress: { _ in })

        #expect(harness.runner.callCount > afterFirst)
        #expect(second.refreshedAt == harness.clock.now)
    }

    /// The other side of the debounce: once it has elapsed, a plain popover open does the work.
    @Test("popoverOpenAfterTheDebounceHasElapsedIssuesAFreshRefresh")
    func popoverOpenAfterTheDebounceHasElapsedIssuesAFreshRefresh() async throws {
        let cached = CacheFile(scan: scanResult(RepoStub.all, scannedAt: Date(timeIntervalSince1970: 1_788_399_000)))
        let harness = makeHarness(policy: RefreshPolicy(debounce: 30, overallDeadline: 30), cacheFile: cached)

        _ = await harness.coordinator.refresh(force: false, expandedRepoIDs: [], tools: healthyTools, onProgress: { _ in })
        let afterFirst = harness.runner.callCount

        harness.clock.advance(31)
        let second = await harness.coordinator.refresh(force: false, expandedRepoIDs: [], tools: healthyTools, onProgress: { _ in })

        #expect(harness.runner.callCount > afterFirst)
        #expect(second.refreshedAt == harness.clock.now)
    }
}

// MARK: - The concurrency cap

@Suite("The task group never runs more repos at once than the cap", .serialized)
struct RefreshCoordinatorConcurrencyTests {

    /// PLAN.md §5 `maxConcurrentRepos` and §7 `peakConcurrencyNeverExceedsCap`, measured with the
    /// double's peak-in-flight probe. The cap is set to 2 rather than the shipped 4 so that three
    /// repos are enough to prove the third waits — and the lower bound proves the cap is a cap and
    /// not an accidental serialization.
    @Test("peakConcurrencyNeverExceedsCap")
    func peakConcurrencyNeverExceedsCap() async throws {
        let policy = RefreshPolicy(debounce: 0, overallDeadline: 30, maxConcurrentRepos: 2, perHeadFallbackCap: 0)
        let runner = RecordedCommandRunner()
        runner.tracksConcurrency = true
        let cached = CacheFile(scan: scanResult(RepoStub.all, scannedAt: Date(timeIntervalSince1970: 1_788_399_000)))
        let harness = makeHarness(
            policy: policy,
            cacheFile: cached,
            delays: Dictionary(uniqueKeysWithValues: RepoStub.all.map { ($0.path, 0.1) }),
            runner: runner
        )

        _ = await harness.coordinator.refresh(force: true, expandedRepoIDs: [], tools: healthyTools, onProgress: { _ in })

        #expect(runner.peakInFlight <= policy.maxConcurrentRepos,
                "peak in flight was \(runner.peakInFlight), cap is \(policy.maxConcurrentRepos)")
        #expect(runner.peakInFlight >= 2, "the cap serialized the walk instead of bounding it")
    }
}

// MARK: - The overall deadline and cancellation

@Suite("The overall deadline cuts repos off, marks them stale, and cancellation reaches the runner", .serialized)
struct RefreshCoordinatorDeadlineTests {

    /// PLAN.md §3 and §7 `refreshHonorsOverallDeadlineAndMarksUnfinishedReposStale`. The deadline
    /// is shrunk to 0.5 s (that is what `RefreshPolicy` is a value for) and one repo's every git
    /// stage sleeps 3 s, so it cannot finish: it lands in the snapshot marked `isStale` with a
    /// `RepoError(stage: .deadlineExceeded)`, the other two are complete and unmarked, and the
    /// refresh returns instead of waiting out the slow repo.
    @Test("refreshHonorsOverallDeadlineAndMarksUnfinishedReposStale")
    func refreshHonorsOverallDeadlineAndMarksUnfinishedReposStale() async throws {
        let cached = CacheFile(scan: scanResult(RepoStub.all, scannedAt: Date(timeIntervalSince1970: 1_788_399_000)))
        let harness = makeHarness(
            policy: RefreshPolicy(debounce: 0, overallDeadline: 0.5, maxConcurrentRepos: 4, perHeadFallbackCap: 0),
            cacheFile: cached,
            delays: [RepoStub.charlie.path: 3.0]
        )

        let started = Date()
        let snapshot = await harness.coordinator.refresh(
            force: true, expandedRepoIDs: [], tools: healthyTools, onProgress: { _ in })
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 2.5, "the refresh waited \(elapsed) s for a repo the deadline had cut off")

        let slow = try #require(snapshot.repos.first { $0.name == RepoStub.charlie.name })
        #expect(slow.isStale)
        #expect(slow.errors.contains { $0.stage == .deadlineExceeded },
                "cut-off repo carries \(slow.errors) instead of a deadlineExceeded error")

        let fast = try #require(snapshot.repos.first { $0.name == RepoStub.branchbar.name })
        #expect(fast.isStale == false)
        #expect(fast.branches.isEmpty == false)
    }

    /// The other half of the deadline rule: a repo the deadline never touched keeps the branches it
    /// loaded, so a slow repo does not blank the snapshot.
    @Test("deadlineLeavesEveryFinishedRepoPopulated")
    func deadlineLeavesEveryFinishedRepoPopulated() async throws {
        let cached = CacheFile(scan: scanResult(RepoStub.all, scannedAt: Date(timeIntervalSince1970: 1_788_399_000)))
        let harness = makeHarness(
            policy: RefreshPolicy(debounce: 0, overallDeadline: 0.5, maxConcurrentRepos: 4, perHeadFallbackCap: 0),
            cacheFile: cached,
            delays: [RepoStub.charlie.path: 3.0]
        )

        let snapshot = await harness.coordinator.refresh(
            force: true, expandedRepoIDs: [], tools: healthyTools, onProgress: { _ in })

        #expect(snapshot.repos.count == 3, "the deadline dropped a repo instead of marking it stale")
        let personalAgent = try #require(snapshot.repos.first { $0.name == RepoStub.personalAgent.name })
        #expect(personalAgent.branches.count == 3)
        #expect(personalAgent.isStale == false)
    }

    /// PLAN.md §7 `cancelledRepoTasksTerminateTheirChildProcesses`, coordinator half:
    /// `cancel()` must propagate into the in-flight `CommandRunner.run` calls, which is what
    /// `ProcessCommandRunner` turns into a terminated child (packet 2.5's half). The probe records
    /// every command that saw cancellation.
    @Test("cancelledRepoTasksTerminateTheirChildProcesses")
    func cancelledRepoTasksTerminateTheirChildProcesses() async throws {
        let base = RecordedCommandRunner()
        let probe = CancellationProbeRunner(base)
        let cached = CacheFile(scan: scanResult(RepoStub.all, scannedAt: Date(timeIntervalSince1970: 1_788_399_000)))
        let harness = makeHarness(
            policy: RefreshPolicy(debounce: 0, overallDeadline: 30, maxConcurrentRepos: 4, perHeadFallbackCap: 0),
            cacheFile: cached,
            delays: Dictionary(uniqueKeysWithValues: RepoStub.all.map { ($0.path, 5.0) }),
            loaderRunner: probe,
            runner: base
        )

        let refresh = Task {
            await harness.coordinator.refresh(force: true, expandedRepoIDs: [], tools: healthyTools, onProgress: { _ in })
        }
        await waitUntil { base.callCount > 0 }
        await harness.coordinator.cancel()

        _ = await refresh.value
        #expect(probe.cancelledCommands.isEmpty == false,
                "cancel() did not reach the runner; \(base.callCount) commands ran and none was cancelled")
    }

    /// PLAN.md §3: cancel "leaves the last emitted snapshot in place". Nothing is persisted over the
    /// top of it and the call returns rather than hanging.
    @Test("cancelLeavesTheLastEmittedSnapshotInPlaceAndPersistsNothingNew")
    func cancelLeavesTheLastEmittedSnapshotInPlaceAndPersistsNothingNew() async throws {
        let previous = previousSnapshot(
            [(RepoStub.branchbar, Date(timeIntervalSince1970: 1_788_317_855))],
            refreshedAt: Date(timeIntervalSince1970: 1_788_399_000))
        let cached = CacheFile(
            scan: scanResult(RepoStub.all, scannedAt: Date(timeIntervalSince1970: 1_788_399_000)),
            lastSnapshot: previous)
        let harness = makeHarness(
            policy: RefreshPolicy(debounce: 0, overallDeadline: 30, maxConcurrentRepos: 4, perHeadFallbackCap: 0),
            cacheFile: cached,
            delays: Dictionary(uniqueKeysWithValues: RepoStub.all.map { ($0.path, 5.0) })
        )

        let refresh = Task {
            await harness.coordinator.refresh(force: true, expandedRepoIDs: [], tools: healthyTools, onProgress: { _ in })
        }
        await waitUntil { harness.runner.callCount > 0 }
        await harness.coordinator.cancel()
        _ = await refresh.value

        #expect(harness.cache.saveCount == 0, "a cancelled refresh persisted \(harness.cache.saveCount) time(s)")
        #expect(harness.cache.current?.lastSnapshot == previous)
    }
}

// MARK: - Stable order and progressive emits

@Suite("Rows fill in without reordering, and launch shows the cached snapshot as stale first", .serialized)
struct RefreshCoordinatorOrderTests {

    /// PLAN.md §5a.3 and §7 `rowOrderIsStableAcrossProgressiveEmits`. The order is computed once
    /// from the previous snapshot's `lastActivity` — charlie, branchbar, hannah-personal-agent —
    /// while the stub delays make them finish in exactly the opposite order. Every emit lists all
    /// three in the computed order, and so does the returned snapshot.
    @Test("rowOrderIsStableAcrossProgressiveEmits")
    func rowOrderIsStableAcrossProgressiveEmits() async throws {
        let previous = previousSnapshot(
            [
                (RepoStub.charlie, Date(timeIntervalSince1970: 1_788_390_000)),
                (RepoStub.branchbar, Date(timeIntervalSince1970: 1_788_380_000)),
                (RepoStub.personalAgent, Date(timeIntervalSince1970: 1_788_370_000)),
            ],
            refreshedAt: Date(timeIntervalSince1970: 1_788_399_000))
        let cached = CacheFile(
            scan: scanResult(RepoStub.all, scannedAt: Date(timeIntervalSince1970: 1_788_399_000)),
            lastSnapshot: previous)
        let harness = makeHarness(
            policy: RefreshPolicy(debounce: 0, overallDeadline: 30, maxConcurrentRepos: 4, perHeadFallbackCap: 0),
            cacheFile: cached,
            delays: [
                RepoStub.charlie.path: 0.30,
                RepoStub.branchbar.path: 0.15,
                RepoStub.personalAgent.path: 0.02,
            ]
        )

        let emits = Emits()
        let snapshot = await harness.coordinator.refresh(
            force: true, expandedRepoIDs: [], tools: healthyTools, onProgress: emits.handler)

        let expected = [RepoStub.charlie.name, RepoStub.branchbar.name, RepoStub.personalAgent.name]
        #expect(snapshot.repos.map(\.name) == expected)
        #expect(emits.all.count >= 3, "only \(emits.all.count) progressive emits for three repos")
        for (index, emitted) in emits.all.enumerated() {
            #expect(emitted.repos.map(\.name) == expected, "emit \(index) reordered to \(emitted.repos.map(\.name))")
        }
    }

    /// PLAN.md §3: "most recent first; new repos appended alphabetically". Only charlie is in the
    /// previous snapshot, so it leads and the two newcomers follow by name — branchbar before
    /// hannah-personal-agent — which is deliberately not their activity order.
    @Test("newReposAreAppendedAlphabeticallyAfterThePreviousSnapshotsOrder")
    func newReposAreAppendedAlphabeticallyAfterThePreviousSnapshotsOrder() async throws {
        let previous = previousSnapshot(
            [(RepoStub.charlie, Date(timeIntervalSince1970: 1_788_390_000))],
            refreshedAt: Date(timeIntervalSince1970: 1_788_399_000))
        let cached = CacheFile(
            scan: scanResult(RepoStub.all, scannedAt: Date(timeIntervalSince1970: 1_788_399_000)),
            lastSnapshot: previous)
        let harness = makeHarness(
            policy: RefreshPolicy(debounce: 0, overallDeadline: 30, perHeadFallbackCap: 0),
            cacheFile: cached)

        let snapshot = await harness.coordinator.refresh(
            force: true, expandedRepoIDs: [], tools: healthyTools, onProgress: { _ in })

        #expect(snapshot.repos.map(\.name)
                == [RepoStub.charlie.name, RepoStub.branchbar.name, RepoStub.personalAgent.name])
    }

    /// PLAN.md §4 and §7 `launchEmitsStaleCachedSnapshotBeforeRefreshing`: the cached rows are shown
    /// first, every one of them marked `isStale`, and only then does the refresh replace them.
    @Test("launchEmitsStaleCachedSnapshotBeforeRefreshing")
    func launchEmitsStaleCachedSnapshotBeforeRefreshing() async throws {
        let previous = previousSnapshot(
            [
                (RepoStub.branchbar, Date(timeIntervalSince1970: 1_788_390_000)),
                (RepoStub.personalAgent, Date(timeIntervalSince1970: 1_788_380_000)),
                (RepoStub.charlie, Date(timeIntervalSince1970: 1_788_370_000)),
            ],
            refreshedAt: Date(timeIntervalSince1970: 1_788_399_000))
        let cached = CacheFile(
            scan: scanResult(RepoStub.all, scannedAt: Date(timeIntervalSince1970: 1_788_399_000)),
            lastSnapshot: previous)
        let harness = makeHarness(
            policy: RefreshPolicy(debounce: 0, overallDeadline: 30, perHeadFallbackCap: 0),
            cacheFile: cached)

        let emits = Emits()
        let snapshot = await harness.coordinator.refresh(
            force: true, expandedRepoIDs: [], tools: healthyTools, onProgress: emits.handler)

        let launch = try #require(emits.all.first)
        #expect(launch.repos.map(\.id) == previous.repos.map(\.id))
        #expect(launch.repos.allSatisfy { $0.isStale }, "launch emit did not mark every cached row stale")
        #expect(launch.repos.allSatisfy { $0.branches.isEmpty }, "launch emit already carried refreshed rows")
        #expect(snapshot.repos.allSatisfy { $0.isStale == false })
    }
}

// MARK: - The repo list, the scan, and vanished repos

@Suite("The repo list comes from the cached scan, rescanned when it is empty or a week old", .serialized)
struct RefreshCoordinatorRepoListTests {

    /// PLAN.md §3 and §7 `scanRunsWhenCacheMissingOrOlderThanSevenDays`, the "older than 7 days"
    /// half: the cached scan is 8 days old and knows one repo, the tree holds three, and the
    /// refresh returns three and persists the new scan.
    @Test("scanRunsWhenTheCachedScanIsOlderThanSevenDays")
    func scanRunsWhenTheCachedScanIsOlderThanSevenDays() async throws {
        let eightDaysAgo = Date(timeIntervalSince1970: 1_788_400_000 - 8 * 86_400)
        let cached = CacheFile(scan: scanResult([RepoStub.branchbar], scannedAt: eightDaysAgo))
        let harness = makeHarness(
            policy: RefreshPolicy(debounce: 0, overallDeadline: 30, perHeadFallbackCap: 0),
            cacheFile: cached)

        let snapshot = await harness.coordinator.refresh(
            force: false, expandedRepoIDs: [], tools: healthyTools, onProgress: { _ in })

        #expect(Set(snapshot.repos.map(\.name)) == Set(RepoStub.all.map(\.name)))
        let persisted = try #require(harness.cache.current?.scan)
        #expect(persisted.repos.count == 3)
        #expect(persisted.scannedAt > eightDaysAgo)
    }

    /// The "cache has none" half of the same invariant, expressed as a cached scan that is fresh but
    /// empty — the shape a first launch leaves behind once the coordinator has a policy to scan
    /// with (reading 7).
    @Test("scanRunsWhenTheCachedScanHasNoRepos")
    func scanRunsWhenTheCachedScanHasNoRepos() async throws {
        let cached = CacheFile(scan: scanResult([], scannedAt: Date(timeIntervalSince1970: 1_788_399_000)))
        let harness = makeHarness(
            policy: RefreshPolicy(debounce: 0, overallDeadline: 30, perHeadFallbackCap: 0),
            cacheFile: cached)

        let snapshot = await harness.coordinator.refresh(
            force: false, expandedRepoIDs: [], tools: healthyTools, onProgress: { _ in })

        #expect(Set(snapshot.repos.map(\.name)) == Set(RepoStub.all.map(\.name)))
    }

    /// The complement: a scan from yesterday is reused as-is. The tree holds three repos and the
    /// cached scan names one, so a coordinator that rescans anyway returns three and fails here.
    @Test("freshCachedScanIsReusedWithoutRescanning")
    func freshCachedScanIsReusedWithoutRescanning() async throws {
        let yesterday = Date(timeIntervalSince1970: 1_788_400_000 - 86_400)
        let cached = CacheFile(scan: scanResult([RepoStub.branchbar], scannedAt: yesterday))
        let harness = makeHarness(
            policy: RefreshPolicy(debounce: 0, overallDeadline: 30, perHeadFallbackCap: 0),
            cacheFile: cached)

        let snapshot = await harness.coordinator.refresh(
            force: false, expandedRepoIDs: [], tools: healthyTools, onProgress: { _ in })

        #expect(snapshot.repos.map(\.name) == [RepoStub.branchbar.name])
        #expect(harness.gitCalls(for: RepoStub.charlie).isEmpty)
    }

    /// PLAN.md §7 `repoWhosePathVanishedIsDroppedWithNote`. The previous snapshot and the week-old
    /// scan both know a repo at `~/gone`; the tree does not. The rescan drops it, no command is ever
    /// issued against it — the double would record an Issue for the unstubbed `-C ~/gone` — and the
    /// persisted scan records the new truth. The user-facing note is `SnapshotPresenter`'s
    /// (packet 2.2) and has no channel in this API.
    @Test("repoWhosePathVanishedIsDroppedWithNote")
    func repoWhosePathVanishedIsDroppedWithNote() async throws {
        let vanished = RepoStub.home + "/gone"
        let eightDaysAgo = Date(timeIntervalSince1970: 1_788_400_000 - 8 * 86_400)
        var stale = scanResult(RepoStub.all, scannedAt: eightDaysAgo)
        stale.repos.append(DiscoveredRepo(path: vanished, id: RepoID(commonDir: vanished + "/.git")))
        let previous = previousSnapshot(
            [(RepoStub.branchbar, Date(timeIntervalSince1970: 1_788_390_000))],
            refreshedAt: eightDaysAgo)
        let cached = CacheFile(scan: stale, lastSnapshot: previous)

        let harness = makeHarness(
            policy: RefreshPolicy(debounce: 0, overallDeadline: 30, perHeadFallbackCap: 0),
            cacheFile: cached)

        let snapshot = await harness.coordinator.refresh(
            force: false, expandedRepoIDs: [], tools: healthyTools, onProgress: { _ in })

        #expect(snapshot.repos.contains { $0.path == vanished } == false)
        #expect(harness.runner.calls.contains { $0.arguments.contains(vanished) } == false)
        #expect(harness.cache.current?.scan?.repos.contains { $0.path == vanished } == false)
    }
}

// MARK: - Lazy PR fetching

@Suite("gh runs only for expanded repos plus the most recently active ones", .serialized)
struct RefreshCoordinatorLazyPullRequestTests {

    /// PLAN.md §3 and §7 `firstRefreshDoesNotIssueGhCallsForCollapsedRepos`. With
    /// `eagerPRRepoCount` at 0 the eager set is exactly the expanded repos, so branchbar gets its
    /// two `gh pr list` calls and the other two get none. The per-head cap is 0 so the count is
    /// the recent-100 list plus the author list and nothing else.
    @Test("firstRefreshDoesNotIssueGhCallsForCollapsedRepos")
    func firstRefreshDoesNotIssueGhCallsForCollapsedRepos() async throws {
        let cached = CacheFile(scan: scanResult(RepoStub.all, scannedAt: Date(timeIntervalSince1970: 1_788_399_000)))
        let harness = makeHarness(
            policy: RefreshPolicy(debounce: 0, overallDeadline: 30, eagerPRRepoCount: 0, perHeadFallbackCap: 0),
            cacheFile: cached)

        _ = await harness.coordinator.refresh(
            force: true, expandedRepoIDs: [RepoStub.branchbar.id], tools: healthyTools, onProgress: { _ in })

        #expect(harness.prListCalls(for: RepoStub.branchbar).count == 2)
        #expect(harness.prListCalls(for: RepoStub.personalAgent).isEmpty)
        #expect(harness.prListCalls(for: RepoStub.charlie).isEmpty)
    }

    /// PLAN.md §3 and §7 `eagerSetIncludesTopNMostRecentlyActive`. Nothing is expanded, the count is
    /// 2, and the previous snapshot orders the repos charlie, branchbar, hannah-personal-agent — so
    /// the two most recently active get `gh` and the third does not.
    @Test("eagerSetIncludesTopNMostRecentlyActive")
    func eagerSetIncludesTopNMostRecentlyActive() async throws {
        let previous = previousSnapshot(
            [
                (RepoStub.charlie, Date(timeIntervalSince1970: 1_788_390_000)),
                (RepoStub.branchbar, Date(timeIntervalSince1970: 1_788_380_000)),
                (RepoStub.personalAgent, Date(timeIntervalSince1970: 1_788_370_000)),
            ],
            refreshedAt: Date(timeIntervalSince1970: 1_788_399_000))
        let cached = CacheFile(
            scan: scanResult(RepoStub.all, scannedAt: Date(timeIntervalSince1970: 1_788_399_000)),
            lastSnapshot: previous)
        let harness = makeHarness(
            policy: RefreshPolicy(debounce: 0, overallDeadline: 30, eagerPRRepoCount: 2, perHeadFallbackCap: 0),
            cacheFile: cached)

        _ = await harness.coordinator.refresh(
            force: true, expandedRepoIDs: [], tools: healthyTools, onProgress: { _ in })

        #expect(harness.prListCalls(for: RepoStub.charlie).isEmpty == false)
        #expect(harness.prListCalls(for: RepoStub.branchbar).isEmpty == false)
        #expect(harness.prListCalls(for: RepoStub.personalAgent).isEmpty,
                "the third most recently active repo issued gh calls with eagerPRRepoCount 2")
    }

    /// PLAN.md §3 and §7 `refreshStillUpdatesGitStateWhenPRCacheIsWarm`: "a refresh always runs git
    /// for every repo (local, fast)". The PR cache is 60 s old against a 600 s TTL, so no
    /// `gh pr list` runs, and branchbar's branches still come back from git.
    @Test("refreshStillUpdatesGitStateWhenPRCacheIsWarm")
    func refreshStillUpdatesGitStateWhenPRCacheIsWarm() async throws {
        let now = Date(timeIntervalSince1970: 1_788_400_000)
        let cached = CacheFile(
            scan: scanResult(RepoStub.all, scannedAt: Date(timeIntervalSince1970: 1_788_399_000)),
            prCache: [RepoStub.branchbar.id: PRCacheEntry(fetchedAt: now.addingTimeInterval(-60))])
        let harness = makeHarness(
            policy: RefreshPolicy(debounce: 0, overallDeadline: 30, prCacheTTL: 600, eagerPRRepoCount: 0, perHeadFallbackCap: 0),
            cacheFile: cached,
            now: now)

        let snapshot = await harness.coordinator.refresh(
            force: true, expandedRepoIDs: [RepoStub.branchbar.id], tools: healthyTools, onProgress: { _ in })

        #expect(harness.prListCalls.isEmpty, "a warm PR cache still issued \(harness.prListCalls.count) gh pr list calls")
        let repo = try #require(snapshot.repos.first { $0.name == RepoStub.branchbar.name })
        #expect(repo.branches.count == 1)
        #expect(harness.gitCalls(for: RepoStub.branchbar).isEmpty == false)
    }
}

// MARK: - Isolation, persistence, and the missing-git case

@Suite("One repo's failure is contained, the result is persisted once, and no git never traps", .serialized)
struct RefreshCoordinatorIsolationTests {

    /// PLAN.md §7 `oneRepoFailingLeavesOthersPopulated`. hannah-personal-agent's
    /// `for-each-ref -- refs/heads` exits 128; it comes back with an error and no branches while the
    /// other two are fully populated.
    @Test("oneRepoFailingLeavesOthersPopulated")
    func oneRepoFailingLeavesOthersPopulated() async throws {
        let cached = CacheFile(scan: scanResult(RepoStub.all, scannedAt: Date(timeIntervalSince1970: 1_788_399_000)))
        let harness = makeHarness(
            policy: RefreshPolicy(debounce: 0, overallDeadline: 30, perHeadFallbackCap: 0),
            cacheFile: cached,
            failing: [RepoStub.personalAgent.path: [.heads]])

        let snapshot = await harness.coordinator.refresh(
            force: true, expandedRepoIDs: [], tools: healthyTools, onProgress: { _ in })

        #expect(snapshot.repos.count == 3)
        let failed = try #require(snapshot.repos.first { $0.name == RepoStub.personalAgent.name })
        #expect(failed.errors.isEmpty == false)
        #expect(failed.branches.isEmpty)

        let healthy = try #require(snapshot.repos.first { $0.name == RepoStub.branchbar.name })
        #expect(healthy.branches.count == 1)
        let alsoHealthy = try #require(snapshot.repos.first { $0.name == RepoStub.charlie.name })
        #expect(alsoHealthy.branches.count == 1)
    }

    /// PLAN.md §3 and §7 `snapshotIsPersistedAfterRefresh`: the cache is written **once**, at the
    /// end, not once per progressive emit, and what it holds is the snapshot that was returned.
    @Test("snapshotIsPersistedAfterRefresh")
    func snapshotIsPersistedAfterRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_788_400_000)
        let cached = CacheFile(scan: scanResult(RepoStub.all, scannedAt: Date(timeIntervalSince1970: 1_788_399_000)))
        let harness = makeHarness(
            policy: RefreshPolicy(debounce: 0, overallDeadline: 30, perHeadFallbackCap: 0),
            cacheFile: cached,
            now: now)

        let snapshot = await harness.coordinator.refresh(
            force: true, expandedRepoIDs: [], tools: healthyTools, onProgress: { _ in })

        #expect(harness.cache.saveCount == 1, "the cache was written \(harness.cache.saveCount) times")
        #expect(harness.cache.current?.lastSnapshot == snapshot)
        #expect(snapshot.refreshedAt == now)
        #expect(harness.cache.current?.schemaVersion == CacheFile.currentSchemaVersion)
    }

    /// PLAN.md §7 `missingGitFailsRefreshWithUserFacingFailureNotCrash`. The preflight found no git,
    /// so the refresh returns a snapshot carrying that `ToolStatus` and issues no command — the
    /// failure is reported, never a trap and never a hopeful `git` call against a nil path.
    @Test("missingGitFailsRefreshWithUserFacingFailureNotCrash")
    func missingGitFailsRefreshWithUserFacingFailureNotCrash() async throws {
        let cached = CacheFile(scan: scanResult(RepoStub.all, scannedAt: Date(timeIntervalSince1970: 1_788_399_000)))
        let harness = makeHarness(
            policy: RefreshPolicy(debounce: 0, overallDeadline: 30, perHeadFallbackCap: 0),
            cacheFile: cached)
        let noTools = ToolStatus()

        let snapshot = await harness.coordinator.refresh(
            force: true, expandedRepoIDs: [], tools: noTools, onProgress: { _ in })

        #expect(harness.runner.callCount == 0, "\(harness.runner.callCount) commands ran with no git on the machine")
        #expect(snapshot.tools == noTools)
    }
}
