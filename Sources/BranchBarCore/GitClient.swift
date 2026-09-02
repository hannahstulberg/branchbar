import Foundation

/// Every git invocation PLAN.md §5 freezes, and nothing else. Owns the environment
/// (`LC_ALL=C`, `GIT_OPTIONAL_LOCKS=0`) and the `-C <repo>` form, and hands raw stdout to the
/// pure parsers so the parsers stay testable without a process.
public struct GitClient: Sendable {
    private let runner: CommandRunner
    private let gitPath: String
    private let timeout: TimeInterval

    /// PLAN.md §5. `LC_ALL=C` keeps the output parseable; `GIT_OPTIONAL_LOCKS=0` stops a read
    /// from taking `index.lock` while the user is mid-commit in another tool.
    public static let frozenEnvironment: [String: String] = [
        "LC_ALL": "C",
        "GIT_OPTIONAL_LOCKS": "0",
    ]

    /// `gitPath` is resolved outside this type; the GUI PATH has no Homebrew.
    // depends on ToolLocator (packet 0.3)
    public init(runner: CommandRunner, gitPath: String, timeout: TimeInterval = RefreshPolicy.default.gitTimeout) {
        self.runner = runner
        self.gitPath = gitPath
        self.timeout = timeout
    }

    /// OWNER: packet 2.1 — run
    /// `git -C <path> rev-parse --path-format=absolute --git-common-dir --show-toplevel`
    /// and return the two absolute paths it prints, in that order.
    public func identity(at path: String) async throws -> (commonDirectory: String, topLevel: String) {
        fatalError("OWNER: packet 2.1 — run `git rev-parse --path-format=absolute --git-common-dir --show-toplevel` and return the common dir and top level.")
    }

    /// OWNER: packet 2.1 — run `git -C <path> config --get remote.origin.url`, returning the
    /// trimmed URL, or nil when the key is unset (git exits 1 with empty stdout, which is
    /// `PRUnavailableReason.noRemote`, not a command failure).
    public func remoteOriginURL(at path: String) async throws -> String? {
        fatalError("OWNER: packet 2.1 — run `git config --get remote.origin.url` and return the URL or nil when the key is unset.")
    }

    /// OWNER: packet 2.1 — run the frozen `for-each-ref … -- refs/heads` invocation and return
    /// `ForEachRefParser.parseBranches` of its stdout.
    public func branchRefs(at path: String) async throws -> [ParsedBranchRef] {
        fatalError("OWNER: packet 2.1 — run the frozen refs/heads for-each-ref and return ForEachRefParser.parseBranches of stdout.")
    }

    /// OWNER: packet 2.1 — run the frozen `for-each-ref … -- refs/remotes/` invocation and return
    /// `ForEachRefParser.parseRemoteRefs` of its stdout.
    public func remoteRefs(at path: String) async throws -> [ParsedRemoteRef] {
        fatalError("OWNER: packet 2.1 — run the frozen refs/remotes for-each-ref and return ForEachRefParser.parseRemoteRefs of stdout.")
    }

    /// OWNER: packet 2.1 — run `git -C <path> worktree list --porcelain` and return
    /// `WorktreeListParser.parse` of its stdout.
    public func worktrees(at path: String) async throws -> [Worktree] {
        fatalError("OWNER: packet 2.1 — run `git worktree list --porcelain` and return WorktreeListParser.parse of stdout.")
    }

    /// OWNER: packet 2.1 — run
    /// `git -C <path> reflog show --date=unix --format='%gd%x1f%gs%x1f%H' <ref>` with **no** `--`
    /// separator, and return `ReflogParser.parse` of its stdout; an empty stdout with exit 0 is an
    /// empty list, not an error.
    public func reflogShow(at path: String, ref: String) async throws -> [ReflogShowEntry] {
        fatalError("OWNER: packet 2.1 — run `git reflog show` WITHOUT a `--` separator and return ReflogParser.parse of stdout.")
    }
}
