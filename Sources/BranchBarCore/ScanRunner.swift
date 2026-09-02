import Foundation

/// The discovery seam: "walk the tree and hand back a `ScanResult`", with no promise about
/// *where* the walk happens.
///
/// It exists because a deadline cannot end a walk that is running in this process (codex round 2,
/// BLOCKER 1). `RefreshCoordinator.scanWithinDeadline` used to race `RepoScanner` against a
/// timer and, when the timer won, call `group.cancelAll()` and keep waiting. `RepoScanner` checks
/// `Task.isCancelled` before each listing, which is the only place cancellation can land: a task
/// already inside `open()`/`readdir()` — behind an unanswered TCC dialog, a stalled automount, a
/// dead network volume, a File Provider that never answers — never reaches that check, and no
/// deadline above it can make it. First launch stayed on "Looking for repos…" forever, and
/// returning from the task group would have leaked a permanently blocked thread rather than
/// fixing anything.
///
/// A process, unlike a task, can be killed. `HelperProcessScanRunner` runs the same walk in the
/// `branchbar-cli` helper and lets `ProcessCommandRunner`'s SIGTERM/SIGKILL escalation end it,
/// blocked kernel call and all. `InProcessScanRunner` is the same walk in this process, which is
/// what every unit test and the CLI's own `scan` subcommand use.
public protocol ScanRunning: Sendable {
    /// Returns a `ScanResult`, whose `truncatedByDeadline` says whether the list is the whole
    /// truth. Throws only for a failure the caller should treat as "no scan happened".
    func scan(policy: ScanPolicy) async throws -> ScanResult
}

/// `RepoScanner` in this process. The default everywhere a killable helper is not available, and
/// the only implementation a unit test uses.
public struct InProcessScanRunner: ScanRunning {
    private let scanner: RepoScanner

    public init(scanner: RepoScanner) {
        self.scanner = scanner
    }

    public func scan(policy: ScanPolicy) async throws -> ScanResult {
        try await scanner.scan(policy: policy)
    }
}

/// What a child printed, plus why it stopped, with neither one hiding the other (packet F11).
///
/// `CommandRunner.run` throws on a timeout, and a thrown error carries no bytes, so a helper that
/// was killed mid-walk read as a helper that had said nothing. For every other command in this app
/// that is the right answer — a truncated `for-each-ref` that happens to end on a record boundary
/// is a shorter branch list, which is a lie — but the scan helper's output is a stream of
/// independently meaningful lines, and each one that arrived is true whatever happened next.
public struct PartialCommandOutput: Sendable {
    public var standardOutput: Data
    public var standardError: Data
    /// nil when the command was killed rather than finished: the status then describes a signal.
    public var exitCode: Int32?
    /// nil when the command ran to completion.
    public var failure: CommandError?

    public var standardOutputText: String { String(decoding: standardOutput, as: UTF8.self) }
    public var standardErrorText: String { String(decoding: standardError, as: UTF8.self) }

    public init(
        standardOutput: Data = Data(),
        standardError: Data = Data(),
        exitCode: Int32? = nil,
        failure: CommandError? = nil
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
        self.failure = failure
    }
}

/// A `CommandRunner` that owns a real process, and can therefore hand back what that process
/// printed before it was killed. `ProcessCommandRunner` conforms; a stub that answers from a
/// dictionary has nothing partial to offer, which is why this is a separate protocol rather than a
/// requirement on the frozen seam.
public protocol PartialOutputCommandRunning: CommandRunner {
    func runCollectingPartialOutput(_ command: Command) async -> PartialCommandOutput
}

/// One line of the helper's NDJSON stream. Exactly one field is set per line.
///
/// The helper writes these as it walks and flushes after each one; `HelperProcessScanRunner` reads
/// whatever arrived. A `result` line means the walk finished and its `ScanResult` is the whole
/// answer; without one, the `repo` and `unreadable` lines are what the walk had established when
/// something ended it.
public struct ScanStreamLine: Hashable, Codable, Sendable {
    public var repo: DiscoveredRepo?
    public var unreadable: String?
    public var entering: String?
    public var skipped: ScanCounters?
    public var result: ScanResult?

