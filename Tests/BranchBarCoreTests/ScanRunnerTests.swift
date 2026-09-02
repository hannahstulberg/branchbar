import Foundation
import Testing

@testable import BranchBarCore

// Packet F6 — codex round 2, BLOCKER 1: "The scan deadline still cannot stop the production hang."
//
// `RefreshCoordinator.scanWithinDeadline` raced `RepoScanner` against a timer and, when the timer
// won, called `group.cancelAll()` and kept waiting. `RepoScanner` checks `Task.isCancelled` before
// each listing, which is the only place cancellation can land; a task already inside
// `open()`/`readdir()` never reaches it. The review's own words: "The test double masks this …
// The kernel does not."
//
// The fix is a seam. `ScanRunning` says "hand me a ScanResult" without saying where the walk runs;
// `InProcessScanRunner` is what every unit test and the CLI's own `scan` subcommand use, and
// `HelperProcessScanRunner` runs the walk in the `branchbar-cli` helper, where the deadline is a
// SIGTERM/SIGKILL to a process group rather than a cancellation flag a blocked thread will never
// read.

/// A `ScanRunning` that answers with a canned result and records what it was asked for.
private final class StubScanRunner: ScanRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _policies: [ScanPolicy] = []
    private let result: ScanResult

    init(result: ScanResult) { self.result = result }

    var policies: [ScanPolicy] {
        lock.lock(); defer { lock.unlock() }
        return _policies
    }

    func scan(policy: ScanPolicy) async throws -> ScanResult {
        record(policy)
        return result
    }

    private func record(_ policy: ScanPolicy) {
        lock.lock(); _policies.append(policy); lock.unlock()
    }
}

/// A scratch directory holding an executable stand-in for `branchbar-cli`.
private struct HelperScript {
    let directory: Packet25TempDir
    let url: URL

    init(_ body: String) throws {
        directory = try Packet25TempDir()
        url = directory.file("branchbar-cli")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func remove() { directory.remove() }
}

@Suite("The scan runs behind a seam, and the helper implementation is killable")
struct ScanRunnerTests {

    private static let policy = ScanPolicy(homeRoot: "/Users/tester", extraRoots: ["/Volumes/Work"])

    /// The in-process runner is the plain adapter: same walk, same result, no process.
    @Test("inProcessScanRunnerWrapsRepoScanner")
    func inProcessScanRunnerWrapsRepoScanner() async throws {
        let fileSystem = InMemoryFileSystem(home: "/Users/tester")
        fileSystem.addRepository(at: "/Users/tester/alpha")

        let runner = InProcessScanRunner(scanner: RepoScanner(fileSystem: fileSystem))
        let result = try await runner.scan(policy: ScanPolicy(homeRoot: "/Users/tester"))

        #expect(result.repos.map(\.path) == ["/Users/tester/alpha"])
        #expect(!result.truncatedByDeadline)
    }

