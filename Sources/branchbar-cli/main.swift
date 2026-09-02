import BranchBarCore
import Foundation

// `branchbar-cli` — the Gate 3 harness, the Gate 0b fallback (PLAN.md §3, §8), and the app's
// discovery helper.
//
// Two subcommands. `snapshot` prints every repo, branch, worktree, PR and push as a table or as
// JSON. `scan` walks for repos and streams NDJSON as it goes; that is the subcommand the app
// spawns through `HelperProcessScanRunner`, and the reason it exists is that a walk blocked inside
// `open()`/`readdir()` cannot be cancelled but a process can be killed (codex round 2, BLOCKER 1).
// It streams rather than printing one document at the end because being killed is the *expected*
// ending: F10 found the helper parked in a TCC-gated listing on three consecutive launches, and
// every repo it had already found — all of them, since the gated folders go last — died with the
// process. `scripts/bundle.sh` copies this binary into `Contents/MacOS` beside the app's own.
//
// It is the same Core the menu bar app runs, with the real `ProcessCommandRunner`,
// `RealFileSystem`, and `FileCacheStore` behind it, so a table printed here and a popover drawn
// there are the same answer rendered twice. The only thing it does differently is its cache: a
// fresh temp directory by default, because a CLI run must never overwrite what the app is
// showing.
//
// `main.swift` is allowed for this target only (PLAN.md §5b bans it for the app, which has a
// `@main` App type; this target has none).

// MARK: - Options

extension String: @retroactive Error {}

enum Subcommand: String {
    case snapshot
    case scan
}

struct Options {
    var command: Subcommand = .snapshot
    var json = false
    var gitPath: String?
    var roots: [String] = []
    var cacheDirectory: String?
    /// `scan` only: the file holding the JSON-encoded `ScanPolicy` to walk under.
    var policyJSONPath: String?
    /// `scan` only: the walk's own cooperative bound, in seconds. The caller kills the process at
    /// a slightly later hard deadline; this is what gives a walk that *can* still answer the
    /// chance to print the repos it already found.
    var deadline: TimeInterval?
}

let usage = """
usage: branchbar-cli snapshot [--json] [--git PATH] [--root PATH]… [--cache-dir PATH]
       branchbar-cli scan --policy-json PATH [--deadline SECONDS] [--git PATH]

snapshot
  --json           print the Snapshot as JSON instead of a table
  --git PATH       git to run; overrides the BRANCHBAR_GIT environment variable
  --root PATH      folder to scan for repos; repeatable, defaults to the home folder
  --cache-dir PATH where to read and write the cache; defaults to a fresh temp directory,
                   so a CLI run never touches the app's cache

scan
  Prints NDJSON as it walks, one line per event, flushed as it goes: {"repo": …} the
  moment a repo is deduped, {"unreadable": path}, {"entering": path} before a folder
  macOS gates behind a consent dialog, {"skipped": {counters}} periodically, and a
  final {"result": ScanResult} when the walk finishes. A caller that kills this
  process keeps every line that had already arrived.

  --policy-json PATH  file holding the JSON-encoded ScanPolicy to walk under
  --deadline SECONDS  bound the walk and print what it found; the caller kills this
                      process at its own, later, hard deadline
  --git PATH          git to dedupe with; overrides BRANCHBAR_GIT
"""

