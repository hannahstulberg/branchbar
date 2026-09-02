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

    /// OWNER: packet 2.1 — split each non-empty line of `refs/heads` output on U+001F into
    /// exactly seven fields, parse field 3 as a unix timestamp, and return one `ParsedBranchRef`
    /// per line in the order git printed them, ignoring blank lines and throwing on a line whose
    /// field count is not seven.
    public static func parseBranches(_ output: String) throws -> [ParsedBranchRef] {
        fatalError("OWNER: packet 2.1 — parse refs/heads for-each-ref rows into [ParsedBranchRef], splitting on U+001F and reading field 3 as a unix timestamp.")
    }

    /// OWNER: packet 2.1 — same split over the `refs/remotes/` output, three fields per line,
    /// returning one `ParsedRemoteRef` per line and skipping the `refs/remotes/<remote>/HEAD`
    /// symbolic ref.
    public static func parseRemoteRefs(_ output: String) throws -> [ParsedRemoteRef] {
        fatalError("OWNER: packet 2.1 — parse refs/remotes for-each-ref rows into [ParsedRemoteRef], skipping the remote HEAD symbolic ref.")
    }

    /// OWNER: packet 2.1 — return nil when `upstreamShort` is empty (no upstream) and otherwise
    /// an `Upstream` whose `ahead`/`behind` come from the `ahead N`/`behind N` clauses of `track`
    /// and whose `isGone` is `track == "gone"`; never decide "no upstream" from `track`.
    public static func upstream(from row: ParsedBranchRef) -> Upstream? {
        fatalError("OWNER: packet 2.1 — map a ParsedBranchRef to Upstream?, using upstreamShort for existence and track only for ahead/behind/gone.")
    }
}
