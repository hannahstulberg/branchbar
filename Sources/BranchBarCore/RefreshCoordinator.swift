import Foundation

/// Owns a refresh: coalescing, the concurrency cap, the overall deadline, cancellation, stable
/// order, progressive emits, and the cache write. PLAN.md §4 refresh lifecycle.
///
/// An actor because a second popover open while a refresh is running must coalesce into the
/// first (`secondRefreshWhileRunningCoalesces`) rather than start a parallel walk.
public actor RefreshCoordinator {
    private let scanner: RepoScanner
    private let loader: RepoLoader
    private let cache: CacheStore
    private let policy: RefreshPolicy
    private let now: @Sendable () -> Date

    /// `tools` is passed in rather than located here: `ToolLocator` is packet 0.3's file and the
    /// coordinator only needs the value it produced.
    // depends on ToolLocator (packet 0.3)
    public init(
        scanner: RepoScanner,
        loader: RepoLoader,
        cache: CacheStore,
        policy: RefreshPolicy = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.scanner = scanner
        self.loader = loader
        self.cache = cache
        self.policy = policy
        self.now = now
    }

    /// OWNER: packet 3.2 — coalesce into the in-flight refresh unless `force` is set or the
    /// debounce has elapsed; load the repo list from the cache, rescanning when it is missing or
    /// older than 7 days; run the repos through a task group capped at
    /// `policy.maxConcurrentRepos` under `policy.overallDeadline`, fetching PRs only for
    /// `expandedRepoIDs` plus the `policy.eagerPRRepoCount` most recently active repos; emit a
    /// snapshot through `onProgress` as each repo lands, always in the order computed once at the
    /// start; mark every repo the deadline cut off `isStale` and terminate its child processes;
    /// and persist the result atomically before returning it.
    public func refresh(
        force: Bool,
        expandedRepoIDs: Set<RepoID>,
        tools: ToolStatus,
        onProgress: @escaping @Sendable (Snapshot) -> Void
    ) async -> Snapshot {
        fatalError("OWNER: packet 3.2 — coalesce, scan or reuse the repo list, run repos capped at 4 under the 45 s deadline with lazy PR fetching, emit progressively in a stable order, mark unfinished repos stale, and persist atomically.")
    }

    /// OWNER: packet 3.2 — cancel the in-flight refresh, terminating every child process it
    /// launched, and leave the last emitted snapshot in place.
    public func cancel() async {
        fatalError("OWNER: packet 3.2 — cancel the in-flight refresh and terminate its child processes.")
    }
}
