import Foundation

/// Package-level identity. Kept trivial on purpose: packet 0.2 is a toolchain spike,
/// not a feature packet.
public enum BranchBarCore {
    public static let version = "0.1.0"
}

/// Text a human reads, as opposed to the JSON a machine reads.
///
/// A repository owns its own directory name, its branch names, and its paths, and two of
/// BranchBar's outputs are plain text a terminal or a log reader interprets rather than displays:
/// `branchbar-cli`'s table and `~/Library/Logs/BranchBar/BranchBar.log`. Both printed those names
/// verbatim (codex round 2, MAJOR 10 and MINOR 4). A directory called
/// `main\n[2026-01-01T00:00:00.000Z] everything is fine` forges a log entry; one carrying ESC
/// forges table rows, erases output already printed, retitles the window, or reaches a
/// terminal-specific escape action.
///
/// Only the human-readable path is escaped. `--json` keeps exact values, because a machine reads
/// those and a JSON string already has its own escaping.
public enum SafeText {
    /// C0, DEL, and C1 escaped; everything else, non-ASCII and emoji included, untouched.
    ///
    /// `\n`, `\r`, and `\t` get their familiar two-character forms because a path or branch name
    /// carrying one is a thing a person may need to recognise; everything else becomes
    /// `\u{XX}` so the escaped text says exactly which scalar was there.
    public static func escapingControlScalars(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isControlScalar) else { return text }
        var escaped = ""
        escaped.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            guard isControlScalar(scalar) else {
                escaped.unicodeScalars.append(scalar)
                continue
            }
            switch scalar {
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped += String(format: "\\u{%02X}", scalar.value)
            }
        }
        return escaped
    }

    /// C0 (U+0000–U+001F), DEL (U+007F), and C1 (U+0080–U+009F). C1 is in the list because
    /// U+009B is a single-scalar CSI that some terminals honour exactly like `ESC [`.
    public static func isControlScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F)
    }

    /// Left-aligned columns padded to the widest cell, every cell escaped first — so the widths
    /// are measured on what is actually printed and a cell can never contribute a row of its own.
    public static func table(header: [String], rows: [[String]]) -> String {
        let header = header.map(escapingControlScalars)
        let rows = rows.map { $0.map(escapingControlScalars) }
        let all = [header] + rows
        let columns = header.count
        var widths = [Int](repeating: 0, count: columns)
        for row in all {
            for index in 0..<columns { widths[index] = max(widths[index], row[index].count) }
        }
        func render(_ row: [String]) -> String {
            (0..<columns).map { index in
                index == columns - 1
                    ? row[index]
                    : row[index].padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }
            .joined(separator: "  ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " "))
        }
        return ([render(header), render(widths.map { String(repeating: "-", count: $0) })]
            + rows.map(render)).joined(separator: "\n")
    }
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

    /// Past this, the log is truncated to its newest `retainedFileBytes` (codex MINOR 4).
    public static let maximumFileBytes = 5 * 1024 * 1024
    public static let retainedFileBytes = 1 * 1024 * 1024

    /// One log entry, terminator included.
    ///
    /// The message is escaped because the log's own grammar is "one line per entry, starting with
    /// a timestamp": a repository path carrying a newline used to be able to write an entry of its
    /// own, complete with a plausible timestamp (codex round 2, MINOR 4).
    public static func line(_ message: String, at date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return "[\(formatter.string(from: date))] \(SafeText.escapingControlScalars(message))\n"
    }

    /// Truncates the log to its newest `retainedFileBytes` once it passes `maximumFileBytes`.
    ///
    /// A menu-bar app refreshes for as long as the machine is awake, and the file had no bound at
    /// all. Keeping the **tail** rather than starting empty is what makes the log useful for the
    /// thing it exists for: reading what happened just before something went wrong. The first
    /// partial line is dropped so the file still parses one entry per line.
    public static func capIfNeeded(at url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.intValue > maximumFileBytes,
              let handle = try? FileHandle(forUpdating: url)
        else { return }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return }
        let keep = UInt64(retainedFileBytes)
        guard end > keep else { return }
        try? handle.seek(toOffset: end - keep)
        guard var tail = try? handle.readToEnd() else { return }
        if let firstBreak = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = Data(tail[tail.index(after: firstBreak)...])
        }
        try? handle.truncate(atOffset: 0)
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: tail)
    }

    public static func info(_ message: String) {
        // `line` takes the lock itself, so it is built before `append`'s critical section.
        let entry = Self.line(message, at: Date())
        lock.lock()
        defer { lock.unlock() }
        capIfNeeded(at: fileURL)
        append(entry)
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
