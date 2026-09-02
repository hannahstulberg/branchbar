import Foundation

/// The real `CommandRunner`. PLAN.md §9: stdout and stderr are drained **concurrently**, or a
/// repo with more than 64 KB of refs deadlocks the pipe and surfaces as a 25 s timeout.
public struct ProcessCommandRunner: CommandRunner {
    /// Per-stream byte cap (codex MAJOR 15). 8 MB is far above anything the frozen invocations
    /// produce — the largest recorded `for-each-ref` on this machine is under 200 KB — and far
    /// below what would end a menu-bar app that holds two of them per repo in memory.
    public static let maximumOutputBytes = 8 * 1024 * 1024

    /// The four calls this runner makes that a test cannot provoke from outside it (codex round 4,
    /// BLOCKER 2 and MAJOR 2).
    ///
    /// A launch that blocks needs a filesystem that blocks; a process group whose leader has
    /// already exited needs a race to be won. Both are real, both are what the findings are about,
    /// and neither can be staged from a unit test. They are one injectable value instead, with the
    /// production defaults spelled out here, so the behaviour under test is the runner's own
    /// sequencing rather than a mock of it.
    struct SystemHooks: Sendable {
        /// Replaces `try process.run()`.
        var launch: (@Sendable () throws -> Void)?
        /// `getpgid`, which returns -1 for a leader that has already been reaped.
        var processGroup: @Sendable (pid_t) -> pid_t = { getpgid($0) }
        /// `kill`, so a test can see which pid and which signal actually went out.
        var sendSignal: @Sendable (pid_t, Int32) -> Void = { pid, signalNumber in
            kill(pid, signalNumber)
        }
        /// Where the process-group guard writes when the kernel disagrees with the assumption.
        var note: @Sendable (String) -> Void = { Log.info($0) }

        init(
            launch: (@Sendable () throws -> Void)? = nil,
            processGroup: @escaping @Sendable (pid_t) -> pid_t = { getpgid($0) },
            sendSignal: @escaping @Sendable (pid_t, Int32) -> Void = { kill($0, $1) },
            note: @escaping @Sendable (String) -> Void = { Log.info($0) }
        ) {
            self.launch = launch
            self.processGroup = processGroup
            self.sendSignal = sendSignal
            self.note = note
        }
    }

    private let hooks: SystemHooks

    public init() {
        self.hooks = SystemHooks()
    }

    init(hooks: SystemHooks) {
        self.hooks = hooks
    }

    /// Launches `command` with an argument array — never a shell string, so a branch named
    /// `-my-branch` arrives as an operand (`branchNameBeginningWithDashIsPassedAsOperandNotFlag`)
    /// — drains both pipes on their own threads, enforces `command.timeout`, and terminates the
    /// child when the calling task is cancelled
    /// (`cancelledRepoTasksTerminateTheirChildProcesses`).
    ///
    /// A non-zero exit is returned, not thrown: `git config --get remote.origin.url` exits 1
    /// with empty stdout when the key is unset, and `GitClient` reads that as "no remote".
    public func run(_ command: Command) async throws -> CommandOutput {
        let partial = await runCollectingPartialOutput(command)
        if let failure = partial.failure { throw failure }
        return CommandOutput(
            exitCode: partial.exitCode ?? -1,
            standardOutput: partial.standardOutput,
            standardError: partial.standardError)
    }

    /// `run`, except that the bytes the child managed to print survive the failure that ended it
    /// (packet F11).
    ///
    /// `run` throws on a timeout and on cancellation, and a thrown error carries no output, so a
    /// child that was killed mid-sentence is indistinguishable from one that never spoke. That is
    /// the whole of F10's finding: `branchbar-cli scan` had found every repo on the machine, had
    /// been killed inside a blocked listing, and the app got an empty result because the killing
    /// path had nowhere to put what had already been read. The readers hit EOF the moment the
    /// child dies, so the bytes are there; this is the accessor that does not throw them away.
    ///
    /// Deliberately not a `CommandError` change: every other caller wants "a failure is not an
    /// answer" (a truncated `for-each-ref` read as a short branch list is a lie), and this is the
    /// one caller whose output is a *stream* of independently meaningful records. The two paths
    /// where the partial buffer is dropped on purpose — a blown output cap and a failed pipe read
    /// — still drop it here.
    public func runCollectingPartialOutput(_ command: Command) async -> PartialCommandOutput {
        // Checked up front so a missing `gh` is one clear error rather than a POSIX errno the
        // tool notice would have to interpret. `CommandError` has no `executableNotFound` case;
        // the frozen seam spells this `launchFailed`.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: command.executable, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: command.executable)
        else {
            return PartialCommandOutput(failure: CommandError.launchFailed(
                executable: command.executable,
                message: "no executable file at \(command.executable)"))
        }

        let running = RunningCommand(command: command, hooks: hooks)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                running.start(continuation)
            }
        } onCancel: {
            running.cancel()
        }
    }
}

