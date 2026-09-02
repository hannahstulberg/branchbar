import Foundation
import Testing

@testable import BranchBarCore

/// `ProcessCommandRunner` is the one type in BranchBarCore that spawns a real child process, so
/// these tests spawn real children too — `/bin/sh`, `/bin/sleep`, `/bin/echo`. Nothing here runs
/// git or gh, so the PLAN.md §4 trust boundary ("`swift test` never runs git or gh") holds.
///
/// PLAN.md §9 names the failure these tests exist for: a repo with more than 64 KB of refs fills
/// the stdout pipe, and a runner that drains stdout and stderr one after the other deadlocks and
/// surfaces as a 25 s timeout instead of a branch list.
@Suite("ProcessCommandRunner drains, times out, and dies with its task")
struct ProcessCommandRunnerTests {

    /// Big enough to be many times the 64 KB pipe buffer, small enough to stay fast.
    private static let bigByteCount = 1_500_000

    /// `yes` writes forever and takes SIGPIPE when `head` has taken its fill, so this produces
    /// exactly `bigByteCount` bytes without a slow shell loop.
    private static func writeBytes(to stream: String, count: Int = bigByteCount) -> String {
        let redirect = stream == "stderr" ? " >&2" : ""
        return "yes 0123456789abcdefghijklmnopqrstuvwxyz | head -c \(count)\(redirect)"
    }

    private static func shell(_ script: String, timeout: TimeInterval = 60) -> Command {
        Command(executable: "/bin/sh", arguments: ["-c", script], timeout: timeout)
    }

    @Test("echoRoundTripsStdout")
    func echoRoundTripsStdout() async throws {
        let output = try await ProcessCommandRunner().run(
            Command(executable: "/bin/echo", arguments: ["hello", "branch bar"])
        )

        #expect(output.exitCode == 0)
        #expect(output.standardOutputText == "hello branch bar\n")
        #expect(output.standardError.isEmpty)
    }

    /// PLAN.md §9. A 1.5 MB stdout is ~23 pipe buffers; a runner that waits for exit before
    /// reading never gets past the first one.
    @Test("commandRunnerReturnsFullOutputWhenStdoutExceedsPipeBuffer")
    func commandRunnerReturnsFullOutputWhenStdoutExceedsPipeBuffer() async throws {
        let output = try await ProcessCommandRunner().run(
            Self.shell(Self.writeBytes(to: "stdout"))
        )

        #expect(output.exitCode == 0)
        #expect(output.standardOutput.count == Self.bigByteCount)
        #expect(output.standardError.isEmpty)
    }

    /// The two orderings between them catch either sequential reader: filling stderr first
    /// deadlocks a runner that drains stdout to EOF before touching stderr, and filling stdout
    /// first deadlocks the reverse.
    @Test("commandRunnerDrainsStderrConcurrentlyWithStdout")
    func commandRunnerDrainsStderrConcurrentlyWithStdout() async throws {
        let runner = ProcessCommandRunner()

        let stderrFirst = try await runner.run(
            Self.shell("\(Self.writeBytes(to: "stderr")); \(Self.writeBytes(to: "stdout"))")
        )
        #expect(stderrFirst.standardOutput.count == Self.bigByteCount)
        #expect(stderrFirst.standardError.count == Self.bigByteCount)

        let stdoutFirst = try await runner.run(
            Self.shell("\(Self.writeBytes(to: "stdout")); \(Self.writeBytes(to: "stderr"))")
        )
        #expect(stdoutFirst.standardOutput.count == Self.bigByteCount)
        #expect(stdoutFirst.standardError.count == Self.bigByteCount)
    }

    /// `git config --get remote.origin.url` exits 1 with empty stdout when the key is unset, and
    /// `GitClient` reads that as "no remote", so a non-zero exit must come back as output rather
    /// than as a thrown error.
    @Test("nonZeroExitIsReported")
    func nonZeroExitIsReported() async throws {
        let output = try await ProcessCommandRunner().run(
            Self.shell("printf 'boom\\n' >&2; exit 3")
        )

        #expect(output.exitCode == 3)
        #expect(output.standardOutputText.isEmpty)
        #expect(output.standardErrorText == "boom\n")
    }

