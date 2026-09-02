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
}
