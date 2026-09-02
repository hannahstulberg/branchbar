import Foundation

/// The real `CommandRunner`. PLAN.md §9: stdout and stderr are drained **concurrently**, or a
/// repo with more than 64 KB of refs deadlocks the pipe and surfaces as a 25 s timeout.
public struct ProcessCommandRunner: CommandRunner {
    /// Per-stream byte cap (codex MAJOR 15). 8 MB is far above anything the frozen invocations
    /// produce — the largest recorded `for-each-ref` on this machine is under 200 KB — and far
    /// below what would end a menu-bar app that holds two of them per repo in memory.
    public static let maximumOutputBytes = 8 * 1024 * 1024

    public init() {}

    /// Launches `command` with an argument array — never a shell string, so a branch named
    /// `-my-branch` arrives as an operand (`branchNameBeginningWithDashIsPassedAsOperandNotFlag`)
    /// — drains both pipes on their own threads, enforces `command.timeout`, and terminates the
    /// child when the calling task is cancelled
    /// (`cancelledRepoTasksTerminateTheirChildProcesses`).
    ///
    /// A non-zero exit is returned, not thrown: `git config --get remote.origin.url` exits 1
    /// with empty stdout when the key is unset, and `GitClient` reads that as "no remote".
    public func run(_ command: Command) async throws -> CommandOutput {
        // Checked up front so a missing `gh` is one clear error rather than a POSIX errno the
        // tool notice would have to interpret. `CommandError` has no `executableNotFound` case;
        // the frozen seam spells this `launchFailed`.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: command.executable, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: command.executable)
        else {
            throw CommandError.launchFailed(
                executable: command.executable,
                message: "no executable file at \(command.executable)"
            )
        }

        let running = RunningCommand(command: command)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                running.start(continuation)
            }
        } onCancel: {
            running.cancel()
        }
    }
}

/// One in-flight child process and the three background threads that see it out: a stdout
/// reader, a stderr reader, and a waiter that resumes the continuation once both readers have
/// hit EOF and the child has been reaped.
///
/// Reading on separate threads is the whole point (PLAN.md §9). A runner that calls
/// `waitUntilExit()` before reading, or that reads stdout to EOF before touching stderr,
/// deadlocks the moment either pipe's 64 KB buffer fills — which a repo with a few hundred refs
/// does routinely.
private final class RunningCommand: @unchecked Sendable {
    /// Grace between SIGTERM and SIGKILL. A git that ignores SIGTERM still dies.
    private static let killGrace: TimeInterval = 2
    /// If the pipes somehow never reach EOF (a grandchild inherited the write end), the caller
    /// still gets its answer shortly after the kill rather than hanging forever.
    private static let forceFinishGrace: TimeInterval = 3

