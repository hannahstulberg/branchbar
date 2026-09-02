import Foundation

/// Reads `<git-common-dir>/logs/refs/remotes/<remote>/<branch>` — the file that records what
/// **this clone** observed. PLAN.md §3 and the DECISION-LOG: it says nothing about pushes from
/// another machine, and lines expire at 90 days reachable / 30 days unreachable.
///
/// Line format: `<old OID> <new OID> <author> <email> <unixtime> <tz>\t<message>`.
public struct ReflogFileReader: Sendable {
    private let fileSystem: FileSystem

    public init(fileSystem: FileSystem) {
        self.fileSystem = fileSystem
    }

    /// Path this reader reads, exposed so `RepoLoader` can report an unreadable file by name.
    public static func reflogPath(commonDirectory: String, remote: String, branch: String) -> String {
        (commonDirectory as NSString)
            .appendingPathComponent("logs/refs/remotes/\(remote)/\(branch)")
    }

    /// Read the reflog file for this remote-tracking branch and return `parse`'s result.
    ///
    /// An absent file is nil and never an error — a branch that was never pushed has no reflog —
    /// while a file that exists and cannot be read throws, so `RepoLoader` can surface it as a
    /// `RepoError(stage: .reflog)` instead of silently reporting "never pushed".
    public func observation(commonDirectory: String, remote: String, branch: String) throws -> ReflogObservation? {
        let path = Self.reflogPath(commonDirectory: commonDirectory, remote: remote, branch: branch)
        guard fileSystem.fileExists(atPath: path) else { return nil }
        let data = try fileSystem.readFile(atPath: path)
        return Self.parse(String(decoding: data, as: UTF8.self))
    }

    /// Walk the lines newest-first, stop at the first line whose **new** OID is all zeros (the
    /// deletion boundary, so a push before a delete-and-recreate is never attributed to the new
    /// incarnation), and return the first `update by push` line above that boundary. An empty,
    /// fetch-only, or deletion-only file yields nil, which sends `PushInfoDeriver` to the
    /// tip-commit-date fallback.
    public static func parse(_ contents: String) -> ReflogObservation? {
        for line in contents.components(separatedBy: "\n").reversed() {
            guard let entry = Entry(line: line) else { continue }
            // Only the NEW OID is a boundary: an all-zero OLD OID is a branch creation
            // (`creationLineWithAllZeroOldOIDIsNotADeletionBoundary`).
            guard !entry.newOID.isAllZeroOID else { return nil }
            guard entry.message.hasPrefix("update by push") else { continue }
            return ReflogObservation(pushedAt: entry.timestamp, newOID: entry.newOID)
        }
        return nil
    }

    /// One reflog line, split the way the format guarantees rather than by field index: the
    /// author's name carries spaces, so the unix time and the timezone are counted from the end
    /// of the header (`reflogFileLastUsablePushLineParsesUnixTimestampFromField5`).
    struct Entry {
        var newOID: String
        var timestamp: Date
        var message: String

        init?(line rawLine: String) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            guard !line.isEmpty else { return nil }

            let halves = line.components(separatedBy: "\t")
            guard halves.count >= 2 else { return nil }
            let header = halves[0].split(separator: " ").map(String.init)
            // old OID, new OID, author name (≥ 1 word), email, unix time, timezone.
            guard header.count >= 6, let seconds = TimeInterval(header[header.count - 2]) else { return nil }

            newOID = header[1]
            timestamp = Date(timeIntervalSince1970: seconds)
            message = halves.dropFirst().joined(separator: "\t")
        }
    }
}

extension String {
    /// `git push --delete` writes a line whose new OID is all zeros; the message still says
    /// `update by push`, so only the OID can tell a deletion from a push.
    var isAllZeroOID: Bool {
        !isEmpty && allSatisfy { $0 == "0" }
    }
}