func parse(_ arguments: [String]) -> Result<Options, String> {
    var arguments = arguments
    guard let name = arguments.first else { return .failure("no command given\n\n\(usage)") }
    guard let command = Subcommand(rawValue: name) else {
        return .failure("unknown command '\(name)'\n\n\(usage)")
    }
    arguments.removeFirst()

    var options = Options()
    options.command = command
    // The environment override comes first so an explicit `--git` still wins (PLAN.md §5's
    // `BRANCHBAR_GIT`, which is how Gate 3 pins the harness to `/usr/bin/git`).
    options.gitPath = ProcessInfo.processInfo.environment["BRANCHBAR_GIT"].flatMap {
        $0.isEmpty ? nil : $0
    }

    while let argument = arguments.first {
        arguments.removeFirst()
        func value(_ name: String) -> Result<String, String> {
            guard let next = arguments.first, !next.hasPrefix("--") else {
                return .failure("\(name) needs a path")
            }
            arguments.removeFirst()
            return .success(next)
        }

        switch argument {
        case "--json":
            options.json = true
        case "--git":
            switch value("--git") {
            case .success(let path): options.gitPath = path
            case .failure(let message): return .failure(message)
            }
        case "--root":
            switch value("--root") {
            case .success(let path): options.roots.append(absolute(path))
            case .failure(let message): return .failure(message)
            }
        case "--cache-dir":
            switch value("--cache-dir") {
            case .success(let path): options.cacheDirectory = absolute(path)
            case .failure(let message): return .failure(message)
            }
        case "--policy-json":
            switch value("--policy-json") {
            case .success(let path): options.policyJSONPath = absolute(path)
            case .failure(let message): return .failure(message)
            }
        case "--deadline":
            switch value("--deadline") {
            case .success(let seconds):
                guard let parsed = TimeInterval(seconds), parsed > 0 else {
                    return .failure("--deadline needs a positive number of seconds")
                }
                options.deadline = parsed
            case .failure: return .failure("--deadline needs a number of seconds")
            }
        case "-h", "--help":
            return .failure(usage)
        default:
            return .failure("unknown option '\(argument)'\n\n\(usage)")
        }
    }
    return .success(options)
}

func absolute(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    guard !expanded.hasPrefix("/") else { return (expanded as NSString).standardizingPath }
    let cwd = FileManager.default.currentDirectoryPath
    return ((cwd as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
}

func fail(_ message: String) -> Never {
    // Escaped for the same reason the table cells are: a failure message names the path that
    // failed, and the path belongs to whatever is on disk (codex round 2, MAJOR 10).
    FileHandle.standardError.write(Data((SafeText.escapingControlScalars(message) + "\n").utf8))
    exit(2)
}

// MARK: - Table

/// Left-aligned columns padded to the widest cell, which is all a hand-check needs.
///
/// The renderer lives in Core as `SafeText.table` because it escapes every cell and that rule has
/// to be testable (codex round 2, MAJOR 10): a repository owns its own directory and branch names,
/// and a name carrying a newline used to forge a table row while one carrying ESC could erase the
/// output already printed or retitle the terminal. Only this human-readable path escapes; `--json`
/// keeps exact values.
func table(_ header: [String], _ rows: [[String]]) -> String {
    SafeText.table(header: header, rows: rows)
}

/// Every human-readable line the CLI prints goes through here, for the same reason the table
/// cells do.
func say(_ text: String) {
    print(SafeText.escapingControlScalars(text))
}

// MARK: - Run

let options: Options
switch parse(Array(CommandLine.arguments.dropFirst())) {
case .success(let parsed): options = parsed
case .failure(let message): fail(message)
}

let runner = ProcessCommandRunner()
let fileSystem = RealFileSystem()
let locator = ToolLocator()

guard let gitPath = options.gitPath ?? locator.locate(.git).path else {
    fail("git not found. Searched: \(locator.locate(.git).searched.joined(separator: ", "))")
}

// MARK: - scan: the app's killable discovery helper

// codex round 2, BLOCKER 1. `RepoScanner` checks `Task.isCancelled` before each listing, which is
// the only place cancellation can land, so a walk already inside `open()`/`readdir()` — behind an
// unanswered TCC dialog, a stalled automount, a dead network volume — cannot be stopped by any
// deadline in the process running it. It can be stopped by killing the process, which is what the
// app does to this subcommand.
//
// Two bounds, and they answer different questions. `--deadline` is this process's own cooperative
// race: a walk that is merely slow, or blocked somewhere a cancellation check still follows, is
// cut at a directory boundary and the repos it already found are printed. The caller's hard
// deadline is a SIGTERM/SIGKILL a few hundred milliseconds later, for the case where nothing in
// user space can help.
if options.command == .scan {
    guard let policyPath = options.policyJSONPath else {
        fail("scan needs --policy-json PATH\n\n\(usage)")
    }
    guard
        let policyData = try? fileSystem.readBoundedRegularFile(
            path: policyPath, maxBytes: 1024 * 1024, tail: false),
        let requested = try? HelperProcessScanRunner.makeDecoder()
            .decode(ScanPolicy.self, from: policyData)
    else {
        fail("could not read a ScanPolicy from \(policyPath)")
    }

    // One line of NDJSON per event, written with a single `write(2)` and never buffered, because
    // the reader on the other end may only ever see what was flushed before this process is killed
    // (packet F11). `makeEncoder` is not pretty-printing, so each value is one line; a directory
    // name carrying a newline is JSON-escaped and stays on its line.
    let streamEncoder = HelperProcessScanRunner.makeEncoder()
    @Sendable func emit(_ line: ScanStreamLine) {
        guard var data = try? streamEncoder.encode(line) else { return }
        data.append(UInt8(ascii: "\n"))
        FileHandle.standardOutput.write(data)
    }

    let helperScanner = RepoScanner(
        fileSystem: fileSystem,
        commandRunner: runner,
        gitExecutable: gitPath,
        onProgress: { emit(ScanStreamLine($0)) })
    let softDeadline = options.deadline ?? RefreshPolicy.default.scanDeadline

    let scanned = await withTaskGroup(of: ScanResult?.self, returning: ScanResult.self) { group in
        group.addTask { try? await helperScanner.scan(policy: requested) }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(max(0, softDeadline) * 1_000_000_000))
            return nil
        }

        var found: ScanResult?
        for await outcome in group {
            group.cancelAll()
            // The deadline arrives as nil; the walk answers with what it has once its next
            // cancellation check lands, which is the partial result worth printing.
            if let outcome { found = outcome; break }
        }
        return found ?? HelperProcessScanRunner.truncatedResult(for: requested)
    }

    // The last line, and the one that says the walk finished. Without it the caller assembles the
    // repos it received and marks the result truncated, which is exactly right: a helper that was
    // killed never wrote this.
    emit(ScanStreamLine(result: scanned))
    exit(0)
}

