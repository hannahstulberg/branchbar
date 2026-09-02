import Foundation

/// Finds repos. PLAN.md §3: the home root is walked breadth-first to depth 6 skipping every
/// hidden directory and the literal skip list; "Add folder…" roots are walked **recursively with
/// no depth limit** so a deep repo, a `~/Library/CloudStorage` folder, or a nested repo inside a
/// monorepo is reachable by adding it. Symlinks are not followed and bare repos are out of scope.
public struct RepoScanner: Sendable {
    private let fileSystem: FileSystem

    public init(fileSystem: FileSystem) {
        self.fileSystem = fileSystem
    }

    /// OWNER: packet 2.4 — walk `policy.homeRoot` breadth-first to `policy.maxDepth` and every
    /// `policy.extraRoots` entry with no depth limit, in both cases skipping hidden directories
    /// and `policy.skipDirectoryNames`, never following symlinks, never descending into a
    /// directory that already yielded a repo, classifying a `.git` **file** by its `gitdir:` line
    /// into a worktree checkout or a submodule and excluding both, deduping the survivors by the
    /// `.git` common directory, and returning a `ScanResult` that counts every directory examined,
    /// every unreadable directory by path, every depth cut, and every hidden skip.
    public func scan(policy: ScanPolicy) throws -> ScanResult {
        fatalError("OWNER: packet 2.4 — BFS the home root to depth 6 and every extra root with no limit, skipping hidden and listed directories, excluding worktree checkouts and submodules, deduping by common dir, and reporting unreadable, depth-cut, and hidden counts.")
    }

    /// OWNER: packet 2.4 — read a `.git` file's `gitdir: <path>` line and classify the checkout:
    /// a path containing `/worktrees/` is a linked worktree, one containing `/modules/` is a
    /// submodule, anything else is a candidate repo whose common dir is that path.
    public static func classifyGitFile(contents: String) -> GitFileClassification {
        fatalError("OWNER: packet 2.4 — classify a `.git` file's gitdir: line as a worktree checkout, a submodule, or a candidate repo.")
    }

    public enum GitFileClassification: Hashable, Codable, Sendable {
        case worktreeCheckout(commonDirectory: String)
        case submodule(gitDirectory: String)
        case candidate(gitDirectory: String)
        case unrecognized
    }
}