    /// codex BLOCKER 1. The helper is spawned with the frozen argument shape, the policy travels
    /// as JSON in a temp file, and the `ScanResult` it prints comes back byte-identical through
    /// the shared encoder and decoder — dates included, which is why both sides use `.iso8601`.
    @Test("helperScanResultRoundTripsThroughJSON")
    func helperScanResultRoundTripsThroughJSON() async throws {
        let expected = ScanResult(
            policy: Self.policy,
            scannedAt: Date(timeIntervalSince1970: 1_788_400_000),
            repos: [
                DiscoveredRepo(path: "/Users/tester/alpha", id: RepoID(commonDir: "/Users/tester/alpha/.git")),
                DiscoveredRepo(path: "/Users/tester/beta", id: RepoID(commonDir: "/Users/tester/beta/.git")),
            ],
            candidatesExamined: 12,
            unreadableDirectories: ["/Users/tester/Documents"],
            depthCutDirectories: 3,
            skippedHiddenDirectories: 40,
            skippedWorktreeCheckouts: ["/Users/tester/wt"],
            skippedSubmodules: ["/Users/tester/sub"],
            truncatedByDeadline: false)

        let payload = try Packet25TempDir()
        defer { payload.remove() }
        let resultFile = payload.file("result.json")
        try HelperProcessScanRunner.makeEncoder().encode(expected).write(to: resultFile)
        let argumentsFile = payload.file("argv.txt")

        let helper = try HelperScript(
            "printf '%s\\n' \"$@\" > '\(argumentsFile.path)'\ncat '\(resultFile.path)'")
        defer { helper.remove() }

        let runner = HelperProcessScanRunner(
            helperExecutable: helper.url.path,
            runner: ProcessCommandRunner(),
            scanDeadline: 20)
        let result = try await runner.scan(policy: Self.policy)

        #expect(result == expected)

        // The frozen shape: `scan --policy-json <tmpfile> --json`, plus the soft deadline the
        // helper enforces on its own walk.
        let argv = try String(contentsOf: argumentsFile, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
        #expect(argv.first == "scan")
        #expect(argv.contains("--json"))
        let policyIndex = try #require(argv.firstIndex(of: "--policy-json"))
        let deadlineIndex = try #require(argv.firstIndex(of: "--deadline"))
        #expect(Double(argv[deadlineIndex + 1]) ?? 0 > 0)
        #expect(Double(argv[deadlineIndex + 1]) ?? 0 < 20,
                "the helper's own bound must fire before the process is killed")

        // The policy really travelled as JSON, and the runner cleans the file up afterwards.
        #expect(!FileManager.default.fileExists(atPath: argv[policyIndex + 1]),
                "the policy file outlived the run")
    }

    /// codex BLOCKER 1, the whole point: a helper that never answers is **killed**, and the caller
    /// gets a truncated result rather than waiting forever. The script sleeps, which is the only
    /// honest stand-in for a listing stuck inside `open()` — a cancellation flag would not reach
    /// it either.
    @Test("helperScanIsKilledAtTheDeadlineAndYieldsATruncatedResult")
    func helperScanIsKilledAtTheDeadlineAndYieldsATruncatedResult() async throws {
        let pidDirectory = try Packet25TempDir()
        defer { pidDirectory.remove() }
        let pidFile = pidDirectory.file("helper.pid").path

        let helper = try HelperScript("echo $$ > '\(pidFile)'\nexec sleep 60")
        defer { helper.remove() }

        let runner = HelperProcessScanRunner(
            helperExecutable: helper.url.path,
            runner: ProcessCommandRunner(),
            scanDeadline: 0.5)

        let started = Date()
        let result = try await runner.scan(policy: Self.policy)
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 15, "the deadline did not end the helper: \(elapsed) s")
        #expect(result.truncatedByDeadline, "a killed scan must not read as a finished one")
        #expect(result.repos.isEmpty)
        #expect(result.policy == Self.policy)

        // The process is gone, not merely abandoned: an abandoned child holds the pipes open and
        // keeps doing whatever blocked it.
        let pid = try #require(Int32(
            (try String(contentsOfFile: pidFile, encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        var gone = false
        for _ in 0..<600 where !gone {
            if kill(pid, 0) != 0 { gone = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(gone, "helper pid \(pid) survived its deadline")
    }

    /// A helper that exits 0 and prints something this side cannot read is a broken helper, not a
    /// finished scan: saying "truncated" keeps the coordinator rescanning instead of freezing an
    /// empty repo list into the cache for a week.
    @Test("helperOutputThatDoesNotDecodeReadsAsTruncated")
    func helperOutputThatDoesNotDecodeReadsAsTruncated() async throws {
        let helper = try HelperScript("printf 'not json'")
        defer { helper.remove() }

        let result = try await HelperProcessScanRunner(
            helperExecutable: helper.url.path, scanDeadline: 10).scan(policy: Self.policy)

        #expect(result.truncatedByDeadline)
        #expect(result.repos.isEmpty)
    }

    /// A non-zero exit is a failure the caller must see, not an empty scan it would persist.
    @Test("helperNonZeroExitThrows")
    func helperNonZeroExitThrows() async throws {
        let helper = try HelperScript("printf 'boom\\n' >&2\nexit 3")
        defer { helper.remove() }

        let runner = HelperProcessScanRunner(helperExecutable: helper.url.path, scanDeadline: 10)
        await #expect(throws: CommandError.self) { _ = try await runner.scan(policy: Self.policy) }
    }

    /// The resolver looks beside the **running executable**, never beside `Bundle.main.bundlePath`:
    /// a quarantined copy is app-translocated and the bundle path is a mirror (ARCHITECTURE.md §8).
    @Test("helperExecutableIsResolvedBesideTheRunningExecutable")
    func helperExecutableIsResolvedBesideTheRunningExecutable() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }

        let app = temp.file("BranchBar")
        try Data("#!/bin/sh\n".utf8).write(to: app)
        #expect(HelperProcessScanRunner.helperExecutableURL(besideExecutableAt: app) == nil,
                "no helper beside the executable means no helper")

        let helper = temp.file(HelperProcessScanRunner.helperExecutableName)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        #expect(HelperProcessScanRunner.helperExecutableURL(besideExecutableAt: app)?.path == helper.path)
        #expect(HelperProcessScanRunner.helperExecutableURL(besideExecutableAt: nil) == nil)
    }
}

