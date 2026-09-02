import Foundation

/// Finds repos. PLAN.md §3: the home root is walked breadth-first to depth 6 skipping every
/// hidden directory and the literal skip list; "Add folder…" roots are walked **recursively with
/// no depth limit** so a deep repo, a `~/Library/CloudStorage` folder, or a nested repo inside a
/// monorepo is reachable by adding it. Symlinks are not followed and bare repos are out of scope.
///
/// **What the scan deadline can and cannot stop** (codex BLOCKER 2). The walk checks
/// `Task.isCancelled` once per directory, *before* the listing that can block, so a cancelled
/// scan stops at a directory boundary and hands back the repos it already found. It cannot stop
/// a listing that is already inside `open()`/`readdir()`: those are synchronous kernel calls,
/// and a task blocked in one never reaches a cancellation check, so `RefreshCoordinator`'s
/// `scanDeadline` bounds *when the refresh continues*, not when that call returns. The
/// mitigation is ordering, not cancellation: `tccGatedFolderNames` are enumerated after every
/// other directory the walk will ever open (`tccGatedFoldersAreEnumeratedLast`), so a pending
/// consent dialog — the one blocking listing this app actually meets — can only ever hold the
/// tail of the scan, with every repo outside those three folders already found and already in
/// the result. `RealFileSystem` no longer stats symlink targets for the same reason: that was
/// the other call an unreachable mount could block, and it answered a question the walk does not
/// ask. A hard bound on an arbitrary blocking listing needs a killable helper process, which is
/// what `HelperProcessScanRunner` and `branchbar-cli scan` are.
///
/// **Why the walk narrates itself** (packet F11). Ordering was not enough. F10 watched the shipped
/// helper park in `open()` inside a gated folder on three consecutive launches, get killed, and
/// deliver nothing — every repo on the machine found and none of them published, because
/// publishing happened only in the value the walk returned and a killed process returns nothing.
/// `onProgress` reports each repo the moment the dedupe claims it, so the helper can put it on
/// stdout while there is still a process to kill, and the folder it announced entering is what the
/// caller reports as "not scanned".
/// What a walk in progress can say about itself, before it has a `ScanResult` to hand back.
///
/// Packet F11. The `branchbar-cli scan` helper is killed from outside when a listing blocks in the
/// kernel, and until F11 everything it had found died with it: the walk's only output was a
/// `ScanResult` returned at the end, and a process that is killed never reaches its end. These
/// events are the same walk narrating itself, so the helper can put a repo on stdout the moment it
/// is deduped and the caller keeps whatever arrived before the kill.
///
/// `InProcessScanRunner` passes no callback and is unaffected: the app's in-process walk still
/// hands back one value.
public enum ScanEvent: Hashable, Sendable {
    /// A repo, at the moment the dedupe claimed its common directory. A later candidate whose
    /// `.git` is a real directory can still win the same key, which emits the repo a second time
    /// with the corrected working-tree path; a consumer keys on `id` and keeps the last.
    case repo(DiscoveredRepo)
    /// A directory the walk could not read, or was cut off before reading. Same fact
    /// `ScanResult.unreadableDirectories` carries, at the moment it is learned.
    case unreadable(String)
    /// About to list a folder macOS gates behind a consent dialog. Emitted **before** the call,
    /// because a listing that never returns runs nothing after it: this line is the only record
    /// that the walk was inside `Documents` when the process was killed.
    case entering(String)
    /// The running totals, emitted periodically and once at the end of each root.
    case skipped(ScanCounters)
}

/// The counting half of a `ScanResult`, so a stream can carry the totals without repeating the
/// paths it has already sent.
public struct ScanCounters: Hashable, Codable, Sendable {
    public var candidatesExamined: Int
    public var depthCutDirectories: Int
    public var skippedHiddenDirectories: Int
    public var skippedWorktreeCheckouts: Int
    public var skippedSubmodules: Int

    public init(
        candidatesExamined: Int = 0,
        depthCutDirectories: Int = 0,
        skippedHiddenDirectories: Int = 0,
        skippedWorktreeCheckouts: Int = 0,
        skippedSubmodules: Int = 0
    ) {
        self.candidatesExamined = candidatesExamined
        self.depthCutDirectories = depthCutDirectories
        self.skippedHiddenDirectories = skippedHiddenDirectories
        self.skippedWorktreeCheckouts = skippedWorktreeCheckouts
        self.skippedSubmodules = skippedSubmodules
    }
}