// MARK: - snapshot

// codex round 3, MAJOR 1: `snapshot` walks in the same killable helper the app uses, and the
// helper it spawns is *this binary's* own `scan` subcommand.
//
// Until now the CLI built its coordinators without a `scanRunner`, so both fell back to
// `InProcessScanRunner`: the walk ran in this process, `scanWithinDeadline` raced it against a
// timer, and when the timer won it cancelled a task that was parked inside `open()`/`readdir()`
// and then waited for it. A TCC prompt nobody answered, a dead mount, or a stalled File Provider
// therefore hung the shipped CLI with no deadline able to end it — the same failure the app fixed
// in round 2 and the reason `scan` exists at all. A process can be killed; the runner's
// `Command.timeout` is `RefreshPolicy.scanDeadline`, which `ProcessCommandRunner` turns into
// SIGTERM then SIGKILL to the helper's process group.
//
// The child is resolved from the running executable rather than from a PATH lookup of
// `branchbar-cli`: `realpath` of `argv[0]` when that names a file, otherwise
// `Bundle.main.executableURL`. A copy installed elsewhere, or a different build earlier on PATH,
// is then not what answers.
func ownExecutablePath() -> String? {
    let manager = FileManager.default
    if let argv0 = CommandLine.arguments.first, !argv0.isEmpty,
       let resolved = realpath(argv0, nil) {
        defer { free(resolved) }
        let path = String(cString: resolved)
        if manager.isExecutableFile(atPath: path) { return path }
    }
    if let url = Bundle.main.executableURL {
        let path = url.resolvingSymlinksInPath().path
        if manager.isExecutableFile(atPath: path) { return path }
    }
    return nil
}

let ghPath = locator.locate(.gh).path

let policy = RefreshPolicy()
let gitVersion = try? await runner.run(
    Command(executable: gitPath, arguments: ["--version"], timeout: policy.gitTimeout)
).standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)

let tools = ToolStatus(gitPath: gitPath, gitVersion: gitVersion, ghPath: ghPath)

