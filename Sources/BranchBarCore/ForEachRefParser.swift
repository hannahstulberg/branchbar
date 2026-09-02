import Foundation

/// One row of `git for-each-ref … -- refs/heads`, fields split on U+001F.
/// PLAN.md §5 format: `%(refname)%1f%(objectname)%1f%(committerdate:unix)%1f%(upstream:short)%1f%(upstream:remotename)%1f%(upstream:track,nobracket)%1f%(HEAD)`
public struct ParsedBranchRef: Hashable, Codable, Sendable {
    /// Full ref, e.g. `refs/heads/main`. Kept whole so a branch named `main` is never confused
    /// with `refs/tags/main` (PLAN.md §7 tag-name collision case).
    public var refName: String
    public var objectName: String
    public var committerDate: Date
    /// `%(upstream:short)` — empty when there is no upstream. The **only** way to tell
    /// "in sync" from "no upstream"; the track field is empty for both.
    public var upstreamShort: String
    public var upstreamRemoteName: String
    /// `%(upstream:track,nobracket)`: "", "ahead 2", "behind 1", "ahead 2, behind 1", or "gone".
    public var track: String
    /// `%(HEAD)` is `*` for the checked-out branch of this worktree.
    public var isHead: Bool

    public init(
        refName: String,
        objectName: String,
        committerDate: Date,
        upstreamShort: String,
        upstreamRemoteName: String,
        track: String,
        isHead: Bool
    ) {
        self.refName = refName
        self.objectName = objectName
        self.committerDate = committerDate
        self.upstreamShort = upstreamShort
        self.upstreamRemoteName = upstreamRemoteName
        self.track = track
        self.isHead = isHead
    }

    /// `refs/heads/feature/x` → `feature/x`.
    public var branchName: String {
        refName.hasPrefix("refs/heads/") ? String(refName.dropFirst("refs/heads/".count)) : refName
    }
}

/// One row of `git for-each-ref … -- refs/remotes/`.
/// Format: `%(refname)%1f%(objectname)%1f%(committerdate:unix)`
public struct ParsedRemoteRef: Hashable, Codable, Sendable {
    /// Full ref, e.g. `refs/remotes/origin/main`.
    public var refName: String
    public var objectName: String
    public var committerDate: Date

    public init(refName: String, objectName: String, committerDate: Date) {
        self.refName = refName
        self.objectName = objectName
        self.committerDate = committerDate
    }

    /// `refs/remotes/origin/main` → `origin/main`.
    public var shortName: String {
        refName.hasPrefix("refs/remotes/") ? String(refName.dropFirst("refs/remotes/".count)) : refName
    }
}

/// Pure parser over `git for-each-ref` stdout. No seams: it takes the string the runner returned.
public enum ForEachRefParser {

    /// A row that does not match the frozen format. Recoverable: `RepoLoader` reports it as a
    /// `RepoError(stage: .branches)` rather than trapping and taking the refresh down with it.
    public enum ParseError: Error, Hashable, Sendable, CustomStringConvertible {
        case wrongFieldCount(expected: Int, found: Int, line: String)
        case malformedTimestamp(field: String, line: String)

        public var description: String {
            switch self {
            case let .wrongFieldCount(expected, found, line):
                return "for-each-ref row has \(found) fields, expected \(expected): \(line)"
            case let .malformedTimestamp(field, line):
                return "for-each-ref row carries a non-numeric committerdate:unix `\(field)`: \(line)"
            }
        }
    }

    /// U+001F, what `%1f` emits. Splitting on the four literal characters `%1f` would yield one
    /// field per row (`reflogFieldsSplitOnUnitSeparatorNotLiteralPercent1f`, the same footgun).
    static let unitSeparator: Character = "\u{1F}"

    /// Every non-blank line, with a trailing carriage return trimmed. Blank lines are not rows.
    static func rows(_ output: String) -> [String] {
        output
            .components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty }
    }

    static func fields(_ line: String, expected: Int) throws -> [String] {
        let parts = line
            .split(separator: unitSeparator, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == expected else {
            throw ParseError.wrongFieldCount(expected: expected, found: parts.count, line: line)
        }
        return parts
    }

    static func unixDate(_ field: String, line: String) throws -> Date {
        guard let seconds = TimeInterval(field.trimmingCharacters(in: .whitespaces)) else {
            throw ParseError.malformedTimestamp(field: field, line: line)
        }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Split each non-empty line of `refs/heads` output on U+001F into exactly seven fields,
    /// parse field 3 as a unix timestamp, and return one row per line in git's order.
    public static func parseBranches(_ output: String) throws -> [ParsedBranchRef] {
        try rows(output).map { line in
            let f = try fields(line, expected: 7)
            return ParsedBranchRef(
                refName: f[0],
                objectName: f[1],
                committerDate: try unixDate(f[2], line: line),
                upstreamShort: f[3],
                upstreamRemoteName: f[4],
                track: f[5],
                // `%(HEAD)` prints `*` for the checked-out branch and a single space otherwise.
                isHead: f[6].trimmingCharacters(in: .whitespaces) == "*"
            )
        }
    }

    /// The same split over the `refs/remotes/` output, three fields per line, skipping the
    /// `refs/remotes/<remote>/HEAD` symbolic ref — it is not a remote-tracking branch.
    public static func parseRemoteRefs(_ output: String) throws -> [ParsedRemoteRef] {
        try rows(output).compactMap { line in
            let f = try fields(line, expected: 3)
            guard !isRemoteHeadSymbolicRef(f[0]) else { return nil }
            return ParsedRemoteRef(
                refName: f[0],
                objectName: f[1],
                committerDate: try unixDate(f[2], line: line)
            )
        }
    }

    /// `refs/remotes/origin/HEAD` — exactly two components under `refs/remotes/`, the second
    /// being `HEAD`. A branch legitimately called `origin/feature/HEAD` is three, and stays.
    static func isRemoteHeadSymbolicRef(_ refName: String) -> Bool {
        guard refName.hasPrefix("refs/remotes/") else { return false }
        let components = refName.dropFirst("refs/remotes/".count).split(separator: "/")
        return components.count == 2 && components.last == "HEAD"
    }

    /// Existence comes from `upstream:short` and nothing else: `%(upstream:track,nobracket)` is
    /// empty for "in sync" **and** for "no upstream"
    /// (`inSyncAndNoUpstreamAreDistinguishedByUpstreamShortNotTrack`). `track` only carries the
    /// ahead/behind counts and `gone`.
    public static func upstream(from row: ParsedBranchRef) -> Upstream? {
        guard !row.upstreamShort.isEmpty else { return nil }

        let track = row.track.trimmingCharacters(in: .whitespaces)
        var ahead = 0
        var behind = 0
        var isGone = false

        for clause in track.components(separatedBy: ",") {
            let words = clause.split(separator: " ").map(String.init)
            guard let keyword = words.first else { continue }
            switch keyword {
            case "gone":
                isGone = true
            case "ahead":
                ahead = words.count > 1 ? Int(words[1]) ?? 0 : 0
            case "behind":
                behind = words.count > 1 ? Int(words[1]) ?? 0 : 0
            default:
                continue
            }
        }

        return Upstream(
            ref: row.upstreamShort,
            remote: row.upstreamRemoteName,
            ahead: ahead,
            behind: behind,
            isGone: isGone
        )
    }
}