public struct RepoScanner: Sendable {
    private let fileSystem: FileSystem
    /// Optional on purpose: the dedupe key is `git rev-parse --path-format=absolute
    /// --git-common-dir --show-toplevel` when a runner is available, and the `.git` directory
    /// path (or the `gitdir:` line) when one is not, so a unit test can scan a tree without a
    /// process seam and still get one repo per common directory.
    private let commandRunner: CommandRunner?
    private let gitExecutable: String
    /// Called as the walk learns things, on whatever task is running it, before `scan` returns
    /// (packet F11). Defaulted nil: the in-process runner and every unit test that does not name
    /// it get exactly the walk they had. `branchbar-cli scan` passes one and turns each event into
    /// a line of NDJSON, which is how a killed helper still delivers the repos it found.
    private let onProgress: (@Sendable (ScanEvent) -> Void)?

    public init(
        fileSystem: FileSystem,
        commandRunner: CommandRunner? = nil,
        gitExecutable: String = "/usr/bin/git",
        onProgress: (@Sendable (ScanEvent) -> Void)? = nil
    ) {
        self.fileSystem = fileSystem
        self.commandRunner = commandRunner
        self.gitExecutable = gitExecutable
        self.onProgress = onProgress
    }

    /// Directories listed between two `skipped` events. Small enough that a walk cut short has
    /// recent totals, large enough that the helper is not writing a line per directory.
    private static let counterReportInterval = 25

    /// Directories one "Add folder…" root may cost before the walk stops and says the root is
    /// incomplete (codex round 3, MAJOR 8).
    ///
    /// An extra root is walked with **no depth limit** by design, which is what makes a repo eight
    /// folders down reachable — and what makes a root somebody put at `/` or on a huge mounted
    /// volume an unbounded walk that the scan deadline kills, every refresh, with a partial list
    /// each time and nothing on screen saying why. The budget makes that case finite and visible:
    /// the root joins the "not scanned" list and the result is truncated, so the notice appears
    /// and the next refresh rescans.
    public static let extraRootCandidateBudget = 10_000

    /// Walks `policy.homeRoot` breadth-first to `policy.maxDepth` and every `policy.extraRoots`
    /// entry with no depth limit, in both cases skipping hidden directories and
    /// `policy.skipDirectoryNames`, never following symlinks, never descending into a directory
    /// that already yielded a repo, classifying a `.git` **file** by its `gitdir:` line into a
    /// worktree checkout or a submodule and excluding both, deduping the survivors by the `.git`
    /// common directory, and returning a `ScanResult` that counts every directory examined, every
    /// unreadable directory by path, every depth cut, and every hidden skip.
    public func scan(policy: ScanPolicy) async throws -> ScanResult {
        let scannedAt = Date()
        var accumulator = Walk()

        accumulator = await walk(
            root: policy.homeRoot,
            maxDepth: policy.maxDepth,
            policy: policy,
            deferTCCGatedFolders: true,
            descendIntoRootRepo: true,
            // codex round 3, MAJOR 2: the home root itself and everything directly under it, so a
            // helper killed inside an ordinary folder still leaves the line that names it.
            announceDepth: 1,
            candidateBudget: nil,
            into: accumulator)
        for root in policy.extraRoots where !accumulator.truncated {
            accumulator = await walk(
                root: root,
                maxDepth: nil,
                policy: policy,
                deferTCCGatedFolders: false,
                descendIntoRootRepo: false,
                announceDepth: 0,
                candidateBudget: Self.extraRootCandidateBudget,
                into: accumulator)
        }

        return ScanResult(
            policy: policy,
            scannedAt: scannedAt,
            repos: accumulator.resolvedRepos,
            candidatesExamined: accumulator.candidatesExamined,
            unreadableDirectories: accumulator.unreadableDirectories,
            depthCutDirectories: accumulator.depthCutDirectories,
            skippedHiddenDirectories: accumulator.skippedHiddenDirectories,
            skippedWorktreeCheckouts: accumulator.skippedWorktreeCheckouts,
            skippedSubmodules: accumulator.skippedSubmodules,
            truncatedByDeadline: accumulator.truncated
        )
    }