// codex round 3, MINOR 2: a `snapshot` run that was not given `--cache-dir` writes its cache into
// a UUID-named temporary directory, and nothing ever removed it — so every Gate 3 run, every
// headless fallback, and every `make snapshot` left a `cache.json` holding repository paths,
// branch names and PR metadata in `/var/folders/…` for the next person with that account.
//
// The removal is registered rather than written as a `defer`: top-level code in `main.swift` ends
// at `exit(_:)` on every path this file takes, and `exit` runs `atexit` handlers while skipping
// `defer` blocks entirely. A directory the user named with `--cache-dir` is theirs and is never
// touched.
enum TemporaryDirectories {
    /// Written before any concurrency starts and read from the exit handler; the directories are
    /// this process's own.
    nonisolated(unsafe) static var paths: [String] = []

    static func removeAll() {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
        paths = []
    }
}
atexit { TemporaryDirectories.removeAll() }

let cacheDirectory = options.cacheDirectory
    ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("branchbar-cli-\(UUID().uuidString)")
try? FileManager.default.createDirectory(
    atPath: cacheDirectory, withIntermediateDirectories: true)
if options.cacheDirectory == nil { TemporaryDirectories.paths.append(cacheDirectory) }
let cache = FileCacheStore(
    fileURL: URL(fileURLWithPath: (cacheDirectory as NSString).appendingPathComponent("cache.json")))

let roots = options.roots.isEmpty ? [fileSystem.homeDirectory()] : options.roots
let scanPolicy = ScanPolicy(homeRoot: roots[0], extraRoots: Array(roots.dropFirst()))
let scanner = RepoScanner(fileSystem: fileSystem, commandRunner: runner, gitExecutable: gitPath)

// One CLI run is one whole answer, so every repo it finds is treated as expanded and its PRs are
// fetched — which means the repo IDs have to be known before the refresh that fetches them starts.
//
// Packet 4.3: that used to be a bare `scanner.scan`, run ahead of the coordinator and therefore
// outside `RefreshPolicy.scanDeadline`, so the CLI could hang exactly where packet 4.1's first
// launch did — inside the walk, behind a folder macOS had not been given permission to read, with
// nothing able to end it. The walk now runs where the app's does: inside a `RefreshCoordinator`,
// wired the way `AppModel` wires one, whose `scanWithinDeadline` bounds it and hands back what it
// found.
//
// The discovery coordinator is a second one, with its own throwaway cache, for two reasons. A
// refresh always persists its snapshot, and a snapshot in the cache the real refresh reads would
// become that refresh's "previous" — which is what decides repo order, so the table would reorder
// itself between runs. And its loader is wired to a runner that launches nothing, so discovering
// the repos costs one walk rather than a second pass of git over every repo it finds.

/// A `CommandRunner` that answers every command with an empty success. The discovery pass wants
/// the coordinator's scan and nothing else; the repos it walks past are loaded again, for real, by
/// the refresh below.
struct NoCommandsRunner: CommandRunner {
    func run(_ command: Command) async throws -> CommandOutput {
        CommandOutput(exitCode: 0, standardOutput: Data(), standardError: Data())
    }
}

let discoveryDirectory = (NSTemporaryDirectory() as NSString)
    .appendingPathComponent("branchbar-cli-scan-\(UUID().uuidString)")
try? FileManager.default.createDirectory(
    atPath: discoveryDirectory, withIntermediateDirectories: true)
// Removed below on the path that reaches it, and at exit on the paths that do not (MINOR 2).
TemporaryDirectories.paths.append(discoveryDirectory)
let discoveryCache = FileCacheStore(
    fileURL: URL(
        fileURLWithPath: (discoveryDirectory as NSString).appendingPathComponent("cache.json")))
let silentRunner = NoCommandsRunner()

/// The walk runs where a deadline can reach it: a child process this one can kill (MAJOR 1).
/// Without an own-executable path — which should not happen for a binary that is running — the
/// in-process walk is what is left, and stderr says so rather than the table.
let scanRunner: any ScanRunning
if let helper = ownExecutablePath() {
    scanRunner = HelperProcessScanRunner(
        helperExecutable: helper,
        runner: runner,
        scanDeadline: policy.scanDeadline,
        gitExecutable: gitPath)
} else {
    scanRunner = InProcessScanRunner(scanner: scanner)
    FileHandle.standardError.write(Data(
        "branchbar-cli: could not resolve this executable, so the scan runs in-process\n".utf8))
}

