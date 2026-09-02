import Foundation

/// The two questions the Gate 0b spike zip asks on a managed Mac, in a form the UI can call and
/// the log can record.
///
/// Deliberately not the real `CommandRunner`/`RepoScanner` (packets 2.5 and 2.4). This file is a
/// throwaway probe: it answers "can a GUI-launched process run `gh auth status`" and "does a
/// folder pick grant read access", nothing more. It shares `ToolLocator` with production because
/// the PATH question is exactly the thing under test.
public enum SpikeChecks {
    /// The frozen `gh` environment from PLAN.md §5, layered over the inherited environment so the
    /// user's `GH_CONFIG_DIR`, `HOME`, and keychain access survive.
    public static let ghEnvironment: [String: String] = [
        "GH_PROMPT_DISABLED": "1",
        "GH_NO_UPDATE_NOTIFIER": "1",
        "GH_PAGER": "cat",
        "NO_COLOR": "1",
        "CLICOLOR": "0",
    ]

    /// PLAN.md §5 `ScanPolicy.skipDirectoryNames`, verbatim.
    public static let skipDirectoryNames: Set<String> = [
        "Library", "Applications", "Pictures", "Movies", "Music", "Public",
        "node_modules", "vendor", "Pods", "DerivedData", "build", "dist",
        "target", "venv", "site-packages", "__pycache__", "go/pkg",
    ]

    /// Most repos a folder pick will report before the walk gives up.
    public static let maxGitDirs = 200

    // MARK: - Check GitHub CLI

    /// Locates `gh` and runs `gh auth status`, returning a report meant to be pasted back by a
    /// tester who has no terminal and no idea what a PATH is.
    ///
    /// The exit code matters as much as the text: `gh auth status` exits 0 when signed in and 1
    /// when not, and a `gh` that cannot reach the keychain from a GUI process fails here in a way
    /// no terminal test would reproduce.
    public static func ghAuthStatus() async -> String {
        let location = ToolLocator().locate(.gh)

        guard let ghPath = location.path else {
            return """
                gh: not found; searched: \(location.searched.joined(separator: ", "))
                exit code: n/a
                output:
                (gh was never run)
                """
        }

        let result = await run(
            executable: ghPath,
            arguments: ["auth", "status"],
            environmentOverrides: ghEnvironment,
            timeout: 10
        )

        var report = """
            gh: \(ghPath)
            searched: \(location.searched.joined(separator: ", "))
            command: gh auth status
            exit code: \(result.exitCodeDescription)
            """
        if result.timedOut {
            report += "\nNOTE: timed out after 10s and was terminated."
        }
        report += "\noutput:\n\(result.combinedOutput)"
        return report
    }

    // MARK: - Add folder…

    /// Walks `root` and returns the path of every directory that holds a `.git` entry.
    ///
    /// Not the real scanner: no dedupe, no worktree classification, no `.git`-file handling. It
    /// exists to prove that a folder chosen in `NSOpenPanel` is actually readable afterwards,
    /// which is the TCC question Gate 0b asks. It does skip hidden directories and the PLAN.md §5
    /// skip list, and it does not descend into a directory it has already called a repo, so the
    /// result resembles what the real scanner will report.
    public static func listGitDirs(under root: URL) -> [String] {
        let fileManager = FileManager.default
        var found: [String] = []
        var queue: [URL] = [root]

        while !queue.isEmpty, found.count < maxGitDirs {
            let directory = queue.removeFirst()

            let entries: [URL]
            do {
                entries = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsPackageDescendants]
                )
            } catch {
                // An unreadable directory is a fact, not a failure: on a managed Mac it is very
                // often TCC saying no, which is the outcome this check is looking for.
                continue
            }

            if entries.contains(where: { $0.lastPathComponent == ".git" }) {
                found.append(directory.path)
                continue  // descendIntoRepos = false (PLAN.md §5)
            }

            for entry in entries {
                let name = entry.lastPathComponent
                if name.hasPrefix(".") { continue }
                if skipDirectoryNames.contains(name) { continue }

                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                queue.append(entry)
            }
        }

        return found
    }

    // MARK: - Running a child process

    private struct RunResult: Sendable {
        var exitCode: Int32?
        var stdout: String
        var stderr: String
        var timedOut: Bool
        var launchError: String?

        var exitCodeDescription: String {
            if let launchError { return "could not launch (\(launchError))" }
            guard let exitCode else { return "unknown" }
            return String(exitCode)
        }

        var combinedOutput: String {
            var parts: [String] = []
            let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty { parts.append("[stdout]\n\(out)") }
            if !err.isEmpty { parts.append("[stderr]\n\(err)") }
            if let launchError { parts.append("[launch error]\n\(launchError)") }
            return parts.isEmpty ? "(no output)" : parts.joined(separator: "\n")
        }
    }

    /// Non-`Sendable` Foundation process plumbing crossing into a `@Sendable` dispatch closure.
    /// Safe because exactly one closure touches each boxed value.
    private final class Unchecked<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func set(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            storage = data
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: storage, as: UTF8.self)
        }
    }

    private static func run(
        executable: String,
        arguments: [String],
        environmentOverrides: [String: String],
        timeout: TimeInterval
    ) async -> RunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: runBlocking(
                        executable: executable,
                        arguments: arguments,
                        environmentOverrides: environmentOverrides,
                        timeout: timeout
                    )
                )
            }
        }
    }

    private static func runBlocking(
        executable: String,
        arguments: [String],
        environmentOverrides: [String: String],
        timeout: TimeInterval
    ) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in environmentOverrides { environment[key] = value }
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // A child that inherits a terminal-less stdin and then asks a question would hang for the
        // full timeout; /dev/null makes it fail immediately instead.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return RunResult(
                exitCode: nil, stdout: "", stderr: "", timedOut: false,
                launchError: error.localizedDescription
            )
        }

        // Both pipes are drained concurrently. Reading stdout to EOF first would deadlock as soon
        // as a child writes more than one pipe buffer (~64 KB) to stderr (PLAN.md §9).
        let stdout = OutputBuffer()
        let stderr = OutputBuffer()
        let outHandle = Unchecked(outPipe.fileHandleForReading)
        let errHandle = Unchecked(errPipe.fileHandleForReading)

        let drain = DispatchGroup()
        drain.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdout.set(outHandle.value.readDataToEndOfFile())
            drain.leave()
        }
        drain.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderr.set(errHandle.value.readDataToEndOfFile())
            drain.leave()
        }

        var timedOut = false
        if drain.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if drain.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = drain.wait(timeout: .now() + 2)
            }
        }

        // The pipes are closed, so the child is done writing; waiting for the status cannot hang
        // on output. It can still hang on a wedged child that ignored SIGKILL, which is not a
        // case worth engineering around in a spike.
        process.waitUntilExit()

        return RunResult(
            exitCode: process.terminationStatus,
            stdout: stdout.text,
            stderr: stderr.text,
            timedOut: timedOut,
            launchError: nil
        )
    }
}