    public init(
        repo: DiscoveredRepo? = nil,
        unreadable: String? = nil,
        entering: String? = nil,
        skipped: ScanCounters? = nil,
        result: ScanResult? = nil
    ) {
        self.repo = repo
        self.unreadable = unreadable
        self.entering = entering
        self.skipped = skipped
        self.result = result
    }

    /// The wire form of one `RepoScanner` progress event.
    public init(_ event: ScanEvent) {
        self.init()
        switch event {
        case .repo(let repo): self.repo = repo
        case .unreadable(let path): self.unreadable = path
        case .entering(let path): self.entering = path
        case .skipped(let counters): self.skipped = counters
        }
    }
}

/// `RepoScanner` in a **separate process** that the deadline can kill.
///
/// The helper is the `branchbar-cli` binary the app ships beside its own executable
/// (`Contents/MacOS/branchbar-cli`, put there by `scripts/bundle.sh`). It is invoked as
///
///     branchbar-cli scan --policy-json <tmpfile> --deadline <soft seconds>
///
/// and streams NDJSON on stdout as it walks: a `repo` line the moment one is deduped, an
/// `unreadable` line per folder it could not read, an `entering` line before each TCC-gated
/// listing, `skipped` counters periodically, and a final `result` line carrying the whole
/// `ScanResult` when the walk finishes. Two bounds sit on it, and they answer different questions:
///
/// - The **soft** deadline is the helper's own copy of the in-process race. A walk that is merely
///   slow, or blocked on something the task system can still interrupt at a directory boundary,
///   is cancelled there and the helper prints the repos it had already found. That is the case
///   where a partial answer exists, and it is the common one.
/// - The **hard** deadline is `Command.timeout`, which `ProcessCommandRunner` turns into SIGTERM
///   to the helper's process group and SIGKILL after its grace period. That is the case a task
///   cannot reach: a listing already inside the kernel.
///
/// Until packet F11 the hard case cost everything: no final line meant no answer, and the runner
/// returned a synthetic empty `ScanResult`. F10 measured what that was worth — three launches, 21
/// seconds each, `repos: 0`, `candidatesExamined: 0`, while the same helper run from Terminal
/// found 25 repos in 1.2 s. The walk had found them all; the gated folders go last. Now the
/// stream is the answer: whatever lines arrived are assembled, `truncatedByDeadline` says the list
/// is not everything so `RefreshCoordinator` rescans next time, and the folder the helper was
/// inside when it died is reported the way a TCC denial is.
public struct HelperProcessScanRunner: ScanRunning {
    /// The `branchbar-cli` subcommand this runner invokes.
    public static let subcommand = "scan"
    /// The helper's file name inside `Contents/MacOS`, and the product name in `Package.swift`.
    public static let helperExecutableName = "branchbar-cli"

    /// How much of the hard deadline the helper is given for its own cooperative cancellation, so
    /// a walk that *can* answer gets the chance to print a partial result before the process is
    /// killed out from under it.
    public static let softDeadlineFraction: Double = 0.75

    private let helperExecutable: String
    private let runner: any CommandRunner
    private let scanDeadline: TimeInterval
    private let temporaryDirectory: URL
    private let gitExecutable: String?

    /// - Parameters:
    ///   - helperExecutable: absolute path to `branchbar-cli`; resolve it with
    ///     `helperExecutableURL(besideExecutableAt:)`.
    ///   - runner: the process seam, so a test can answer with a script instead of the real helper.
    ///   - scanDeadline: `RefreshPolicy.scanDeadline`, used verbatim as the child's `timeout`.
    ///   - gitExecutable: the git the helper should dedupe with. Passed through so the helper
    ///     resolves the same binary `ToolLocator` did rather than searching again.
    ///   - temporaryDirectory: where the policy JSON is written; the file is removed afterwards.
    public init(
        helperExecutable: String,
        runner: any CommandRunner = ProcessCommandRunner(),
        scanDeadline: TimeInterval = RefreshPolicy.default.scanDeadline,
        gitExecutable: String? = nil,
        temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    ) {
        self.helperExecutable = helperExecutable
        self.runner = runner
        self.scanDeadline = scanDeadline
        self.gitExecutable = gitExecutable
        self.temporaryDirectory = temporaryDirectory
    }