    /// The three folders under the home root macOS gates behind a consent dialog. The walk opens
    /// them **after** every other directory it will ever open, so a dialog the user has not
    /// answered can only block the tail of the scan: every repo outside them is already found and
    /// already in the result (`tccGatedFoldersAreEnumeratedLast`). The rule is about these three
    /// folders as children of the home root, not about the words — a `Documents` deeper in the
    /// tree, or one inside a folder the user added through "Add folder…", is walked in turn,
    /// because the panel already granted it and there is no dialog left to wait for.
    public static let tccGatedFolderNames = ["Desktop", "Documents", "Downloads"]

    /// Reads a `.git` file's `gitdir: <path>` line and classifies the checkout: a path inside
    /// `…/.git/worktrees/` is a linked worktree whose **common directory** is everything before
    /// `/worktrees/`, one inside `…/.git/modules/` is a submodule, anything else (a
    /// `--separate-git-dir` repo) is a candidate whose common dir is the path on the line.
    public static func classifyGitFile(contents: String) -> GitFileClassification {
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix(Self.gitdirPrefix) else { continue }
            let gitDirectory = String(line.dropFirst(Self.gitdirPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !gitDirectory.isEmpty else { return .unrecognized }

            if let marker = gitDirectory.range(of: Self.worktreesMarker, options: .backwards) {
                // `<common>/.git/worktrees/<name>` — the common directory is the main repo's
                // `.git`, which is also the dedupe key the checkout would otherwise collide on.
                let commonDirectory = String(gitDirectory[gitDirectory.startIndex..<marker.lowerBound]) + "/.git"
                return .worktreeCheckout(commonDirectory: commonDirectory)
            }
            if gitDirectory.range(of: Self.modulesMarker, options: .backwards) != nil {
                return .submodule(gitDirectory: gitDirectory)
            }
            return .candidate(gitDirectory: gitDirectory)
        }
        return .unrecognized
    }

    /// A `.git` file holds one short `gitdir:` line. Only this many bytes are read (codex
    /// MAJOR 15), so a repo carrying a gigabyte marker cannot be read into memory by the scan.
    public static let maximumGitFileBytes = 4096

    private static let gitdirPrefix = "gitdir:"
    private static let worktreesMarker = "/.git/worktrees/"
    private static let modulesMarker = "/.git/modules/"

    public enum GitFileClassification: Hashable, Codable, Sendable {
        case worktreeCheckout(commonDirectory: String)
        case submodule(gitDirectory: String)
        case candidate(gitDirectory: String)
        case unrecognized
    }

    // MARK: - Traversal

    /// A directory that carried a repo marker, before any git command has run against it.
    private struct Candidate {
        var path: String
        /// The common directory the filesystem alone can tell us: `<path>/.git` for a marker
        /// directory, the `gitdir:` line for a `.git` file.
        var commonDirectoryHint: String
        /// `.git` is a real directory here, which is what breaks a dedupe tie.
        var gitIsDirectory: Bool
    }

    /// Everything one or more root walks accumulated, **including the dedupe** (packet F11).
    ///
    /// The dedupe used to run after every root had been walked, over a list of candidates the walk
    /// had collected. That was fine for a value returned at the end and useless for a process that
    /// is killed: a helper parked in `open()` inside `Documents` had already found every repo on
    /// the machine and had published none of them, because publishing happened in a pass that
    /// never started (F10). Each candidate is now identified and claimed the moment the walk meets
    /// it, which is what makes `onProgress` able to say "here is a repo" while there is still a
    /// walk to kill.
    private struct Walk {
        var candidatesExamined = 0
        var unreadableDirectories: [String] = []
        var depthCutDirectories = 0
        var skippedHiddenDirectories = 0
        var skippedWorktreeCheckouts: [String] = []
        var skippedSubmodules: [String] = []
        /// The walk stopped on cancellation with directories still queued.
        var truncated = false

        /// Claim order of the dedupe keys, and the working tree each key kept.
        private var order: [String] = []
        private var winners: [String: (path: String, gitIsDirectory: Bool)] = [:]

        /// The running totals a `skipped` event carries.
        var counters: ScanCounters {
            ScanCounters(
                candidatesExamined: candidatesExamined,
                depthCutDirectories: depthCutDirectories,
                skippedHiddenDirectories: skippedHiddenDirectories,
                skippedWorktreeCheckouts: skippedWorktreeCheckouts.count,
                skippedSubmodules: skippedSubmodules.count)
        }

        /// Sorted by path so a rescan of an unchanged machine produces an identical `ScanResult`
        /// and the cache does not churn.
        var resolvedRepos: [DiscoveredRepo] {
            order
                .map { DiscoveredRepo(path: winners[$0]!.path, id: RepoID(commonDir: $0)) }
                .sorted { $0.path < $1.path }
        }

        /// Records one identified candidate under its common directory and returns the repo to
        /// announce, or nil when an already-claimed key keeps the working tree it had.
        ///
        /// "The `.git` directory wins", not "whichever the walk reached first": a mirror whose
        /// `.git` file points into a real repo must never displace the repo itself. An upgrade
        /// changes the path under a key already announced, so it is announced again and the
        /// consumer keeps the last value for that id.
        mutating func claim(
            key: String, path: String, gitIsDirectory: Bool
        ) -> DiscoveredRepo? {
            guard let existing = winners[key] else {
                order.append(key)
                winners[key] = (path, gitIsDirectory)
                return DiscoveredRepo(path: path, id: RepoID(commonDir: key))
            }
            guard gitIsDirectory, !existing.gitIsDirectory else { return nil }
            winners[key] = (path, true)
            return DiscoveredRepo(path: path, id: RepoID(commonDir: key))
        }

        /// A folder the walk was cut off before it could finish is reported the same way a folder
        /// macOS refused to open is: not scanned, recoverable by granting access or rescanning.
        /// The folder named is the pending directory's own ancestor directly under the scan root,
        /// because "Not scanned: Documents" is the fact the user can act on and
        /// `Documents/notes/vendor` is not.
        ///
        /// Returns whether this was new, so the caller announces each folder once.
        @discardableResult
        mutating func reportNotScanned(_ path: String) -> Bool {
            guard !unreadableDirectories.contains(path) else { return false }
            unreadableDirectories.append(path)
            return true
        }
    }

    /// Breadth-first with an explicit `(path, depth)` queue. `maxDepth` is `nil` for an
    /// "Add folder…" root, which has no limit at all (PLAN.md §3).
    ///
    /// Two things the queue carries beyond the plain walk (packet 3.3). `deferTCCGatedFolders`
    /// holds the root's `Desktop`, `Documents` and `Downloads` back until everything else has
    /// been opened, so a pending consent dialog cannot block a repo that is elsewhere. And the
    /// loop checks cancellation once per directory, before the listing that can block: a
    /// cancelled walk stops where it is, marks the result truncated, and names the folders it
    /// never reached, rather than throwing away the repos it already found.
    private func walk(
        root: String,
        maxDepth: Int?,
        policy: ScanPolicy,
        deferTCCGatedFolders: Bool,
        descendIntoRootRepo: Bool,
        announceDepth: Int,
        candidateBudget: Int?,
        into initial: Walk
    ) async -> Walk {
        var accumulator = initial
        let rootPath = Self.normalized(root)
        let candidatesAtStart = accumulator.candidatesExamined
        var queue: [(path: String, depth: Int)] = [(rootPath, 0)]
        var deferred: [(path: String, depth: Int)] = []
        var gatedPaths: Set<String> = []
        var next = 0
        var flushedDeferred = false
        var lastReportedAt = accumulator.candidatesExamined

        while true {
            if next == queue.count {
                guard !flushedDeferred, !deferred.isEmpty else { break }
                flushedDeferred = true
                queue.append(contentsOf: deferred)
                deferred.removeAll()
                continue
            }

            let (path, depth) = queue[next]

            if Task.isCancelled {
                accumulator.truncated = true
                for pending in queue[next...] + deferred {
                    let folder = Self.topLevelFolder(of: pending.path, under: rootPath)
                    if accumulator.reportNotScanned(folder) { onProgress?(.unreadable(folder)) }
                }
                onProgress?(.skipped(accumulator.counters))
                return accumulator
            }
            next += 1

            // Announced before the call, not after it: a listing macOS is holding behind an
            // unanswered consent dialog never returns, so anything written afterwards is never
            // written at all. This line is the whole record that the walk was inside this folder
            // when the process was killed, and it is what the "Not scanned: Documents" row is
            // rebuilt from (packet F11).
            // codex round 3, MAJOR 2: announced for the gated folders **and** for every folder at
            // `announceDepth` or above, which is the home root's own children and each extra root.
            // Only the three gated names were announced before, so a helper killed inside an
            // ordinary directory or an added root left a result that was marked truncated and
            // named no folder at all — and the presenter suppressed its warning on exactly that
            // emptiness.
            if depth <= announceDepth || gatedPaths.contains(path) { onProgress?(.entering(path)) }

            if let candidateBudget, accumulator.candidatesExamined - candidatesAtStart >= candidateBudget {
                accumulator.truncated = true
                if accumulator.reportNotScanned(rootPath) { onProgress?(.unreadable(rootPath)) }
                onProgress?(.skipped(accumulator.counters))
                return accumulator
            }

            let entries: [DirectoryEntry]
            do {
                entries = try fileSystem.contentsOfDirectory(atPath: path)
            } catch {
                // A TCC denial is the normal case on a managed Mac: reported, never swallowed.
                if accumulator.reportNotScanned(path) { onProgress?(.unreadable(path)) }
                continue
            }
            accumulator.candidatesExamined += 1
            if accumulator.candidatesExamined - lastReportedAt >= Self.counterReportInterval {
                lastReportedAt = accumulator.candidatesExamined
                onProgress?(.skipped(accumulator.counters))
            }

            // A repo found inside a walk stops the descent — `descendIntoRepos` is a constant
            // false (PLAN.md §5), and a repo inside a monorepo is reached by adding it as a root.
            //
            // The **home root** is the one exception (REVIEW WR-08). `git init` in `$HOME` with a
            // `*` gitignore is the dotfiles pattern, and the `.git` check runs before a
            // directory's children are enqueued, so `~/.git` used to make `~` the one and only
            // candidate and end the walk there: every real repo under the home folder invisible,
            // the empty state suppressed because one repo was listed, and no message saying why.
            // The home root is therefore listed as a repo *and* walked. An "Add folder…" root
            // that is a repo keeps the plain rule (`extraRootThatIsARepoYieldsItself`): it is the
            // folder the user pointed at, they get the repo they picked, and a nested one is
            // another "Add folder…" away.
            let isWalkRoot = depth == 0 && descendIntoRootRepo
            //
            // A **symlinked** `.git` is not a marker at all (codex round 2, BLOCKER 2). It is
            // reported `isDirectory == false`, so it used to fall into the `.git` file arm and get
            // opened, and `.git -> /path/to/some/fifo` parked the whole walk inside
            // `open(O_RDONLY)` with nothing able to end it. It is classified `unrecognized`, never
            // read, and the walk carries on into the directory's children.
            if let marker = entries.first(where: { $0.name == ".git" }), !marker.isSymbolicLink {
                if marker.isDirectory {
                    await claim(
                        Candidate(path: path, commonDirectoryHint: path + "/.git", gitIsDirectory: true),
                        into: &accumulator)
                    if !isWalkRoot { continue }
                } else {
                    // Bounded: a `.git` file holds one short `gitdir:` line, and the file is
                    // repository-controlled (codex MAJOR 15).
                    let contents = (try? fileSystem.readFile(
                        atPath: marker.path, maximumBytes: Self.maximumGitFileBytes))
                        .map { String(decoding: $0, as: UTF8.self) } ?? ""
                    switch Self.classifyGitFile(contents: contents) {
                    case .worktreeCheckout:
                        accumulator.skippedWorktreeCheckouts.append(path)
                        if !isWalkRoot { continue }
                    case .submodule:
                        accumulator.skippedSubmodules.append(path)
                        if !isWalkRoot { continue }
                    case .candidate(let gitDirectory):
                        await claim(
                            Candidate(path: path, commonDirectoryHint: gitDirectory, gitIsDirectory: false),
                            into: &accumulator)
                        if !isWalkRoot { continue }
                    case .unrecognized:
                        // Not a repo marker we can vouch for; keep walking rather than inventing a row.
                        break
                    }
                }
            }

            for entry in entries where entry.isDirectory {
                // Following a symlink turns the home scan into an unbounded walk and can list the
                // same repo twice; the target is reachable by adding it as a root.
                if entry.isSymbolicLink { continue }
                if entry.name == ".git" { continue }
                if policy.skipHiddenDirectories, entry.name.hasPrefix(".") {
                    accumulator.skippedHiddenDirectories += 1
                    continue
                }
                if Self.isSkipped(path: entry.path, name: entry.name, names: policy.skipDirectoryNames) {
                    continue
                }
                if let maxDepth, depth + 1 > maxDepth {
                    accumulator.depthCutDirectories += 1
                    continue
                }
                let child = (path: Self.normalized(entry.path), depth: depth + 1)
                if deferTCCGatedFolders, depth == 0, Self.tccGatedFolderNames.contains(entry.name) {
                    gatedPaths.insert(child.path)
                    deferred.append(child)
                } else {
                    queue.append(child)
                }
            }
        }

        onProgress?(.skipped(accumulator.counters))
        return accumulator
    }

    /// Identifies one candidate and records it under its common directory, announcing the repo
    /// through `onProgress` if the claim changed what that key holds.
    private func claim(_ candidate: Candidate, into accumulator: inout Walk) async {
        let resolved = await identify(candidate)
        let repo = accumulator.claim(
            key: Self.normalized(resolved.commonDirectory),
            path: resolved.path,
            gitIsDirectory: candidate.gitIsDirectory)
        if let repo { onProgress?(.repo(repo)) }
    }

    /// The ancestor of `path` that sits directly under `root`, or `root` itself when `path` is
    /// the root. What the "Not scanned" row names when a walk is cut short.
    private static func topLevelFolder(of path: String, under root: String) -> String {
        guard path.hasPrefix(root + "/") else { return path }
        let remainder = path.dropFirst(root.count + 1)
        let first = remainder.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return root + "/" + first
    }

    /// A single-component entry matches a directory **name** at any depth; a multi-component
    /// entry (the frozen list holds one, `"go/pkg"`) matches a **path suffix**, so `~/go/pkg` is
    /// skipped while `~/src/pkg` and `~/go/src` are walked.
    private static func isSkipped(path: String, name: String, names: [String]) -> Bool {
        for entry in names {
            if entry.contains("/") {
                if path == entry || path.hasSuffix("/" + entry) { return true }
            } else if name == entry {
                return true
            }
        }
        return false
    }

    // MARK: - Dedupe

    /// `git -C <path> rev-parse --path-format=absolute --git-common-dir --show-toplevel` when a
    /// runner is available; otherwise the common directory the filesystem already told us and the
    /// directory that carried the marker.
    private func identify(_ candidate: Candidate) async -> (commonDirectory: String, path: String) {
        guard let commandRunner else {
            return (candidate.commonDirectoryHint, candidate.path)
        }

        // codex round 2, MAJOR 3: one invocation per path. Asking for both in one `rev-parse`
        // returns them separated by a newline, and a directory name may legally contain one, so
        // `project\narchive` shifted the two fields — the dedupe keyed on the wrong id, and every
        // later command ran with a fragment as its working directory. Each answer is stripped of
        // exactly one trailing record newline and nothing else, so a path that really ends in a
        // newline keeps it.
        guard
            let commonDirectory = await path(
                for: "--git-common-dir", at: candidate.path, using: commandRunner),
            let topLevel = await path(
                for: "--show-toplevel", at: candidate.path, using: commandRunner)
        else {
            return (candidate.commonDirectoryHint, candidate.path)
        }
        return (commonDirectory, topLevel)
    }

    /// One `git -C <path> rev-parse --path-format=absolute <option>`, or nil when git failed or
    /// printed nothing.
    private func path(
        for option: String, at path: String, using commandRunner: CommandRunner
    ) async -> String? {
        // No working directory, for the reason `GitClient.command` gives: `-C` already names the
        // repository, and a second resolution of the same repository-owned path happens inside
        // `Process.run()`, where a dead mount blocks before there is a child to kill (codex
        // round 4, BLOCKER 2).
        let command = Command(
            executable: gitExecutable,
            arguments: ["-C", path, "rev-parse", "--path-format=absolute", option]
        )
        guard
            let output = try? await commandRunner.run(command),
            output.exitCode == 0
        else { return nil }

        let answer = Self.strippingOneTrailingNewline(output.standardOutputText)
        return answer.isEmpty ? nil : answer
    }

    /// Removes the single record separator git writes after the path, and nothing else. A
    /// `trimmingCharacters` here would eat a newline the path itself ends in.
    static func strippingOneTrailingNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    private static func normalized(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}
