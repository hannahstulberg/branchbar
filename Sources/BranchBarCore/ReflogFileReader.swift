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

    /// OWNER: packet 2.1 — read the reflog file for this remote-tracking branch and return
    /// `parse`'s result, returning nil (never throwing) when the file is absent, and throwing
    /// only when the file exists but cannot be read.
    public func observation(commonDirectory: String, remote: String, branch: String) throws -> ReflogObservation? {
        fatalError("OWNER: packet 2.1 — read <common dir>/logs/refs/remotes/<remote>/<branch> and return the newest usable push observation, nil when the file is absent or holds no usable line.")
    }

    /// OWNER: packet 2.1 — walk the lines newest-first, stop at the first line whose **new** OID
    /// is all zeros (the deletion boundary, so a push before a delete-and-recreate is never
    /// attributed to the new incarnation), and return the first `update by push` line above that
    /// boundary as `ReflogObservation(pushedAt: field 5, newOID: field 2)`; return nil for an
    /// empty, fetch-only, or deletion-only file.
    public static func parse(_ contents: String) -> ReflogObservation? {
        fatalError("OWNER: packet 2.1 — parse reflog file contents newest-first, stopping at the all-zero-new-OID deletion boundary, returning the newest `update by push` line above it.")
    }
}