extension ProcessCommandRunner: PartialOutputCommandRunning {}

/// The bounded pipe drain, lifted out of `RunningCommand` so the error path is testable without
/// a child process.
enum PipeDrain {
    /// The buffer passed the cap; the caller terminates the child and reports `outputTooLarge`.
    struct Overflow: Error {}

    /// Reads until EOF or the cap, and **throws** whatever the read threw (codex round 2,
    /// MINOR 2).
    ///
    /// The loop used to be `guard let chunk = try? handle.read(...)`, which turns an I/O error
    /// into the same nil a clean EOF produces: the bytes already buffered were returned as a
    /// complete answer. If the truncation happened to land on a record boundary — and a
    /// `for-each-ref` stream is nothing but record boundaries — the repo silently showed a
    /// shorter branch list than it has. A failure to hear the answer is not an answer, so the
    /// error propagates and every byte already read is dropped by the caller.
    static func readBounded(cap: Int, _ next: () throws -> Data?) throws -> Data {
        var buffer = Data()
        while true {
            guard let chunk = try next(), !chunk.isEmpty else { break }
            buffer.append(chunk)
            if buffer.count > cap { throw Overflow() }
        }
        return buffer
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
    private let hooks: ProcessCommandRunner.SystemHooks
    private let lock = NSLock()
    /// Every deadline this runner arms — the command timeout, the SIGTERM→SIGKILL grace, the
    /// force-finish grace — is scheduled here, and nothing that blocks is (packet F19).
    ///
    /// It is **serial on purpose**. A private concurrent queue drains on libdispatch's default
    /// root queue, which is not overcommit: a work item submitted to it waits for a free worker
    /// thread, and the pool is capped at 64 threads per QoS. This runner used to submit its own
    /// blocking work — two pipe reads and a waiter, three parked threads per in-flight command —
    /// to that same pool, so roughly twenty concurrent commands filled it and the timeout item
    /// that was supposed to cut them off could not get a thread to run on. Measured on this
    /// machine: with 66 workers parked, a 0.3 s deadline on a private *concurrent* queue had not
    /// fired 20 s later, while the same deadline on a *serial* queue fired at 0.311 s. Serial
    /// queues drain on the overcommit root queue, which always brings a thread up.
    private let deadlineQueue = DispatchQueue(
        label: "com.branchbar.process-command-runner.deadline"
    )

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var continuation: CheckedContinuation<PartialCommandOutput, Never>?
    private var standardOutput = Data()
    private var standardError = Data()
    private var didFinish = false
    private var didCancel = false
    private var didTimeOut = false
    /// The child's process group, which is its own pid: Foundation spawns with
    /// `POSIX_SPAWN_SETPGROUP` and pgroup 0, so the pid the spawn returns **is** the group id
    /// (codex round 2, MAJOR 2; round 4, MAJOR 2 stopped discovering it with `getpgid`).
    /// Signalling asks this value, never the live process, because the leader can be gone while
    /// its group is not.
    private var savedProcessGroup: pid_t?
    /// Set when the launch itself threw. Carried rather than resumed on the spot, so `finish` is
    /// still the single place the continuation is answered (codex round 4, BLOCKER 2).
    private var launchFailure: CommandError?
    /// True once a child really exists. Until then there is nothing to signal and nothing to wait
    /// for, which is what lets a blocked launch answer its caller immediately.
    private var didLaunchChild = false
    /// The pid `getpgid` reported for the child at spawn, or nil when the lookup failed. Read only
    /// by `signalGroup`, and only to decide whether the pid needs a signal of its own.
    private var observedProcessGroup: pid_t?
    /// Set by whichever reader failed (codex round 2, MINOR 2); outranks the exit code.
    private var readFailure: (stream: CommandError.OutputStream, message: String)?
    /// Set by whichever reader passed the byte cap first (codex MAJOR 15).
    private var overflowedStream: CommandError.OutputStream?
    private var timeoutItem: DispatchWorkItem?

    init(command: Command, hooks: ProcessCommandRunner.SystemHooks) {
        self.command = command
        self.hooks = hooks
    }

    func start(_ continuation: CheckedContinuation<PartialCommandOutput, Never>) {
        lock.lock()
        // The task can already have been cancelled before the child was ever launched.
        if didCancel {
            lock.unlock()
            continuation.resume(returning: PartialCommandOutput(failure: .cancelled))
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

        let timeoutItem = DispatchWorkItem { [self] in self.timeOut() }
        self.timeoutItem = timeoutItem
        lock.unlock()

        // The deadline is armed **before** the launch, and the lock is not held across it (codex
        // round 4, BLOCKER 2). `Process.run()` is synchronous and does real work with the
        // pathnames it was handed — resolving `currentDirectoryURL`, opening the executable — and
        // on a disconnected mount that work blocks in the kernel. Arming afterwards meant the one
        // stretch of a command's life with no child process to kill was also the one stretch no
        // deadline covered, and holding the lock across it meant the cancellation handler blocked
        // behind the same call it was trying to end.
        deadlineQueue.asyncAfter(deadline: .now() + max(0, command.timeout), execute: timeoutItem)

        // A dedicated thread, not a queue work item: if the launch never returns, the thread it
        // owns is lost and nothing else is. The caller is resumed by the deadline that is already
        // running, and never waits on this.
        Self.onOwnThread("com.branchbar.process-launch") { [self] in self.launchAndSupervise() }
    }

    /// Runs one blocking job on a thread of its own (packet F19).
    ///
    /// Every job this runner starts parks: a pipe read blocks until the child writes or exits, and
    /// the waiter blocks until both readers are done. libdispatch's shared pool is the wrong place
    /// for work that parks — a parked worker is a worker no other work item can have, the pool is
    /// capped, and the item left waiting for a thread was this runner's own deadline. A thread per
    /// blocking job costs ~512 KB of stack that is released when the child ends, and it means the
    /// number of commands in flight can never decide whether a timeout is delivered.
    private static func onOwnThread(_ name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// Runs the launch, then — only if the launch actually produced a child — records its group
    /// and starts the readers and the waiter.
    private func launchAndSupervise() {
        lock.lock()
        let process = self.process
        lock.unlock()
        guard let process else { finish(exitCode: -1); return }

        do {
            // `hooks.launch` stands in for `process.run()` so a test can hold the launch open past
            // the deadline, which is what a dead mount does and what nothing else can stage.
            if let launch = hooks.launch { try launch() } else { try process.run() }
        } catch {
            lock.lock()
            launchFailure = .launchFailed(
                executable: command.executable, message: String(describing: error))
            lock.unlock()
            finish(exitCode: -1)
            return
        }

        // codex round 4, MAJOR 2: the group **is** the pid, recorded here rather than discovered.
        // Foundation spawns with `POSIX_SPAWN_SETPGROUP` and pgroup 0, so the child is the leader
        // of a group whose id is its own pid — that is true the instant `posix_spawn` returns,
        // while `getpgid` is a question asked afterwards that a child which forked a descendant
        // and exited first answers with -1. Answering -1 used to leave `savedProcessGroup` nil,
        // so the escalation signalled a dead pid and the descendant kept the pipes open.
        //
        // `kill(-pid, …)` can only ever reach a group whose leader is this child, because a group
        // id is the pid of its leader; a child that is somehow not a leader simply has no such
        // group and the signal costs an ESRCH. The old `getpgid == pid` guard is kept as exactly
        // that — a guard that says so rather than one that silently disarms the escalation.
        let pid = process.processIdentifier
        lock.lock()
        savedProcessGroup = pid > 0 ? pid : nil
        didLaunchChild = pid > 0
        let alreadyOver = didFinish || didCancel || didTimeOut
        lock.unlock()

        if pid > 0 {
            let observed = hooks.processGroup(pid)
            lock.lock()
            observedProcessGroup = observed > 0 ? observed : nil
            lock.unlock()
            if observed != pid {
                hooks.note(
                    "process group disagreement: child pid \(pid) reports group \(observed); "
                        + "signalling group \(pid) anyway")
            }
        }

        // The deadline or a cancellation arrived while the launch was still in flight, so the
        // caller has already been resumed by whichever of them it was and no reader or waiter was
        // ever started. The child exists now and nobody is watching it: this thread owns the
        // orphan. It signals the group, escalates, and reaps — and it never touches the
        // continuation, which `finish` has already answered (packet F19).
        guard !alreadyOver else {
            signalGroup(SIGTERM)
            deadlineQueue.asyncAfter(deadline: .now() + Self.killGrace) { [self] in
                self.signalGroup(SIGKILL)
            }
            // Bounded by the SIGKILL above. Guarded on the pid because a `Process` that never
            // reached `run()` — the injected-launch case — has nothing to wait for.
            if pid > 0 { process.waitUntilExit() }
            return
        }

        // Two readers, running at the same time, each blocking on its own pipe — on threads of
        // their own, so a full dispatch pool cannot delay the reads or the deadline that ends them.
        let readers = DispatchGroup()
        readers.enter()
        Self.onOwnThread("com.branchbar.process-read-stdout") { [self] in
            self.drain(self.outputPipe?.fileHandleForReading, stream: .standardOutput)
            readers.leave()
        }
        readers.enter()
        Self.onOwnThread("com.branchbar.process-read-stderr") { [self] in
            self.drain(self.errorPipe?.fileHandleForReading, stream: .standardError)
            readers.leave()
        }

        // The waiter joins both readers before reaping, so no output is lost to a fast exit.
        Self.onOwnThread("com.branchbar.process-wait") { [self] in
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
        // Read under the same lock that records the cancellation — see `timeOut`.
        let childExisted = didLaunchChild
        lock.unlock()
        terminateChild(childExisted: childExisted)
    }

    private func timeOut() {
        lock.lock()
        guard !didFinish, !didTimeOut, !didCancel else { lock.unlock(); return }
        didTimeOut = true
        // Whether a child existed is decided **here**, under the same lock that records the
        // timeout, and never re-read later (packet F19).
        //
        // `terminateChild` used to take its own lock and ask again, which let the launcher thread
        // slip in between: it sets `didLaunchChild` and reads `didTimeOut` in one lock hold, so a
        // launch that returned a pid a moment after the deadline fired saw `alreadyOver` and went
        // straight to signalling the orphan — no reader, no waiter, nothing left that could resume
        // the caller — while `terminateChild`, asking afterwards, saw the pid and took the
        // signal-and-wait path. The only thing that could answer the caller was then the 3 s
        // force-finish timer, so a 0.3 s timeout cost 3.3 s. Deciding at the moment the deadline
        // fires makes the two threads agree: if the pid was not there yet, the caller is resumed
        // now and the launcher owns the orphan.
        let childExisted = didLaunchChild
        lock.unlock()
        terminateChild(childExisted: childExisted)
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
    ///
    /// `childExisted` is the caller's snapshot of `didLaunchChild`, taken under the lock that
    /// recorded the cancellation or the timeout, so this decision cannot be overtaken by a launch
    /// that returns a pid immediately afterwards (packet F19).
    private func terminateChild(childExisted: Bool) {
        // codex round 4, BLOCKER 2: the launch has not produced a child yet, so there is no group
        // to signal and no output that could still arrive. Waiting out the kill grace here would
        // make a blocked launch cost the caller the deadline *plus* three seconds, on a call that
        // will never come back. The launch thread is left to whatever it is stuck in;
        // `launchAndSupervise` signals and reaps the child if one ever appears.
        guard childExisted else {
            finish(exitCode: -1)
            return
        }

        signalGroup(SIGTERM)

        deadlineQueue.asyncAfter(deadline: .now() + Self.killGrace) { [self] in
            self.signalGroup(SIGKILL)
        }

        deadlineQueue.asyncAfter(deadline: .now() + Self.forceFinishGrace) { [self] in
            self.finish(exitCode: -1)
        }
    }

    /// Signals the **saved** process group, whatever the leader is doing now (codex round 2,
    /// MAJOR 2).
    ///
    /// The old version asked `Process.isRunning` first and refused when it was false. That is
    /// exactly the case the escalation exists for: the direct child accepts SIGTERM and exits,
    /// a grandchild ignores it and keeps stdout open, and by SIGKILL time the leader is gone — so
    /// nothing was ever sent, the descendant survived, and the runner returned on its force-finish
    /// timer while the reader threads stayed blocked on a pipe the grandchild still held. A
    /// process group outlives its leader; `killpg` on a group with no members returns ESRCH and
    /// costs nothing.
    ///
    /// When the child did not lead its own group, `savedProcessGroup` is nil and the pid alone is
    /// signalled: a negative pid on BranchBar's own group would signal BranchBar.
    private func signalGroup(_ signalNumber: Int32) {
        lock.lock()
        let group = savedProcessGroup
        let observed = observedProcessGroup
        let pid = process?.processIdentifier ?? -1
        lock.unlock()

        guard let group, group > 0 else {
            // No child was ever spawned, so there is nothing addressable at all.
            guard pid > 0 else { return }
            hooks.sendSignal(pid, signalNumber)
            return
        }

        hooks.sendSignal(-group, signalNumber)

        // The only case where the group signal reaches nothing: the kernel says this child is a
        // member of somebody else's group, so no group with id `pid` exists. `-observed` is not
        // the answer — it could be BranchBar's own group — so the child itself is signalled
        // directly, and its descendants are beyond reach. A lookup that merely *failed* is the
        // opposite case: the leader is gone, its group is not, and a bare pid could by then belong
        // to somebody else entirely.
        if let observed, observed != group, pid > 0 {
            hooks.sendSignal(pid, signalNumber)
        }
    }

    /// Reads one pipe in bounded chunks, so the size of what a child decides to print is never
    /// the size of an allocation here (codex MAJOR 15). Past the cap the partial output is
    /// dropped — a truncated `for-each-ref` would read as a short branch list, which is a lie —
    /// the child is terminated, and the caller gets `CommandError.outputTooLarge`.
    private func drain(_ handle: FileHandle?, stream: CommandError.OutputStream) {
        guard let handle else { return }
        do {
            let buffer = try PipeDrain.readBounded(cap: ProcessCommandRunner.maximumOutputBytes) {
                try handle.read(upToCount: 64 * 1024)
            }
            store(buffer, as: stream)
        } catch is PipeDrain.Overflow {
            lock.lock()
            if overflowedStream == nil { overflowedStream = stream }
            let childExisted = didLaunchChild
            lock.unlock()
            terminateChild(childExisted: childExisted)
        } catch {
            // codex round 2, MINOR 2: a read that failed partway is not a short answer. The
            // partial buffer is never stored, so nothing downstream can read it as a complete
            // one, and the caller gets `readFailed`.
            lock.lock()
            if readFailure == nil { readFailure = (stream, String(describing: error)) }
            let childExisted = didLaunchChild
            lock.unlock()
            terminateChild(childExisted: childExisted)
        }
    }

    private func store(_ data: Data, as stream: CommandError.OutputStream) {
        lock.lock(); defer { lock.unlock() }
        switch stream {
        case .standardOutput: standardOutput = data
        case .standardError: standardError = data
        }
    }

    /// Resumes the continuation exactly once. Cancellation outranks a timeout, both outrank a
    /// blown output cap, that outranks a failed pipe read, and all four outrank whatever exit code
    /// the terminated child ended up with.
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
        let readError = readFailure
        let launchError = launchFailure
        let bufferedOutput = standardOutput
        let bufferedError = standardError
        lock.unlock()

        guard let continuation else { return }

        let failure: CommandError?
        if cancelled {
            failure = .cancelled
        } else if timedOut {
            failure = .timedOut(after: command.timeout)
        } else if let launchError {
            // A launch that threw produced no child and no bytes; it outranks everything below.
            failure = launchError
        } else if let overflowed {
            failure = .outputTooLarge(
                stream: overflowed, limit: ProcessCommandRunner.maximumOutputBytes)
        } else if let readError {
            failure = .readFailed(stream: readError.stream, message: readError.message)
        } else {
            failure = nil
        }

        continuation.resume(returning: PartialCommandOutput(
            standardOutput: bufferedOutput,
            standardError: bufferedError,
            // A failure is not an exit status: the child was killed, so whatever number the
            // kernel left behind describes the signal and not the command.
            exitCode: failure == nil ? exitCode : nil,
            failure: failure))
    }
}
