import Foundation

/// One external process. PLAN.md §5 freezes the argument lists and the environment; this type
/// carries them as an array, never a shell string, so a branch name beginning with `-` is an
/// operand and not a flag (`branchNameBeginningWithDashIsPassedAsOperandNotFlag`).
public struct Command: Hashable, Codable, Sendable {
    /// Absolute path, resolved by `ToolLocator`; the GUI PATH has no Homebrew.
    // depends on ToolLocator (packet 0.3)
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String?
    /// Merged over the inherited environment, never a replacement for it: these entries win on a
    /// key the parent also sets, and every other inherited key survives
    /// (`environmentMergesCommandEnvOverInherited`).
    public var environment: [String: String]?
    /// Seconds. PLAN.md §5: git 10 s, `gh auth status` 10 s, `gh pr list` 25 s.
    public var timeout: TimeInterval

    public init(
        executable: String,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 10
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
    }

    /// What a `RecordedCommandRunner` stub matches on, and what a failure prints.
    public var displayString: String {
        let name = (executable as NSString).lastPathComponent
        return ([name] + arguments).joined(separator: " ")
    }
}

/// stdout and stderr of a finished process. Both are captured; PLAN.md §9 requires stderr to be
/// drained concurrently with stdout or a > 64 KB stdout deadlocks the pipe.
public struct CommandOutput: Hashable, Codable, Sendable {
    public var exitCode: Int32
    public var standardOutput: Data
    public var standardError: Data

    public init(exitCode: Int32, standardOutput: Data, standardError: Data) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var standardOutputText: String { String(decoding: standardOutput, as: UTF8.self) }
    public var standardErrorText: String { String(decoding: standardError, as: UTF8.self) }
}

/// Why a command produced no usable output. A non-zero exit is `nonZeroExit`, not a throw from
/// `Process`; `gh` uses exit 1 for "no PRs" and for "bad credentials" alike, so the mapping to
/// `PRUnavailableReason` reads stderr and belongs to `GHClient` (packet 2.3).
public enum CommandError: Error, Hashable, Codable, Sendable {
    /// The executable did not exist or could not be launched.
    case launchFailed(executable: String, message: String)
    case nonZeroExit(exitCode: Int32, standardError: String)
    /// The per-command timeout elapsed; the child was terminated.
    case timedOut(after: TimeInterval)
    /// The enclosing task was cancelled; the child was terminated.
    case cancelled
    /// The child wrote more than `ProcessCommandRunner.maximumOutputBytes` to stdout or stderr
    /// and was terminated with its output discarded (codex MAJOR 15). A repository with an
    /// enormous ref list, or a `git` that has started printing a loop, would otherwise be read
    /// to EOF into memory and can end the app before any timeout helps. `stream` names which
    /// pipe blew the cap so the log says which command to look at.
    case outputTooLarge(stream: OutputStream, limit: Int)
    /// A read from the child's pipe failed partway and every byte already read was discarded
    /// (codex round 2, MINOR 2). The loop used to swallow the error with `try?`, which returns a
    /// short buffer as a complete answer — and a truncated `for-each-ref` that happens to end on a
    /// record boundary reads as a shorter branch list, which is a lie. `stream` names which pipe
    /// failed so the log says which half of the command to look at.
    case readFailed(stream: OutputStream, message: String)

    /// Which of the two captured pipes exceeded the cap.
    public enum OutputStream: String, Hashable, Codable, Sendable {
        case standardOutput
        case standardError
    }
}

/// The process seam. `RecordedCommandRunner` replaces it in every unit test, so `swift test`
/// never runs git or gh (PLAN.md §4 trust boundary).
public protocol CommandRunner: Sendable {
    /// Runs to completion, draining stdout and stderr concurrently. Cancelling the calling task
    /// terminates the child (`cancelledRepoTasksTerminateTheirChildProcesses`).
    func run(_ command: Command) async throws -> CommandOutput
}