let discovery = RefreshCoordinator(
    scanner: scanner,
    loader: RepoLoader(
        git: GitClient(runner: silentRunner, gitPath: gitPath, timeout: policy.gitTimeout),
        gh: nil,
        reflog: ReflogFileReader(fileSystem: fileSystem),
        policy: policy),
    cache: discoveryCache,
    policy: policy,
    scanPolicy: scanPolicy,
    fileSystem: fileSystem,
    scanRunner: scanRunner)

_ = await discovery.refresh(
    force: true,
    expandedRepoIDs: [],
    tools: tools,
    onProgress: { _ in },
    rescan: true)

guard let scan = ((try? discoveryCache.load()) ?? nil)?.scan else {
    fail("scan failed: the discovery refresh recorded no scan under \(scanPolicy.homeRoot)")
}
try? FileManager.default.removeItem(atPath: discoveryDirectory)
try? cache.save(CacheFile(scan: scan))

// `runner` and `gitPath` switch the per-remote owner lookup on: without them `RepoLoader` skips
// `config --get remote.<name>.url` and every branch is attributed to the origin repository's owner,
// so a branch tracking a fork is matched against a head that only shares its name (codex round 2,
// MAJOR 4). The discovery loader above stays without them on purpose — it is wired to a runner that
// launches nothing, and its only job is the walk.
let loader = RepoLoader(
    git: GitClient(runner: runner, gitPath: gitPath, timeout: policy.gitTimeout),
    gh: ghPath.map { GHClient(runner: runner, ghPath: $0, policy: policy) },
    reflog: ReflogFileReader(fileSystem: fileSystem),
    policy: policy,
    runner: runner,
    gitPath: gitPath)

let coordinator = RefreshCoordinator(
    scanner: scanner,
    loader: loader,
    cache: cache,
    policy: policy,
    scanPolicy: scanPolicy,
    fileSystem: fileSystem,
    // The refresh rescans when the discovery pass came back truncated, so its walk needs the same
    // killable process the discovery walk had.
    scanRunner: scanRunner)

let snapshot = await coordinator.refresh(
    force: true,
    expandedRepoIDs: Set(scan.repos.map(\.id)),
    tools: tools,
    onProgress: { _ in })

if options.json {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(snapshot) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
        fail("could not encode the snapshot as JSON")
    }
    exit(0)
}

// The refresh rescans when the discovery pass was cut short by `scanDeadline`, so the scan the
// table describes is read back the way `AppModel.reloadScanFromCache` reads it: whatever the
// refresh actually used. Identical to `scan` on any run the deadline did not fire on.
let finalScan = ((try? cache.load()) ?? nil)?.scan ?? scan

let presenter = SnapshotPresenter()
let viewModel = presenter.present(
    snapshot,
    refreshState: .idle(lastRefreshedAt: snapshot.refreshedAt),
    collapsedRepoIDs: [],
    scanResult: finalScan,
    appVersion: "cli",
    now: Date())

var rows: [[String]] = []
for (section, repo) in zip(viewModel.sections, snapshot.repos) {
    let worktreeByBranch = Dictionary(
        repo.branches.map { ($0.name, $0.worktreePath) }, uniquingKeysWith: { first, _ in first })
    for row in section.active + section.merged + section.closedUnmerged {
        rows.append([
            repo.name,
            row.title,
            worktreeByBranch[row.title].flatMap { $0 } ?? "—",
            row.prPill?.text ?? "—",
            row.pushLabel,
            row.aheadLabel ?? "—",
        ])
    }
}

print(table(["REPO", "BRANCH", "WORKTREE", "PR", "PUSH", "AHEAD"], rows))
print("")
say("\(viewModel.footer.updatedLabel) · \(snapshot.repos.count) repo(s) · \(rows.count) branch row(s)")
if let notice = viewModel.footer.toolNotice {
    say(notice.text)
}
for repo in snapshot.repos where !repo.errors.isEmpty {
    for error in repo.errors {
        say("\(repo.name): \(error.stage.rawValue): \(error.message)")
    }
}
exit(0)