    @Test("sleepWithShortTimeoutThrowsTimedOut")
    func sleepWithShortTimeoutThrowsTimedOut() async throws {
        let started = Date()
        await #expect(throws: CommandError.timedOut(after: 0.5)) {
            try await ProcessCommandRunner().run(
                Command(executable: "/bin/sleep", arguments: ["30"], timeout: 0.5)
            )
        }
        // The deadline is enforced, not merely reported: the call returns near the timeout.
        #expect(Date().timeIntervalSince(started) < 10)
    }

    /// The frozen `CommandError` (Seams/CommandRunner.swift) has no `executableNotFound` case;
    /// a missing or non-executable path is `launchFailed`.
    @Test("nonexistentExecutableThrowsExecutableNotFound (spelled launchFailed in the frozen seam)")
    func nonexistentExecutableThrowsLaunchFailed() async throws {
        let missing = "/nowhere/branchbar-does-not-exist"
        await #expect(throws: CommandError.self) {
            try await ProcessCommandRunner().run(Command(executable: missing, arguments: []))
        }

        do {
            _ = try await ProcessCommandRunner().run(Command(executable: missing, arguments: []))
            Issue.record("running a nonexistent executable should throw")
        } catch let error as CommandError {
            guard case .launchFailed(let executable, let message) = error else {
                Issue.record("expected launchFailed, got \(error)")
                return
            }
            #expect(executable == missing)
            #expect(!message.isEmpty)
        }
    }

    /// A directory is not launchable either, and the message must name the path so the tool
    /// notice can print it.
    @Test("aDirectoryIsNotALaunchableExecutable")
    func directoryIsNotLaunchable() async throws {
        await #expect(throws: CommandError.self) {
            try await ProcessCommandRunner().run(Command(executable: "/usr/bin", arguments: []))
        }
    }

    /// PLAN.md §7 `cancelledRepoTasksTerminateTheirChildProcesses`. The child records its own pid
    /// and then `exec`s, so the pid in the file is the direct child `Process` signals.
    @Test("cancelledRepoTasksTerminateTheirChildProcesses")
    func cancelledRepoTasksTerminateTheirChildProcesses() async throws {
        let directory = try Packet25TempDir()
        defer { directory.remove() }
        let pidFile = directory.url.appendingPathComponent("child.pid").path

        let task = Task {
            try await ProcessCommandRunner().run(
                Self.shell("echo $$ > '\(pidFile)'; exec sleep 30", timeout: 120)
            )
        }

        // Wait for the child to publish its pid (it is running by then).
        var pid: pid_t?
        for _ in 0..<300 where pid == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
            if let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
               let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                pid = value
            }
        }
        let childPID = try #require(pid, "the child never reported its pid")
        #expect(kill(childPID, 0) == 0, "the child should be alive before the task is cancelled")

        task.cancel()

        await #expect(throws: CommandError.cancelled) { try await task.value }

        var gone = false
        for _ in 0..<300 where !gone {
            if kill(childPID, 0) != 0 { gone = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(gone, "pid \(childPID) was still alive 3 s after the task was cancelled")
    }

    /// A GUI-launched `gh` needs the inherited `HOME` to find its config, and `GitClient`
    /// contributes only `LC_ALL` and `GIT_OPTIONAL_LOCKS`, so `Command.environment` is merged
    /// over the inherited environment rather than replacing it.
    @Test("environmentMergesCommandEnvOverInherited")
    func environmentMergesCommandEnvOverInherited() async throws {
        setenv("BRANCHBAR_TEST_INHERITED", "from-parent", 1)
        setenv("BRANCHBAR_TEST_OVERRIDDEN", "from-parent", 1)
        defer {
            unsetenv("BRANCHBAR_TEST_INHERITED")
            unsetenv("BRANCHBAR_TEST_OVERRIDDEN")
        }

        var command = Self.shell(
            "printf '%s|%s|%s' \"$BRANCHBAR_TEST_INHERITED\" \"$BRANCHBAR_TEST_OVERRIDDEN\" \"$BRANCHBAR_TEST_ADDED\""
        )
        command.environment = [
            "BRANCHBAR_TEST_OVERRIDDEN": "from-command",
            "BRANCHBAR_TEST_ADDED": "added",
        ]

        let output = try await ProcessCommandRunner().run(command)

        #expect(output.standardOutputText == "from-parent|from-command|added")
    }

    @Test("workingDirectoryIsWhereTheChildRuns")
    func workingDirectoryIsWhereTheChildRuns() async throws {
        let directory = try Packet25TempDir()
        defer { directory.remove() }

        var command = Self.shell("pwd -P")
        command.workingDirectory = directory.url.path

        let output = try await ProcessCommandRunner().run(command)
        let printed = output.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)

        // `pwd -P` prints `/private/var/...` where the URL says `/var/...`, so both sides go
        // through the same standardisation before they are compared.
        #expect(
            URL(fileURLWithPath: printed).resolvingSymlinksInPath()
                == directory.url.resolvingSymlinksInPath()
        )
    }

    /// PLAN.md §7 `branchNameBeginningWithDashIsPassedAsOperandNotFlag`: the argument array
    /// reaches the child verbatim, so a branch named `-my-branch` arrives as an operand.
    @Test("branchNameBeginningWithDashIsPassedAsOperandNotFlag")
    func branchNameBeginningWithDashIsPassedAsOperandNotFlag() async throws {
        let output = try await ProcessCommandRunner().run(
            Command(
                executable: "/bin/sh",
                arguments: ["-c", "printf '%s' \"$1\"", "sh", "-my-branch"]
            )
        )

        #expect(output.standardOutputText == "-my-branch")
    }

    // MARK: - Packet F3 — codex MAJOR 13 (process groups) and MAJOR 15 (bounded output)

    /// The group kill in `terminateChild` is only correct while every child leads its own
    /// process group, which is what Darwin's `Process` does (it spawns with
    /// `POSIX_SPAWN_SETPGROUP` and pgroup 0). This is the guard on that assumption: if a future
    /// Foundation leaves the child in BranchBar's own group, `kill(-pgid, …)` would signal the
    /// app itself, and the runner's fallback has to be the one that runs.
    @Test("childRunsInItsOwnProcessGroup")
    func childRunsInItsOwnProcessGroup() async throws {
        let directory = try Packet25TempDir()
        defer { directory.remove() }
        let pidFile = directory.url.appendingPathComponent("child.pid").path

        let task = Task {
            try await ProcessCommandRunner().run(
                Self.shell("echo $$ > '\(pidFile)'; exec sleep 30", timeout: 120)
            )
        }
        let childPID = try await Self.awaitPID(inFile: pidFile)

        #expect(getpgid(childPID) == childPID,
                "the child is expected to lead its own process group; it is in \(getpgid(childPID))")
        #expect(getpgid(childPID) != getpgid(0), "the child must not share BranchBar's group")

        task.cancel()
        _ = try? await task.value
    }

    /// codex MAJOR 13. The existing cancellation test `exec`s, so the pid the runner signals is
    /// the only process there is. A real `git` forks helpers — credential helpers, `git-remote-*`,
    /// a lazy fetch — and a helper that outlives the signal keeps the pipe write ends open after
    /// the app has reported the command finished.
    ///
    /// The parent here does not `exec`: it starts a background `sleep` and waits. It also ignores
    /// SIGTERM, and `sleep` inherits that disposition across its own exec, which is what a
    /// wrapper that installs its own handler does. So only the escalation matters, and the
    /// escalation was `kill(processIdentifier, SIGKILL)` — one pid, leaving the grandchild
    /// running. Both signals have to reach the whole process group.
    @Test("cancellationKillsAGrandchildThatDidNotExec")
    func cancellationKillsAGrandchildThatDidNotExec() async throws {
        let directory = try Packet25TempDir()
        defer { directory.remove() }
        let parentFile = directory.url.appendingPathComponent("parent.pid").path
        let grandchildFile = directory.url.appendingPathComponent("grandchild.pid").path

        let task = Task {
            try await ProcessCommandRunner().run(
                Self.shell(
                    "trap '' TERM; sleep 30 & echo $! > '\(grandchildFile)'; echo $$ > '\(parentFile)'; wait",
                    timeout: 120)
            )
        }

        let parentPID = try await Self.awaitPID(inFile: parentFile)
        let grandchildPID = try await Self.awaitPID(inFile: grandchildFile)
        #expect(grandchildPID != parentPID)
        #expect(kill(grandchildPID, 0) == 0, "the grandchild should be alive before cancellation")

        task.cancel()
        await #expect(throws: CommandError.cancelled) { try await task.value }

        #expect(await Self.waitUntilGone(parentPID), "pid \(parentPID) outlived its cancellation")
        #expect(await Self.waitUntilGone(grandchildPID),
                "grandchild pid \(grandchildPID) survived the cancellation with the pipes still open")
    }

    /// codex MAJOR 15: stdout and stderr are read to EOF into memory, so a repo with an enormous
    /// ref list — or a command that has started printing a loop — can end the app before any
    /// timeout helps. Past the cap the child is terminated and the caller gets a distinct error
    /// rather than a truncated answer that would read as a short branch list.
    @Test("stdoutBeyondTheCapTerminatesTheChildWithOutputTooLarge")
    func stdoutBeyondTheCapTerminatesTheChildWithOutputTooLarge() async throws {
        let over = ProcessCommandRunner.maximumOutputBytes + 1_000_000
        let started = Date()

        do {
            let output = try await ProcessCommandRunner().run(
                Self.shell(Self.writeBytes(to: "stdout", count: over), timeout: 120))
            Issue.record("expected outputTooLarge, got \(output.standardOutput.count) bytes")
        } catch let error as CommandError {
            #expect(error == .outputTooLarge(
                stream: .standardOutput, limit: ProcessCommandRunner.maximumOutputBytes))
        }

        #expect(Date().timeIntervalSince(started) < 30, "the cap must end the read, not wait it out")
    }

    /// The same cap on the other pipe, because stderr is drained by its own reader.
    @Test("stderrBeyondTheCapTerminatesTheChildWithOutputTooLarge")
    func stderrBeyondTheCapTerminatesTheChildWithOutputTooLarge() async throws {
        let over = ProcessCommandRunner.maximumOutputBytes + 1_000_000

        do {
            let output = try await ProcessCommandRunner().run(
                Self.shell(Self.writeBytes(to: "stderr", count: over), timeout: 120))
            Issue.record("expected outputTooLarge, got \(output.standardError.count) bytes")
        } catch let error as CommandError {
            #expect(error == .outputTooLarge(
                stream: .standardError, limit: ProcessCommandRunner.maximumOutputBytes))
        }
    }

    /// The cap is a cap, not a truncation: output just under it still arrives whole, so the
    /// bound cannot quietly shorten a real branch list.
    @Test("outputJustUnderTheCapIsReturnedWhole")
    func outputJustUnderTheCapIsReturnedWhole() async throws {
        let under = ProcessCommandRunner.maximumOutputBytes - 1024
        let output = try await ProcessCommandRunner().run(
            Self.shell(Self.writeBytes(to: "stdout", count: under), timeout: 120))

        #expect(output.exitCode == 0)
        #expect(output.standardOutput.count == under)
    }

    // MARK: Helpers

    /// Waits for a child to publish its pid into `file`, which it does before it blocks.
    private static func awaitPID(inFile file: String, timeout: TimeInterval = 5) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: file, encoding: .utf8),
               let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CancellationError()
    }

    /// True once `pid` is gone, polled for up to three seconds — the runner's own SIGTERM,
    /// SIGKILL, force-finish sequence.
    private static func waitUntilGone(_ pid: pid_t, timeout: TimeInterval = 6) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}

