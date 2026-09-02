import Foundation

/// Package-level identity. Kept trivial on purpose: packet 0.2 is a toolchain spike,
/// not a feature packet.
public enum BranchBarCore {
    public static let version = "0.1.0"
}

/// Minimal file logger. The real one (packet 2.5) pairs this with `os.Logger`;
/// the spike needs only a durable line the orchestrator can grep from outside the app,
/// because an `LSUIElement` app has no stdout anyone can read.
public enum Log {
    /// `~/Library/Logs/BranchBar/BranchBar.log`
    public static let fileURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/BranchBar", isDirectory: true)
        .appendingPathComponent("BranchBar.log", isDirectory: false)

    private static let lock = NSLock()

    /// `ISO8601DateFormatter` is not `Sendable`; every read and write below happens
    /// while `lock` is held, which is the external synchronization Swift 6 asks for.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func info(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        append("[\(formatter.string(from: Date()))] \(message)\n")
    }

    /// Caller must hold `lock`.
    private static func append(_ line: String) {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
