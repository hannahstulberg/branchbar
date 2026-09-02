import Foundation

/// Pure parser over `git worktree list --porcelain` stdout.
///
/// Records are separated by blank lines; each line is `key` or `key value`. Keys seen in the
/// wild: `worktree`, `HEAD`, `branch`, `bare`, `detached`, `locked` (optionally with a reason),
/// `prunable` (optionally with a reason). Paths can contain spaces, so only the first space
/// separates key from value.
public enum WorktreeListParser {

    /// OWNER: packet 2.1 — parse the porcelain into one `Worktree` per record, marking the first
    /// record `isPrimary`, leaving `branch` nil for a `detached` or `bare` record, and carrying
    /// the text after `locked` into `lockReason` when present.
    public static func parse(_ output: String) throws -> [Worktree] {
        fatalError("OWNER: packet 2.1 — parse `git worktree list --porcelain` into [Worktree], first record primary, detached and bare records carrying no branch.")
    }
}