// MARK: - Packet F6 — codex round 2, MAJOR 2 (pgid) and MINOR 2 (pipe read errors)

/// codex round 2, MAJOR 2: "Process-group escalation loses descendants when the group leader exits
/// first." `signalGroup` refused to signal unless `Process.isRunning`, and asked `getpgid(pid)` at
/// signal time. A direct child that accepts SIGTERM and exits therefore takes the whole escalation
/// with it: at SIGKILL time the leader is gone, `isRunning` is false, and a grandchild that
/// ignored SIGTERM keeps running with the pipes open.
///
/// MINOR 2: "Pipe read failures are treated as clean EOF." `try?` around the read turned an I/O
/// error into a short buffer returned as success, so a truncated `for-each-ref` would read as a
/// shorter branch list.
@Suite("Escalation reaches the saved process group, and a pipe error is not an EOF")
struct ProcessCommandRunnerGroupAndReadTests {

    private static func shell(_ script: String, timeout: TimeInterval = 120) -> Command {
        Command(executable: "/bin/sh", arguments: ["-c", script], timeout: timeout)
    }

    /// The existing `cancellationKillsAGrandchildThatDidNotExec` keeps the **parent** alive by
    /// trapping SIGTERM, so it never reaches the case where the leader is gone. Here the parent
    /// takes the default disposition and dies on SIGTERM; only the grandchild traps it, and it
    /// holds stdout, so the readers never see EOF either.
    @Test("escalationKillsAGrandchildAfterTheLeaderExited")
    func escalationKillsAGrandchildAfterTheLeaderExited() async throws {
        let directory = try Packet25TempDir()
        defer { directory.remove() }
        let parentFile = directory.url.appendingPathComponent("parent.pid").path
        let grandchildFile = directory.url.appendingPathComponent("grandchild.pid").path

        // The grandchild ignores TERM and never exits on its own; it inherits stdout, so the
        // runner's readers stay blocked after the leader is reaped.
        let script = """
            sh -c 'trap "" TERM; echo $$ > \(grandchildFile); while :; do sleep 1; done' &
            echo $$ > \(parentFile)
            wait
            """

        let task = Task { try await ProcessCommandRunner().run(Self.shell(script)) }

        let parentPID = try await Self.awaitPID(inFile: parentFile)
        let grandchildPID = try await Self.awaitPID(inFile: grandchildFile)
        #expect(grandchildPID != parentPID)
        #expect(getpgid(grandchildPID) == getpgid(parentPID),
                "the grandchild must share the leader's group for this to be the case under test")

