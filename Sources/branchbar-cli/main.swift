import BranchBarCore
import Foundation

// `branchbar-cli snapshot` — the Gate 3 harness and the Gate 0b fallback (PLAN.md §3, §8).
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

struct Options {
    var json = false
    var gitPath: String?
    var roots: [String] = []
    var cacheDirectory: String?
}

let usage = """
usage: branchbar-cli snapshot [--json] [--git PATH] [--root PATH]… [--cache-dir PATH]

  --json           print the Snapshot as JSON instead of a table
  --git PATH       git to run; overrides the BRANCHBAR_GIT environment variable
  --root PATH      folder to scan for repos; repeatable, defaults to the home folder
  --cache-dir PATH where to read and write the cache; defaults to a fresh temp directory,
                   so a CLI run never touches the app's cache
"""

func parse(_ arguments: [String]) -> Result<Options, String> {
    var arguments = arguments
    guard let command = arguments.first else { return .failure("no command given\n\n\(usage)") }
    guard command == "snapshot" else { return .failure("unknown command '\(command)'\n\n\(usage)") }
    arguments.removeFirst()

    var options = Options()
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
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

// MARK: - Table

/// Left-aligned columns padded to the widest cell, which is all a hand-check needs.
func table(_ header: [String], _ rows: [[String]]) -> String {
    let all = [header] + rows
    let columns = header.count
    var widths = [Int](repeating: 0, count: columns)
    for row in all {
        for index in 0..<columns {
            widths[index] = max(widths[index], row[index].count)
        }
    }
    func render(_ row: [String]) -> String {
        (0..<columns)
            .map { index in
                index == columns - 1
                    ? row[index]
                    : row[index].padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }
            .joined(separator: "  ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }
    return ([render(header), render(widths.map { String(repeating: "-", count: $0) })]
        + rows.map(render)).joined(separator: "\n")
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
let ghPath = locator.locate(.gh).path

let policy = RefreshPolicy()
let gitVersion = try? await runner.run(
    Command(executable: gitPath, arguments: ["--version"], timeout: policy.gitTimeout)
).standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)

let tools = ToolStatus(gitPath: gitPath, gitVersion: gitVersion, ghPath: ghPath)

let cacheDirectory = options.cacheDirectory
    ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("branchbar-cli-\(UUID().uuidString)")
try? FileManager.default.createDirectory(
    atPath: cacheDirectory, withIntermediateDirectories: true)
let cache = FileCacheStore(
    fileURL: URL(fileURLWithPath: (cacheDirectory as NSString).appendingPathComponent("cache.json")))

let roots = options.roots.isEmpty ? [fileSystem.homeDirectory()] : options.roots
let scanPolicy = ScanPolicy(homeRoot: roots[0], extraRoots: Array(roots.dropFirst()))
let scanner = RepoScanner(fileSystem: fileSystem, commandRunner: runner, gitExecutable: gitPath)

// One CLI run is one whole answer, so every repo it finds is treated as expanded and its PRs are
// fetched. The scan is done here rather than left to the coordinator so the repo IDs are known
// before the refresh starts; seeding the cache with it means the coordinator reuses it instead of
// walking the tree a second time.
let scan: ScanResult
do {
    scan = try await scanner.scan(policy: scanPolicy)
} catch {
    fail("scan failed: \(error)")
}
try? cache.save(CacheFile(scan: scan))

let loader = RepoLoader(
    git: GitClient(runner: runner, gitPath: gitPath, timeout: policy.gitTimeout),
    gh: ghPath.map { GHClient(runner: runner, ghPath: $0, policy: policy) },
    reflog: ReflogFileReader(fileSystem: fileSystem),
    policy: policy)

let coordinator = RefreshCoordinator(
    scanner: scanner,
    loader: loader,
    cache: cache,
    policy: policy,
    scanPolicy: scanPolicy,
    fileSystem: fileSystem)

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

let presenter = SnapshotPresenter()
let viewModel = presenter.present(
    snapshot,
    refreshState: .idle(lastRefreshedAt: snapshot.refreshedAt),
    collapsedRepoIDs: [],
    scanResult: scan,
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
print("\(viewModel.footer.updatedLabel) · \(snapshot.repos.count) repo(s) · \(rows.count) branch row(s)")
if let notice = viewModel.footer.toolNotice {
    print(notice.text)
}
for repo in snapshot.repos where !repo.errors.isEmpty {
    for error in repo.errors {
        print("\(repo.name): \(error.stage.rawValue): \(error.message)")
    }
}
exit(0)
