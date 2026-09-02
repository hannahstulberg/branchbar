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

/// `RepoScanner` in a **separate process** that the deadline can kill.
///
/// The helper is the `branchbar-cli` binary the app ships beside its own executable
/// (`Contents/MacOS/branchbar-cli`, put there by `scripts/bundle.sh`). It is invoked as
///
///     branchbar-cli scan --policy-json <tmpfile> --json --deadline <soft seconds>
///
/// and prints one `ScanResult` as JSON on stdout. Two bounds sit on it, and they answer different
/// questions:
///
/// - The **soft** deadline is the helper's own copy of the in-process race. A walk that is merely
///   slow, or blocked on something the task system can still interrupt at a directory boundary,
///   is cancelled there and the helper prints the repos it had already found. That is the case
///   where a partial answer exists, and it is the common one.
/// - The **hard** deadline is `Command.timeout`, which `ProcessCommandRunner` turns into SIGTERM
///   to the helper's process group and SIGKILL after its grace period. That is the case a task
///   cannot reach: a listing already inside the kernel. Nothing has been printed, so the runner
///   answers with an empty result marked `truncatedByDeadline`, which is what tells
///   `RefreshCoordinator` the list is incomplete and the next refresh must walk again.
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
    public static func arguments(policyPath: String, softDeadline: TimeInterval, gitExecutable: String?) -> [String] {
        var arguments = [subcommand, "--policy-json", policyPath, "--json"]
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

        let output: CommandOutput
        do {
            output = try await runner.run(command)
        } catch let error as CommandError {
            switch error {
            case .timedOut, .cancelled, .outputTooLarge, .readFailed:
                // The hard bound fired: the helper was killed with its process group, so nothing
                // is leaked and nothing is lost that was ever printed. An empty truncated result
                // is the honest answer — the walk did not finish, and the next refresh rescans.
                return Self.truncatedResult(for: policy)
            case .launchFailed, .nonZeroExit:
                throw error
            }
        }

        guard output.exitCode == 0 else {
            throw CommandError.nonZeroExit(
                exitCode: output.exitCode,
                standardError: output.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let result = try? Self.makeDecoder().decode(ScanResult.self, from: output.standardOutput) else {
            // Exit 0 with output this side cannot read is a broken helper, not a finished scan;
            // saying "truncated" keeps the coordinator rescanning rather than freezing an empty
            // repo list into the cache for a week.
            return Self.truncatedResult(for: policy)
        }
        return result
    }
}
