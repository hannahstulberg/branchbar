import Foundation

/// One row of the secondary fallback,
/// `git reflog show --date=unix --format='%gd%x1f%gs%x1f%H' refs/remotes/<upstream>`.
///
/// Two footguns are frozen here: the format uses `%x1f`, because `%1f` is a `for-each-ref` atom
/// only, and the invocation carries **no** `--`, because `reflog show` silently returns zero rows
/// and exit 0 when one is present (verified on 2.39.5 and 2.52).
public struct ReflogShowEntry: Hashable, Codable, Sendable {
    /// `%gd` under `--date=unix`, e.g. `origin/main@{1788316926}`.
    public var selector: String
    /// `%gs`, e.g. `update by push`.
    public var message: String
    /// `%H`, the OID the ref pointed at after the entry.
    public var objectName: String

    public init(selector: String, message: String, objectName: String) {
        self.selector = selector
        self.message = message
        self.objectName = objectName
    }
}

/// Pure parser over `git reflog show` stdout.
public enum ReflogParser {

    /// A row that does not match the frozen `%gd%x1f%gs%x1f%H` format. Recoverable, never a trap.
    public enum ParseError: Error, Hashable, Sendable, CustomStringConvertible {
        case wrongFieldCount(expected: Int, found: Int, line: String)

        public var description: String {
            switch self {
            case let .wrongFieldCount(expected, found, line):
                return "reflog show row has \(found) fields, expected \(expected): \(line)"
            }
        }
    }

    /// Split each non-empty line on U+001F into three fields and return one entry per line in
    /// git's order, which is newest first.
    public static func parse(_ output: String) throws -> [ReflogShowEntry] {
        try output
            .components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty }
            .map { line in
                let fields = line
                    .split(separator: "\u{1F}", omittingEmptySubsequences: false)
                    .map(String.init)
                guard fields.count == 3 else {
                    throw ParseError.wrongFieldCount(expected: 3, found: fields.count, line: line)
                }
                return ReflogShowEntry(selector: fields[0], message: fields[1], objectName: fields[2])
            }
    }

    /// Reduce the entries to the newest push observation, applying the same deletion-boundary
    /// rule as the file reader: the walk stops at the first all-zero OID, and the first
    /// `update by push` above it wins. The timestamp comes from inside the braces of `%gd`,
    /// which under `--date=unix` reads `origin/main@{1788317856}`.
    public static func observation(from entries: [ReflogShowEntry]) -> ReflogObservation? {
        for entry in entries {
            guard !entry.objectName.isAllZeroOID else { return nil }
            guard entry.message.hasPrefix("update by push") else { continue }
            guard let pushedAt = unixTime(inSelector: entry.selector) else { continue }
            return ReflogObservation(pushedAt: pushedAt, newOID: entry.objectName)
        }
        return nil
    }

    /// `origin/feature/2026-09@{1788100000}` → 1788100000. The ref's own name can carry digits,
    /// slashes, and dashes, so the search anchors on the last `@{` and the trailing `}`.
    static func unixTime(inSelector selector: String) -> Date? {
        guard selector.hasSuffix("}"),
              let open = selector.range(of: "@{", options: .backwards) else { return nil }
        let digits = selector[open.upperBound..<selector.index(before: selector.endIndex)]
        guard let seconds = TimeInterval(digits) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
