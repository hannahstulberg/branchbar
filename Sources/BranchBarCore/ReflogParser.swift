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

    /// OWNER: packet 2.1 — split each non-empty line on U+001F into three fields and return one
    /// `ReflogShowEntry` per line in git's order (newest first), throwing on a line whose field
    /// count is not three.
    public static func parse(_ output: String) throws -> [ReflogShowEntry] {
        fatalError("OWNER: packet 2.1 — split `git reflog show` rows on U+001F into [ReflogShowEntry], newest first.")
    }

    /// OWNER: packet 2.1 — extract the unix timestamp from between the braces of `%gd` and apply
    /// the same deletion-boundary rule as the file reader, returning the newest `update by push`
    /// entry above the boundary as a `ReflogObservation`, or nil when there is none.
    public static func observation(from entries: [ReflogShowEntry]) -> ReflogObservation? {
        fatalError("OWNER: packet 2.1 — reduce [ReflogShowEntry] to the newest push observation, reading the timestamp from inside the braces of %gd and stopping at the deletion boundary.")
    }
}