    private let command: Command
    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "com.branchbar.process-command-runner",
        attributes: .concurrent
    )

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var continuation: CheckedContinuation<CommandOutput, any Error>?
    private var standardOutput = Data()
    private var standardError = Data()
    private var didFinish = false
    private var didCancel = false
    private var didTimeOut = false
    /// Set by whichever reader passed the byte cap first (codex MAJOR 15).
    private var overflowedStream: CommandError.OutputStream?
    private var timeoutItem: DispatchWorkItem?

    init(command: Command) {
        self.command = command
    }

    func start(_ continuation: CheckedContinuation<CommandOutput, any Error>) {
        lock.lock()
        // The task can already have been cancelled before the child was ever launched.
        if didCancel {
            lock.unlock()
            continuation.resume(throwing: CommandError.cancelled)
            return
        }
        self.continuation = continuation

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        if let workingDirectory = command.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }

        // Merged over the inherited environment, not a replacement for it: `GitClient`
        // contributes only `LC_ALL` and `GIT_OPTIONAL_LOCKS`, and a `gh` launched without the
        // inherited `HOME` cannot find its own config or keyring entry.
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in command.environment ?? [:] {
            environment[key] = value
        }
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        // Nothing is ever written to a child; an inherited stdin would let `gh` block on a prompt.
        process.standardInput = FileHandle.nullDevice

        self.process = process
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe

        do {
            try process.run()
        } catch {
            self.process = nil
            self.continuation = nil
            lock.unlock()
            continuation.resume(
                throwing: CommandError.launchFailed(
                    executable: command.executable,
                    message: String(describing: error)
                )
            )
            return
        }

        let timeoutItem = DispatchWorkItem { [self] in self.timeOut() }
        self.timeoutItem = timeoutItem
        lock.unlock()

        queue.asyncAfter(deadline: .now() + max(0, command.timeout), execute: timeoutItem)

        // Two readers, running at the same time, each blocking on its own pipe.
        let readers = DispatchGroup()
        readers.enter()
        queue.async { [self] in
            self.drain(self.outputPipe?.fileHandleForReading, stream: .standardOutput)
            readers.leave()
        }
        readers.enter()
        queue.async { [self] in
            self.drain(self.errorPipe?.fileHandleForReading, stream: .standardError)
            readers.leave()
        }

        // The waiter joins both readers before reaping, so no output is lost to a fast exit.
        queue.async { [self] in
            readers.wait()
            self.process?.waitUntilExit()
            self.finish(exitCode: self.process?.terminationStatus ?? -1)
        }
    }

    /// Called from the task cancellation handler, on whatever thread cancelled.
    func cancel() {
        lock.lock()
        guard !didFinish, !didCancel else { lock.unlock(); return }
        didCancel = true
        lock.unlock()
        terminateChild()
    }

    private func timeOut() {
        lock.lock()
        guard !didFinish, !didTimeOut, !didCancel else { lock.unlock(); return }
        didTimeOut = true
        lock.unlock()
        terminateChild()
    }

    /// SIGTERM to the child's **process group**, then SIGKILL to the group after a grace period,
    /// then resume the caller regardless.
    ///
    /// The group, not the pid (codex MAJOR 13). `git` forks helpers — a credential helper, a
    /// `git-remote-*`, a lazy fetch — and `gh` forks a browser opener; a helper that outlives the
    /// signal holds the pipe write ends open after the app has reported the command finished, and
    /// keeps doing whatever it was doing. Every child leads its own process group
    /// (`childRunsInItsOwnProcessGroup`), so the negative pid reaches the child and everything it
    /// started, and `cancellationKillsAGrandchildThatDidNotExec` is the parent that ignores
    /// SIGTERM and leaves a background child behind.
    private func terminateChild() {
        lock.lock()
        let child = process
        lock.unlock()

        signalGroup(child, SIGTERM)

        queue.asyncAfter(deadline: .now() + Self.killGrace) { [self] in
            self.lock.lock()
            let stillRunning = self.process
            self.lock.unlock()
            self.signalGroup(stillRunning, SIGKILL)
        }

        queue.asyncAfter(deadline: .now() + Self.forceFinishGrace) { [self] in
            self.finish(exitCode: -1)
        }
    }

    /// Signals the child's process group when the child leads one, and the child alone when it
    /// does not — which would mean Foundation had stopped calling `posix_spawn` with
    /// `POSIX_SPAWN_SETPGROUP`, and a negative pid would then reach BranchBar's own group.
    private func signalGroup(_ child: Process?, _ signalNumber: Int32) {
        guard let child, child.isRunning else { return }
        let pid = child.processIdentifier
        guard pid > 0 else { return }

        let group = getpgid(pid)
        if group == pid, group != getpgrp() {
            kill(-group, signalNumber)
        } else {
            kill(pid, signalNumber)
        }
    }

    /// Reads one pipe in bounded chunks, so the size of what a child decides to print is never
    /// the size of an allocation here (codex MAJOR 15). Past the cap the partial output is
    /// dropped — a truncated `for-each-ref` would read as a short branch list, which is a lie —
    /// the child is terminated, and the caller gets `CommandError.outputTooLarge`.
    private func drain(_ handle: FileHandle?, stream: CommandError.OutputStream) {
        guard let handle else { return }
        var buffer = Data()

        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            buffer.append(chunk)
            guard buffer.count <= ProcessCommandRunner.maximumOutputBytes else {
                lock.lock()
                if overflowedStream == nil { overflowedStream = stream }
                lock.unlock()
                terminateChild()
                return
            }
        }

        store(buffer, as: stream)
    }

    private func store(_ data: Data, as stream: CommandError.OutputStream) {
        lock.lock(); defer { lock.unlock() }
        switch stream {
        case .standardOutput: standardOutput = data
        case .standardError: standardError = data
        }
    }

    /// Resumes the continuation exactly once. Cancellation outranks a timeout, both outrank a
    /// blown output cap, and all three outrank whatever exit code the terminated child ended up
    /// with.
    private func finish(exitCode: Int32) {
        lock.lock()
        guard !didFinish else { lock.unlock(); return }
        didFinish = true
        timeoutItem?.cancel()
        timeoutItem = nil
        let continuation = self.continuation
        self.continuation = nil
        let cancelled = didCancel
        let timedOut = didTimeOut
        let overflowed = overflowedStream
        let output = CommandOutput(
            exitCode: exitCode,
            standardOutput: standardOutput,
            standardError: standardError
        )
        lock.unlock()

        guard let continuation else { return }
        if cancelled {
            continuation.resume(throwing: CommandError.cancelled)
        } else if timedOut {
            continuation.resume(throwing: CommandError.timedOut(after: command.timeout))
        } else if let overflowed {
            continuation.resume(throwing: CommandError.outputTooLarge(
                stream: overflowed, limit: ProcessCommandRunner.maximumOutputBytes))
        } else {
            continuation.resume(returning: output)
        }
    }
}
