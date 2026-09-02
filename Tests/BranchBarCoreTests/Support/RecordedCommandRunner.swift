import Foundation
import Testing

@testable import BranchBarCore

/// A `CommandRunner` that answers from a stub table and fails the test on anything it was not
/// told about, so a packet cannot quietly start issuing a git or gh invocation that PLAN.md §5
/// never froze.
///
/// Matching is on the executable's **basename** (`git`, `gh` — never the resolved Homebrew or
/// `/usr/bin` path, which differs per machine), the exact argument array, and the working
/// directory when the stub names one.
public final class RecordedCommandRunner: CommandRunner, @unchecked Sendable {

    /// One canned answer.
    public struct Stub: Sendable {
        public var executableName: String
        public var arguments: [String]
        /// nil matches any working directory.
        public var workingDirectory: String?
        public var result: StubResult
        /// Held before answering, so a concurrency probe can observe overlap.
        public var delay: TimeInterval

        public init(
            executableName: String,
            arguments: [String],
            workingDirectory: String? = nil,
            result: StubResult,
            delay: TimeInterval = 0
        ) {
            self.executableName = executableName
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.result = result
            self.delay = delay
        }

        func matches(_ command: Command) -> Bool {
            guard (command.executable as NSString).lastPathComponent == executableName else { return false }
            guard command.arguments == arguments else { return false }
            if let workingDirectory, command.workingDirectory != workingDirectory { return false }
            return true
        }
    }

    public enum StubResult: Sendable {
        case output(CommandOutput)
        case failure(CommandError)

        /// Exit 0 with this stdout and no stderr — the common case.
        public static func stdout(_ text: String) -> StubResult {
            .output(CommandOutput(exitCode: 0, standardOutput: Data(text.utf8), standardError: Data()))
        }

        public static func exit(_ code: Int32, stdout: String = "", stderr: String = "") -> StubResult {
            .output(CommandOutput(exitCode: code, standardOutput: Data(stdout.utf8), standardError: Data(stderr.utf8)))
        }
    }

    private let lock = NSLock()
    private var stubs: [Stub] = []
    private var _calls: [Command] = []
    private var _inFlight = 0
    private var _peakInFlight = 0
    /// Off by default: only the concurrency tests pay for the extra bookkeeping.
    public var tracksConcurrency: Bool = false

    public init(stubs: [Stub] = []) {
        self.stubs = stubs
    }

    // MARK: Configuration

    public func stub(_ stub: Stub) {
        lock.lock(); defer { lock.unlock() }
        stubs.append(stub)
    }

    /// Convenience for the frozen git invocations: `git ["-C", path, …] → stdout`.
    public func stubGit(_ arguments: [String], stdout: String, delay: TimeInterval = 0) {
        stub(Stub(executableName: "git", arguments: arguments, result: .stdout(stdout), delay: delay))
    }

    public func stubGH(_ arguments: [String], stdout: String, delay: TimeInterval = 0) {
        stub(Stub(executableName: "gh", arguments: arguments, result: .stdout(stdout), delay: delay))
    }

    // MARK: Inspection

    /// Every command asked for, in the order it was asked.
    public var calls: [Command] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    public var callCount: Int { calls.count }

    /// Highest number of overlapping `run` calls seen; only meaningful with
    /// `tracksConcurrency = true`. Backs `peakConcurrencyNeverExceedsCap`.
    public var peakInFlight: Int {
        lock.lock(); defer { lock.unlock() }
        return _peakInFlight
    }

    public func calls(matchingExecutable name: String) -> [Command] {
        calls.filter { ($0.executable as NSString).lastPathComponent == name }
    }

    // MARK: CommandRunner

    public func run(_ command: Command) async throws -> CommandOutput {
        let stub: Stub? = lock.withLock {
            _calls.append(command)
            if tracksConcurrency {
                _inFlight += 1
                _peakInFlight = max(_peakInFlight, _inFlight)
            }
            return stubs.first { $0.matches(command) }
        }
        defer {
            if tracksConcurrency {
                lock.withLock { _inFlight -= 1 }
            }
        }

        guard let stub else {
            Issue.record("unstubbed command: \(command.displayString) (cwd \(command.workingDirectory ?? "-"))")
            throw CommandError.launchFailed(executable: command.executable, message: "unstubbed in RecordedCommandRunner")
        }

        if stub.delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(stub.delay * 1_000_000_000))
        }
        try Task.checkCancellation()

        switch stub.result {
        case .output(let output): return output
        case .failure(let error): throw error
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