        task.cancel()
        await #expect(throws: CommandError.cancelled) { try await task.value }

        #expect(await Self.waitUntilGone(parentPID), "the leader outlived its own SIGTERM")
        #expect(
            await Self.waitUntilGone(grandchildPID),
            "grandchild pid \(grandchildPID) survived the escalation because the leader had already exited")
    }

    /// The saved group id is captured at spawn, so the escalation does not depend on the leader
    /// still being there to ask.
    @Test("theProcessGroupIsCapturedAtSpawnNotAtSignalTime")
    func processGroupIsCapturedAtSpawn() async throws {
        let directory = try Packet25TempDir()
        defer { directory.remove() }
        let pidFile = directory.url.appendingPathComponent("child.pid").path

        let task = Task {
            try await ProcessCommandRunner().run(
                Self.shell("echo $$ > '\(pidFile)'; exec sleep 30"))
        }
        let childPID = try await Self.awaitPID(inFile: pidFile)
        let group = getpgid(childPID)

        #expect(group == childPID)
        #expect(group != getpgrp(), "signalling this group must never reach BranchBar itself")

        task.cancel()
        _ = try? await task.value
        #expect(await Self.waitUntilGone(childPID))
    }

    /// codex MINOR 2. The bounded drain returns what it read only when the read **ended**; an
    /// error mid-stream throws, and the bytes already buffered are dropped rather than handed back
    /// as a complete answer.
    @Test("aPipeReadErrorDiscardsPartialOutput")
    func pipeReadErrorDiscardsPartialOutput() throws {
        struct Boom: Error {}
        var chunk = 0

        #expect(throws: Boom.self) {
            _ = try PipeDrain.readBounded(cap: 1_000_000) {
                chunk += 1
                // A record boundary, which is exactly what makes a silent truncation plausible.
                if chunk == 1 { return Data("refs/heads/main\n".utf8) }
                throw Boom()
            }
        }
        #expect(chunk == 2, "the drain stopped before it reached the failing read")

        // A clean EOF still returns everything, so the distinction is error-versus-EOF and not
        // "short reads are suspicious".
        var remaining = [Data("a".utf8), Data("b".utf8)]
        let whole = try PipeDrain.readBounded(cap: 1_000_000) {
            remaining.isEmpty ? nil : remaining.removeFirst()
        }
        #expect(whole == Data("ab".utf8))
    }

    /// Past the cap the drain still reports the overflow rather than the bytes, which is the
    /// behaviour `stdoutBeyondTheCapTerminatesTheChildWithOutputTooLarge` already pins end to end.
    @Test("theBoundedDrainStillReportsAnOverflow")
    func boundedDrainReportsOverflow() throws {
        #expect(throws: PipeDrain.Overflow.self) {
            _ = try PipeDrain.readBounded(cap: 4) { Data(repeating: 0x41, count: 8) }
        }
    }

    /// A read error is a distinct `CommandError`, not a `nonZeroExit` and not a truncated success,
    /// so the caller can tell "git said nothing" from "we could not hear git".
    @Test("readFailedIsItsOwnCommandError")
    func readFailedIsItsOwnCommandError() {
        let error = CommandError.readFailed(stream: .standardOutput, message: "Input/output error")
        #expect(error != CommandError.cancelled)
        #expect(error == CommandError.readFailed(stream: .standardOutput, message: "Input/output error"))
        #expect(error != CommandError.readFailed(stream: .standardError, message: "Input/output error"))
    }

    // MARK: Helpers

    private static func awaitPID(inFile file: String, timeout: TimeInterval = 10) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: file, encoding: .utf8),
               let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CancellationError()
    }

    private static func waitUntilGone(_ pid: pid_t, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
