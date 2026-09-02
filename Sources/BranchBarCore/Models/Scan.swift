import Foundation

/// What the home scan is allowed to walk. PLAN.md §3 and §5.
///
/// The product promise is "repos BranchBar found under your home folder, or folders you added",
/// so the policy is data the scan summary can read back to the user rather than constants
/// buried in `RepoScanner`.
public struct ScanPolicy: Hashable, Codable, Sendable {
    /// Absolute path of the home folder. Walked breadth-first to `maxDepth`.
    public var homeRoot: String
    /// "Add folder…" roots, walked **recursively with no depth limit** (PLAN.md §3), same skip list.
    public var extraRoots: [String]
    /// Applies to `homeRoot` only. PLAN.md §2 found 4 real repos at depth 5–7 on this machine.
    public var maxDepth: Int
    /// Skip every directory whose name starts with `.`, except the `.git` marker itself.
    public var skipHiddenDirectories: Bool
    /// Literal skip list, frozen verbatim from PLAN.md §5.
    public var skipDirectoryNames: [String]
    /// Constant `false` for the home scan: no descent into a repo that was already found.
    public var descendIntoRepos: Bool

    public static let defaultSkipDirectoryNames: [String] = [
        "Library", "Applications", "Pictures", "Movies", "Music", "Public",
        "node_modules", "vendor", "Pods", "DerivedData", "build", "dist",
        "target", "venv", "site-packages", "__pycache__", "go/pkg",
    ]

    public init(
        homeRoot: String,
        extraRoots: [String] = [],
        maxDepth: Int = 6,
        skipHiddenDirectories: Bool = true,
        skipDirectoryNames: [String] = ScanPolicy.defaultSkipDirectoryNames,
        descendIntoRepos: Bool = false
    ) {
        self.homeRoot = homeRoot
        self.extraRoots = extraRoots
        self.maxDepth = maxDepth
        self.skipHiddenDirectories = skipHiddenDirectories
        self.skipDirectoryNames = skipDirectoryNames
        self.descendIntoRepos = descendIntoRepos
    }
}

/// A repo the scan kept, before any git command has run against it. PLAN.md §5.
public struct DiscoveredRepo: Hashable, Codable, Sendable {
    /// Absolute working-tree path.
    public var path: String
    /// From `git rev-parse --git-common-dir`; the dedupe key.
    public var id: RepoID

    public init(path: String, id: RepoID) {
        self.path = path
        self.id = id
    }
}

/// Everything the scan summary needs to say what it did and what it deliberately skipped.
/// PLAN.md §3: the summary names "hidden folders, Library, depth > 6, folders inside repos"
/// beside the "Not scanned" row for TCC-denied folders.
public struct ScanResult: Hashable, Codable, Sendable {
    public var policy: ScanPolicy
    public var scannedAt: Date
    public var repos: [DiscoveredRepo]
    /// Directories opened, whether or not they held a repo.
    public var candidatesExamined: Int
    /// TCC-denied or otherwise unreadable; reported, never silently skipped
    /// (`unreadableDirectoryIsReportedNotSilentlySkipped`).
    public var unreadableDirectories: [String]
    /// Directories not entered because `maxDepth` was reached.
    public var depthCutDirectories: Int
    /// Directories not entered because their name starts with `.`.
    public var skippedHiddenDirectories: Int
    /// `.git` files pointing into `…/worktrees/…`; these are checkouts, never repos.
    public var skippedWorktreeCheckouts: [String]
    /// `.git` files pointing into `…/modules/…`; submodules are never listed as repos.
    public var skippedSubmodules: [String]
    /// The walk was cancelled before it drained its queue, so `repos` is what it had found by
    /// then rather than everything there is (packet 3.3). `RefreshCoordinator` bounds the scan
    /// with `RefreshPolicy.scanDeadline` and treats a truncated result as unusable, so the next
    /// refresh walks the tree again instead of trusting a list that was cut short. Defaulted, so
    /// a `ScanResult` written before the field existed still decodes.
    public var truncatedByDeadline: Bool = false

    public init(
        policy: ScanPolicy,
        scannedAt: Date,
        repos: [DiscoveredRepo] = [],
        candidatesExamined: Int = 0,
        unreadableDirectories: [String] = [],
        depthCutDirectories: Int = 0,
        skippedHiddenDirectories: Int = 0,
        skippedWorktreeCheckouts: [String] = [],
        skippedSubmodules: [String] = [],
        truncatedByDeadline: Bool = false
    ) {
        self.policy = policy
        self.scannedAt = scannedAt
        self.repos = repos
        self.candidatesExamined = candidatesExamined
        self.unreadableDirectories = unreadableDirectories
        self.depthCutDirectories = depthCutDirectories
        self.skippedHiddenDirectories = skippedHiddenDirectories
        self.skippedWorktreeCheckouts = skippedWorktreeCheckouts
        self.skippedSubmodules = skippedSubmodules
        self.truncatedByDeadline = truncatedByDeadline
    }
}
