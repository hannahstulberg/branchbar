import Foundation

/// The real `CommandRunner`. PLAN.md §9: stdout and stderr are drained **concurrently**, or a
/// repo with more than 64 KB of refs deadlocks the pipe and surfaces as a 25 s timeout.
public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    /// OWNER: packet 2.5 — launch the command with `Process` and an argument array (never a shell
    /// string), drain stdout and stderr on separate readers so neither pipe can fill, enforce
    /// `command.timeout` by terminating the child and throwing `CommandError.timedOut`, terminate
    /// the child and throw `CommandError.cancelled` when the calling task is cancelled, and return
    /// the full output including exit code even when the exit code is non-zero.
    public func run(_ command: Command) async throws -> CommandOutput {
        fatalError("OWNER: packet 2.5 — run the command with concurrent stdout/stderr draining, a timeout that kills the child, and cancellation that kills the child.")
    }
}
