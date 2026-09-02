import Foundation

/// The real `CommandRunner`. PLAN.md §9: stdout and stderr are drained **concurrently**, or a
/// repo with more than 64 KB of refs deadlocks the pipe and surfaces as a 25 s timeout.
public struct ProcessCommandRunner: CommandRunner {
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
            let data = self.outputPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
            self.store(standardOutput: data)
            readers.leave()
        }
        readers.enter()
        queue.async { [self] in
            let data = self.errorPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
            self.store(standardError: data)
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

    /// SIGTERM, then SIGKILL after a grace period, then resume the caller regardless.
    private func terminateChild() {
        lock.lock()
        let child = process
        lock.unlock()

        if let child, child.isRunning {
            child.terminate()
        }

        queue.asyncAfter(deadline: .now() + Self.killGrace) { [self] in
            self.lock.lock()
            let stillRunning = self.process
            self.lock.unlock()
            if let stillRunning, stillRunning.isRunning {
                kill(stillRunning.processIdentifier, SIGKILL)
            }
        }

        queue.asyncAfter(deadline: .now() + Self.forceFinishGrace) { [self] in
            self.finish(exitCode: -1)
        }
    }

    private func store(standardOutput data: Data) {
        lock.lock(); defer { lock.unlock() }
        standardOutput = data
    }

    private func store(standardError data: Data) {
        lock.lock(); defer { lock.unlock() }
        standardError = data
    }

    /// Resumes the continuation exactly once. Cancellation outranks a timeout, and both outrank
    /// whatever exit code the terminated child ended up with.
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
        } else {
            continuation.resume(returning: output)
        }
    }
}
