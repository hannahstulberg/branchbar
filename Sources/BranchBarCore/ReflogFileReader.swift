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

    /// Only the last this-many bytes of a reflog are read (codex MAJOR 15). The file grows
    /// without a bound git enforces, and the fact this reader wants lives in its newest lines;
    /// 64 KB is several hundred entries.
    public static let maximumTailBytes = 64 * 1024

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
        try reading(commonDirectory: commonDirectory, remote: remote, branch: branch).observation
    }

    /// `observation`, plus the third answer this file can give (codex round 3, MAJOR 7).
    ///
    /// Absence is decided by the **open**, not by a `fileExists` preflight in front of it
    /// (BLOCKER 2): `statRegularFile` returns nil only for a path that is not there, throws for
    /// one that is there and unreadable or is not a regular file, and never follows a symlink or
    /// blocks on a FIFO.
    public func reading(commonDirectory: String, remote: String, branch: String) throws -> ReflogReading {
        let path = Self.reflogPath(commonDirectory: commonDirectory, remote: remote, branch: branch)
        guard try fileSystem.statRegularFile(atPath: path) != nil else { return .nothingObserved }
        let data = try fileSystem.readFileTail(atPath: path, maximumBytes: Self.maximumTailBytes)
        return Self.read(Self.completeLines(in: data))
    }

    /// The window as text, minus a leading partial line (codex MAJOR 15).
    ///
    /// A tail read starts wherever `size - maximumTailBytes` lands, which is usually the middle
    /// of a line. That fragment can still satisfy the parser — the header's last two fields are a
    /// unix time and a timezone whether or not the two OIDs in front of them survived the cut —
    /// and would then report an OID taken from the middle of an entry. So a window that filled
    /// the bound is parsed from its first newline: only whole lines the file actually contains.
    /// A window smaller than the bound is the whole file and keeps its first line.
    static func completeLines(in data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        guard data.count >= Self.maximumTailBytes else { return text }
        guard let firstBreak = text.firstIndex(of: "\n") else { return "" }
        return String(text[text.index(after: firstBreak)...])
    }

    /// Walk the lines newest-first, stop at the first line whose **new** OID is all zeros (the
    /// deletion boundary, so a push before a delete-and-recreate is never attributed to the new
    /// incarnation), and return the first `update by push` line above that boundary. An empty,
    /// fetch-only, or deletion-only file yields nil, which sends `PushInfoDeriver` to the
    /// tip-commit-date fallback.
    public static func parse(_ contents: String, now: Date = Date()) -> ReflogObservation? {
        read(contents, now: now).observation
    }

    /// `parse`, with the third answer kept apart from the second (codex round 3, MAJOR 7).
    ///
    /// Every malformed line used to be skipped, which walked the reader **past** corruption: a
    /// torn or crafted deletion entry was ignored and an older pre-deletion push was then
    /// attributed to a recreated branch. A nonempty line this reader cannot vouch for is now an
    /// uncertainty boundary — the walk stops there and says so — because the thing below it could
    /// be the deletion that makes everything above it a lie.
    public static func read(_ contents: String, now: Date = Date()) -> ReflogReading {
        for line in contents.components(separatedBy: "\n").reversed() {
            let trimmed = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if trimmed.isEmpty { continue }
            guard let entry = Entry(line: trimmed, now: now) else { return .uncertain }
            // Only the NEW OID is a boundary: an all-zero OLD OID is a branch creation
            // (`creationLineWithAllZeroOldOIDIsNotADeletionBoundary`).
            guard !entry.newOID.isAllZeroOID else { return .nothingObserved }
            guard entry.isPush else { continue }
            return .observed(ReflogObservation(pushedAt: entry.timestamp, newOID: entry.newOID))
        }
        return .nothingObserved
    }

    /// One reflog line, split the way the format guarantees rather than by field index: the
    /// author's name carries spaces, so the unix time and the timezone are counted from the end
    /// of the header (`reflogFileLastUsablePushLineParsesUnixTimestampFromField5`).
    struct Entry {
        var newOID: String
        var timestamp: Date
        var message: String

        /// `git push` writes exactly this, with nothing before it. Anything else is another
        /// operation wearing the same first two words (codex round 3, MAJOR 7).
        static let pushMessagePrefix = "update by push"

        /// The line's message is a push record: the documented prefix, and then either the end of
        /// the message or the separator git puts before its detail — never an arbitrary
        /// continuation such as `update by pushbot`.
        var isPush: Bool {
            guard message.hasPrefix(Self.pushMessagePrefix) else { return false }
            let rest = message.dropFirst(Self.pushMessagePrefix.count)
            guard let next = rest.first else { return true }
            return next == " " || next == ":" || next == "\t"
        }

        /// A future timestamp is not evidence of a past push, and neither is one before git
        /// existed. One day of slack absorbs a clock skew between this Mac and the machine that
        /// wrote the line; anything beyond it is a line this reader will not vouch for.
        static let futureSlack: TimeInterval = 24 * 60 * 60

        /// 40 hexadecimal characters for SHA-1, 64 for SHA-256, and nothing else — not "whatever
        /// sat in field 2". An unvalidated OID let a line whose fields had shifted (a tail window
        /// opened mid-line, a torn write) report a fragment of a name as the pushed commit, which
        /// then decided `originMovedSince`.
        static func isValidOID(_ text: String) -> Bool {
            guard text.utf8.count == 40 || text.utf8.count == 64 else { return false }
            return text.unicodeScalars.allSatisfy { scalar in
                ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar) || ("A"..."F").contains(scalar)
            }
        }

        init?(line rawLine: String, now: Date = Date()) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            guard !line.isEmpty else { return nil }

            let halves = line.components(separatedBy: "\t")
            guard halves.count >= 2 else { return nil }
            let header = halves[0].split(separator: " ").map(String.init)
            // old OID, new OID, author name (≥ 1 word), email, unix time, timezone.
            guard header.count >= 6, let seconds = TimeInterval(header[header.count - 2]) else { return nil }
            guard Self.isValidOID(header[0]), Self.isValidOID(header[1]) else { return nil }
            guard seconds.isFinite, seconds > 0,
                  seconds < now.timeIntervalSince1970 + Self.futureSlack
            else { return nil }

            newOID = header[1]
            timestamp = Date(timeIntervalSince1970: seconds)
            message = halves.dropFirst().joined(separator: "\t")
        }
    }
}

/// What one reflog file said, with "nothing to report" and "this file cannot be trusted" kept
/// apart (codex round 3, MAJOR 7).
///
/// The third case is the one that did not exist: a malformed nonempty line was skipped, so a torn
/// or crafted deletion entry let an older push be attributed to a branch that had been deleted and
/// recreated since. The row that reads this says its push history is unreadable rather than
/// reporting the date it found above the corruption.
public enum ReflogReading: Hashable, Sendable {
    /// A usable `update by push` line above the deletion boundary.
    case observed(ReflogObservation)
    /// The file is absent, empty, fetch-only, deletion-only, or expired: no push to report, and
    /// nothing wrong with the file.
    case nothingObserved
    /// A nonempty line this reader could not parse or could not validate. The walk stopped there.
    case uncertain

    public var observation: ReflogObservation? {
        if case .observed(let observation) = self { return observation }
        return nil
    }

    public var isUncertain: Bool { self == .uncertain }
}

extension String {
    /// `git push --delete` writes a line whose new OID is all zeros; the message still says
    /// `update by push`, so only the OID can tell a deletion from a push.
    var isAllZeroOID: Bool {
        !isEmpty && allSatisfy { $0 == "0" }
    }
}