@Suite("The coordinator discovers repos through the injected runner", .serialized)
struct CoordinatorScanRunnerTests {

    /// codex BLOCKER 1, the coordinator half: discovery goes through `ScanRunning`, so the shell
    /// can hand it the killable helper without the coordinator knowing the difference. The stub
    /// names a repo the in-memory tree does not hold, which no in-process walk could invent.
    @Test("coordinatorUsesTheInjectedScanRunner")
    func coordinatorUsesTheInjectedScanRunner() async throws {
        let fileSystem = InMemoryFileSystem(home: "/Users/tester")
        fileSystem.addRepository(at: "/Users/tester/never-walked")

        let helperOnly = DiscoveredRepo(
            path: "/Users/tester/from-the-helper",
            id: RepoID(commonDir: "/Users/tester/from-the-helper/.git"))
        let stub = StubScanRunner(result: ScanResult(
            policy: ScanPolicy(homeRoot: "/Users/tester"),
            scannedAt: Date(timeIntervalSince1970: 1_788_400_000),
            repos: [helperOnly],
            candidatesExamined: 1))

        let runner = RecordedCommandRunner()
        for arguments in [
            ["-C", helperOnly.path, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            ["-C", helperOnly.path, "rev-parse", "--path-format=absolute", "--show-toplevel"],
            ["-C", helperOnly.path, "config", "--get", "remote.origin.url"],
            ["-C", helperOnly.path, "for-each-ref", GitClient.headsFormat, "--", "refs/heads"],
            ["-C", helperOnly.path, "for-each-ref", GitClient.remotesFormat, "--", "refs/remotes/"],
            ["-C", helperOnly.path, "worktree", "list", "--porcelain", "-z"],
        ] {
            runner.stubGit(arguments, stdout: "")
        }

        let policy = RefreshPolicy(debounce: 0, overallDeadline: 30, perHeadFallbackCap: 0)
        let coordinator = RefreshCoordinator(
            scanner: RepoScanner(fileSystem: fileSystem),
            loader: RepoLoader(
                git: GitClient(runner: runner, gitPath: "/usr/bin/git"),
                gh: nil,
                reflog: ReflogFileReader(fileSystem: fileSystem),
                policy: policy),
            cache: InMemoryCacheStore(initial: CacheFile()),
            policy: policy,
            scanPolicy: ScanPolicy(homeRoot: "/Users/tester"),
            fileSystem: fileSystem,
            scanRunner: stub)

        let snapshot = await coordinator.refresh(
            force: true,
            expandedRepoIDs: [],
            tools: ToolStatus(gitPath: "/usr/bin/git", gitVersion: "git version 2.39.5", ghPath: nil),
            onProgress: { _ in })

        #expect(stub.policies.count == 1)
        #expect(stub.policies.first?.homeRoot == "/Users/tester")
        #expect(snapshot.repos.map(\.path) == [helperOnly.path],
                "the coordinator walked the tree itself instead of asking the injected runner")
    }
}