    /// The `branchbar-cli` sitting next to `executableURL`, or nil when there is no executable
    /// file there.
    ///
    /// Derived from the **running executable**, never from `Bundle.main.bundlePath`: a quarantined
    /// copy is app-translocated, so the bundle path is a `/private/var/…/AppTranslocation/…`
    /// mirror, and the executable URL is the only thing that points at the binary that is actually
    /// running (ARCHITECTURE.md §8).
    public static func helperExecutableURL(
        besideExecutableAt executableURL: URL?,
        fileSystem: FileSystem = RealFileSystem()
    ) -> URL? {
        guard let executableURL else { return nil }
        let candidate = executableURL
            .deletingLastPathComponent()
            .appendingPathComponent(helperExecutableName, isDirectory: false)
        guard fileSystem.isExecutableFile(atPath: candidate.path) else { return nil }
        return candidate
    }

    /// `.iso8601`, matching what the helper prints. The two sides share this so a date never
    /// round-trips through two different strategies.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The argument array for one helper run, exposed so a test can assert the shape without
    /// spawning anything.
    ///
    /// No `--json` (F10's finding): `scan` never read the flag, and the subcommand's only output
    /// shape is now the NDJSON stream, so advertising a second one was a promise nothing kept.
    public static func arguments(policyPath: String, softDeadline: TimeInterval, gitExecutable: String?) -> [String] {
        var arguments = [subcommand, "--policy-json", policyPath]
        arguments += ["--deadline", String(format: "%.3f", max(0, softDeadline))]
        if let gitExecutable { arguments += ["--git", gitExecutable] }
        return arguments
    }

    /// An empty result that says so: no repos, nothing examined, `truncatedByDeadline` set, which
    /// `RefreshCoordinator.isUsable` refuses and the next refresh rescans.
    public static func truncatedResult(for policy: ScanPolicy, at date: Date = Date()) -> ScanResult {
        ScanResult(policy: policy, scannedAt: date, truncatedByDeadline: true)
    }

    public func scan(policy: ScanPolicy) async throws -> ScanResult {
        let policyFile = temporaryDirectory.appendingPathComponent(
            "branchbar-scan-policy-\(UUID().uuidString).json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: policyFile) }

        do {
            try Self.makeEncoder().encode(policy).write(to: policyFile, options: [.atomic])
        } catch {
            // Nowhere to hand the helper its instructions: the caller treats this as "no scan
            // happened" and falls back to whatever the cache already holds.
            throw error
        }

        let command = Command(
            executable: helperExecutable,
            arguments: Self.arguments(
                policyPath: policyFile.path,
                softDeadline: max(0.05, scanDeadline * Self.softDeadlineFraction),
                gitExecutable: gitExecutable),
            timeout: scanDeadline
        )

        // Whatever the helper printed before it stopped, and why it stopped, side by side. A
        // runner with no real process behind it has nothing partial to offer, so it falls back to
        // the plain call: only the shipped `ProcessCommandRunner` can return bytes from a child it
        // killed.
        let output: PartialCommandOutput
        if let partialRunner = runner as? any PartialOutputCommandRunning {
            output = await partialRunner.runCollectingPartialOutput(command)
        } else {
            do {
                let finished = try await runner.run(command)
                output = PartialCommandOutput(
                    standardOutput: finished.standardOutput,
                    standardError: finished.standardError,
                    exitCode: finished.exitCode)
            } catch let error as CommandError {
                output = PartialCommandOutput(failure: error)
            }
        }

        let lines = Self.streamLines(from: output.standardOutput)

        // The last line of a finished walk is its whole answer: the counts, the skip lists and
        // `truncatedByDeadline: false` are things only the walk knows.
        if let finished = lines.compactMap(\.result).last {
            return finished
        }

        // No final line, but lines: the helper was ended mid-walk and these are the repos it had
        // already established. This is the case F10 lost entirely.
        if !lines.isEmpty {
            return Self.assemble(policy: policy, from: lines)
        }

        // Nothing readable at all. A failure the caller must see is still a failure; a kill is
        // still an empty truncated result, which is what makes the next refresh rescan.
        if let failure = output.failure {
            switch failure {
            case .timedOut, .cancelled, .outputTooLarge, .readFailed:
                return Self.truncatedResult(for: policy)
            case .launchFailed, .nonZeroExit:
                throw failure
            }
        }
        if let exitCode = output.exitCode, exitCode != 0 {
            throw CommandError.nonZeroExit(
                exitCode: exitCode,
                standardError: output.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // Exit 0 with output this side cannot read is a broken helper, not a finished scan; saying
        // "truncated" keeps the coordinator rescanning rather than freezing an empty repo list
        // into the cache for a week.
        return Self.truncatedResult(for: policy)
    }

    /// Every line of the stream this side could read. A line it could not is skipped and costs
    /// that line only: the stream describes directory names, which belong to whatever is on disk,
    /// and letting one of them end the scan would hand any folder on this Mac the power to empty
    /// the repo list.
    static func streamLines(from data: Data) -> [ScanStreamLine] {
        let decoder = makeDecoder()
        var lines: [ScanStreamLine] = []
        for raw in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let line = try? decoder.decode(ScanStreamLine.self, from: Data(raw)) else { continue }
            // A line that decodes but sets nothing is not evidence of anything.
            guard line.repo != nil || line.unreadable != nil || line.entering != nil
                    || line.skipped != nil || line.result != nil
            else { continue }
            lines.append(line)
        }
        return lines
    }

    /// The `ScanResult` a walk that never finished had established.
    ///
    /// Always `truncatedByDeadline: true`, because the absence of a final line is exactly the
    /// claim "this list is not everything" — `RefreshCoordinator` refuses it as a finished scan
    /// and rescans next time, while the user still sees the repos that were found.
    ///
    /// The folder named by the last `entering` line joins `unreadableDirectories`, which is how
    /// "Not scanned: Documents" reaches the user. Last, not all: the gated folders are enumerated
    /// one after another at the very end of the walk, so an earlier one that was announced has
    /// since been left. The one case this over-reports is a kill in the moment between the final
    /// gated listing returning and the result line being written, where the row says a folder was
    /// not scanned that in fact was; the cost is one recoverable row and a rescan, and the cost of
    /// the opposite mistake is F10's silence.
    static func assemble(policy: ScanPolicy, from lines: [ScanStreamLine], at date: Date = Date()) -> ScanResult {
        var order: [RepoID] = []
        var byID: [RepoID: DiscoveredRepo] = [:]
        var unreadable: [String] = []
        var inProgress: String?
        var counters = ScanCounters()

        for line in lines {
            if let repo = line.repo {
                // A candidate whose `.git` is a real directory can supersede an earlier claim on
                // the same common directory, so the last value for an id wins.
                if byID.updateValue(repo, forKey: repo.id) == nil { order.append(repo.id) }
            }
            if let path = line.unreadable, !unreadable.contains(path) { unreadable.append(path) }
            if let path = line.entering { inProgress = path }
            if let skipped = line.skipped { counters = skipped }
        }

        if let inProgress, !unreadable.contains(inProgress) { unreadable.append(inProgress) }

        return ScanResult(
            policy: policy,
            scannedAt: date,
            repos: order.compactMap { byID[$0] }.sorted { $0.path < $1.path },
            candidatesExamined: counters.candidatesExamined,
            unreadableDirectories: unreadable,
            depthCutDirectories: counters.depthCutDirectories,
            skippedHiddenDirectories: counters.skippedHiddenDirectories,
            // The stream carries these as counts, not paths: a partial result names the repos it
            // found and the folders the user can act on, and nothing it cannot spell out.
            truncatedByDeadline: true)
    }
}
