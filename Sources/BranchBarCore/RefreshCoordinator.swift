import Foundation

/// How a refresh ended (codex round 2, MAJOR 9). A deadline persists what it has; a cancel
/// persists nothing and must not claim a new update time.
public enum RefreshOutcome: String, Hashable, Codable, Sendable {
    case completed
    case cancelled
    case deadline
}

/// Owns a refresh: coalescing, the concurrency cap, the overall deadline, cancellation, stable
/// order, progressive emits, and the cache write. PLAN.md §4 refresh lifecycle.
///
/// An actor because a second popover open while a refresh is running must coalesce into the
/// first (`secondRefreshWhileRunningCoalesces`) rather than start a parallel walk.
public actor RefreshCoordinator {
    private let scanner: RepoScanner
    private let loader: RepoLoader
    private let makeLoader: (@Sendable (DiscoveredRepo) -> RepoLoader)?
    private let cache: CacheStore
    private let policy: RefreshPolicy
    private let now: @Sendable () -> Date
    private let scanPolicy: ScanPolicy?
    private let fileSystem: FileSystem
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// Where discovery runs (codex round 2, BLOCKER 1). Defaulted to `InProcessScanRunner` over
    /// the injected `scanner`, so every existing caller and test is unchanged; the shell hands it
    /// `HelperProcessScanRunner` so a walk stuck inside `open()` can be killed rather than waited
    /// on.
    private let scanRunner: any ScanRunning

    /// How the most recent refresh ended (codex round 2, MAJOR 9). The shell reads it to decide
    /// whether to keep the previous "Updated" label and whether to suppress the follow-ups a
    /// completed refresh triggers.
    public private(set) var lastOutcome: RefreshOutcome?

    /// PLAN.md §3: "the cache has none, is older than 7 days, or reason == rescan".
    static let scanMaxAge: TimeInterval = 7 * 24 * 60 * 60

    /// The refresh every later caller coalesces into. Nil exactly when none is running.
    private var inFlight: Task<Snapshot, Never>?
    /// What the debounce hands back, and what the coalescing path is measured against.
    private var lastSnapshot: Snapshot?
    private var lastRefreshFinishedAt: Date?
    /// PLAN.md §4 "launch → load cache (rows stale) → show → refresh" is a one-time event, not
    /// something every popover open repeats.
    private var hasEmittedLaunchSnapshot = false
    /// The eager PR warm-up is a launch bootstrap, not a per-refresh rule; see `run`.
    private var hasRefreshed = false

    /// `tools` is passed in rather than located here: `ToolLocator` is packet 0.3's file and the
    /// coordinator only needs the value it produced.
    // depends on ToolLocator (packet 0.3)
    ///
    /// Everything after `now` is defaulted and additive: `makeLoader` builds a per-repo loader
    /// when one is wanted and falls back to `loader`; `scanPolicy` is reached only when
    /// `CacheFile.scan` carries no policy of its own; `fileSystem` supplies nothing but the
    /// default home root (it never decides which repos appear — the scan does); and `sleep` is
    /// the deadline seam, which behaves like `Task.sleep`.
    public init(
        scanner: RepoScanner,
        loader: RepoLoader,
        cache: CacheStore,
        policy: RefreshPolicy = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        makeLoader: (@Sendable (DiscoveredRepo) -> RepoLoader)? = nil,
        scanPolicy: ScanPolicy? = nil,
        fileSystem: FileSystem = RealFileSystem(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        scanRunner: (any ScanRunning)? = nil
    ) {
        self.scanner = scanner
        self.loader = loader
        self.cache = cache
        self.policy = policy
        self.now = now
        self.makeLoader = makeLoader
        self.scanPolicy = scanPolicy
        self.fileSystem = fileSystem
        self.sleep = sleep
        self.scanRunner = scanRunner ?? InProcessScanRunner(scanner: scanner)
    }

    /// OWNER: packet 3.2 — coalesce into the in-flight refresh unless `force` is set or the
    /// debounce has elapsed; load the repo list from the cache, rescanning when it is missing or
    /// older than 7 days; run the repos through a task group capped at
    /// `policy.maxConcurrentRepos` under `policy.overallDeadline`, fetching PRs only for
    /// `expandedRepoIDs` plus the `policy.eagerPRRepoCount` most recently active repos; emit a
    /// snapshot through `onProgress` as each repo lands, always in the order computed once at the
    /// start; mark every repo the deadline cut off `isStale` and terminate its child processes;
    /// and persist the result atomically before returning it.
    ///
    /// `force` is PLAN.md §3's manual Refresh: it bypasses the 30 s debounce but not the
    /// coalescing rule, because an in-flight refresh "is returned, not queued". `rescan` is the
    /// rescan reason and `bypassPRCache` is "Refresh PRs now"; both are defaulted off.
    public func refresh(
        force: Bool,
        expandedRepoIDs: Set<RepoID>,
        tools: ToolStatus,
        onProgress: @escaping @Sendable (Snapshot) -> Void,
        rescan: Bool = false,
        bypassPRCache: Bool = false
    ) async -> Snapshot {
        // Coalescing first, and before the debounce: a manual Refresh during a running refresh is
        // answered by that refresh rather than by a second walk of the same repos.
        if let inFlight {
            return await inFlight.value
        }

        let startedAt = now()

        if !force,
           let finished = lastRefreshFinishedAt,
           startedAt.timeIntervalSince(finished) < policy.debounce {
            // `popoverOpenWithinDebounceIssuesNoWork`: no command, no emit, and the answer the
            // user is already looking at.
            return lastSnapshot ?? Snapshot(refreshedAt: finished, tools: tools)
        }

        guard tools.gitPath != nil else {
            // `missingGitFailsRefreshWithUserFacingFailureNotCrash`: the preflight already
            // decided; re-deriving it here, or hopefully running `git` at a nil path, is how this
            // turns into a trap. The copy belongs to `Strings.swift` (packet 4.0).
            let cached = (try? cache.load()).flatMap { $0 }
            var snapshot = lastSnapshot ?? cached?.lastSnapshot ?? Snapshot()
            snapshot.refreshedAt = startedAt
            snapshot.tools = tools
            return snapshot
        }

        let task = Task<Snapshot, Never> { [self] in
            await run(
                startedAt: startedAt,
                expandedRepoIDs: expandedRepoIDs,
                tools: tools,
                onProgress: onProgress,
                rescan: rescan,
                bypassPRCache: bypassPRCache)
        }
        inFlight = task
        return await task.value
    }

    /// OWNER: packet 3.2 — cancel the in-flight refresh, terminating every child process it
    /// launched, and leave the last emitted snapshot in place.
    ///
    /// Cancellation travels the structured task tree: the refresh task, its group, each repo
    /// task, and finally the `CommandRunner.run` call, which `ProcessCommandRunner` turns into a
    /// terminated child (packet 2.5's half of
    /// `cancelledRepoTasksTerminateTheirChildProcesses`). Nothing is persisted over the last
    /// emitted snapshot.
    public func cancel() async {
        inFlight?.cancel()
    }

    // MARK: - One refresh

    /// What one repo task hands back, plus the deadline's own arrival.
    private enum Outcome: Sendable {
        case deadline
        case loaded(index: Int, result: RepoLoader.LoadResult)
    }

    private func run(
        startedAt: Date,
        expandedRepoIDs: Set<RepoID>,
        tools: ToolStatus,
        onProgress: @escaping @Sendable (Snapshot) -> Void,
        rescan: Bool,
        bypassPRCache: Bool
    ) async -> Snapshot {
        let isFirstRefresh = !hasRefreshed
        hasRefreshed = true

        var cacheFile = (try? cache.load()).flatMap { $0 } ?? CacheFile()
        cacheFile.schemaVersion = CacheFile.currentSchemaVersion

        // 1. The repo list. It comes from the scan and nothing else: a repo is present because
        // the cached scan or a fresh scan lists it, which is what drops a vanished path without
        // ever issuing a command against it (`repoWhosePathVanishedIsDroppedWithNote`).
        //
        // A scan that was cut short is not a usable scan: packet 4.1's first launch hung inside
        // the walk while macOS held TCC consent dialogs open, and a truncated list persisted as
        // if it were complete would keep a repo missing until the 7-day age check expired.
        let cachedScan = cacheFile.scan
        let scanIsUsable = cachedScan.map { Self.isUsable($0, at: startedAt) } ?? false
        if rescan || !scanIsUsable {
            if let fresh = await scanWithinDeadline(resolvedScanPolicy(from: cacheFile)) {
                cacheFile.scan = fresh
            }
        }
        let discovered = cacheFile.scan?.repos ?? []

        // 2. Stable order, computed once: the previous snapshot's `lastActivity` most recent
        // first, then repos it never held, alphabetically by name (PLAN.md §3, §5a.3).
        let previous = cacheFile.lastSnapshot
        let previousByID = Dictionary(
            (previous?.repos ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previousRank = Dictionary(
            (previous?.repos ?? []).enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        let ordered = Self.stableOrder(
            discovered: discovered, previousByID: previousByID, previousRank: previousRank)

        var rows: [Repo] = ordered.map { repo in
            previousByID[repo.id] ?? Repo(id: repo.id, name: Self.name(of: repo), path: repo.path)
        }

        // 3. PLAN.md §4's launch step, which is the first refresh of the process: the cached rows
        // are shown before any of them has been reloaded, every one marked stale
        // (`launchEmitsStaleCachedSnapshotBeforeRefreshing`).
        if !hasEmittedLaunchSnapshot {
            hasEmittedLaunchSnapshot = true
            if previous != nil {
                rows = rows.map { row in
                    var row = row
                    row.isStale = true
                    return row
                }
                onProgress(Snapshot(repos: rows, refreshedAt: previous?.refreshedAt, tools: tools))
            }
        }

        // 4. The eager PR set (PLAN.md §3 "gh runs only for expanded repos plus the 5 most
        // recently active").
        //
        // `expandedRepoIDs` is what the shell says is open, and it is authoritative on every
        // refresh. The `eagerPRRepoCount` term is the launch bootstrap for the moment before the
        // shell has said anything: §5a item 4 opens "only the most recent" repo by default, so
        // the first refresh of the process warms the most recently active repos from the cached
        // snapshot's `lastActivity`. Once a refresh has run, the shell's expanded set has
        // arrived and re-deriving a second one here would fetch PRs for repos nobody is looking
        // at. "Most recently active" is a fact about the previous snapshot, so a machine with no
        // cached snapshot warms nothing and draws its first rows without a `gh` session per repo.
        var eagerIDs = expandedRepoIDs
        if isFirstRefresh {
            let ranked = ordered.filter { previousByID[$0.id]?.lastActivity != nil }
            for repo in ranked.prefix(max(0, policy.eagerPRRepoCount)) {
                eagerIDs.insert(repo.id)
            }
        }

        // 5. The walk: a task group capped at `policy.maxConcurrentRepos`, racing one sleeping
        // task that carries the overall deadline. The deadline lives inside the group rather than
        // cancelling the whole refresh, so a deadline and a `cancel()` stay distinguishable —
        // one persists what it has, the other persists nothing.
        var loaded: Set<RepoID> = []
        var deadlineHit = false

        await withTaskGroup(of: Outcome.self) { group in
            guard !ordered.isEmpty else { return }
            group.addTask { [sleep, policy] in
                try? await sleep(policy.overallDeadline)
                return .deadline
            }

            var next = 0
            let cap = max(1, policy.maxConcurrentRepos)
            while next < ordered.count, next < cap {
                addRepoTask(
                    to: &group, index: next, ordered: ordered, previousByID: previousByID,
                    eagerIDs: eagerIDs, cacheFile: cacheFile, bypassPRCache: bypassPRCache,
                    at: startedAt)
                next += 1
            }

            for await outcome in group {
                switch outcome {
                case .deadline:
                    // PLAN.md §3: cancel the outstanding tasks; the runner honours cancellation
                    // and terminates its children.
                    deadlineHit = true
                    group.cancelAll()
                case .loaded(let index, let result):
                    rows[index] = result.repo
                    loaded.insert(result.repo.id)
                    if let entry = result.prCache {
                        cacheFile.prCache[ordered[index].id] = entry
                    }
                    // Every emit carries every repo, in the order computed at the start: rows
                    // fill in, the list never reorders (`rowOrderIsStableAcrossProgressiveEmits`).
                    onProgress(Snapshot(repos: rows, refreshedAt: startedAt, tools: tools))

                    if next < ordered.count {
                        addRepoTask(
                            to: &group, index: next, ordered: ordered, previousByID: previousByID,
                            eagerIDs: eagerIDs, cacheFile: cacheFile, bypassPRCache: bypassPRCache,
                            at: startedAt)
                        next += 1
                    }
                }

                if deadlineHit || Task.isCancelled || loaded.count == ordered.count { break }
            }

            group.cancelAll()
        }

        if Task.isCancelled {
            // PLAN.md §3: a cancelled refresh leaves the last emitted snapshot in place and
            // writes nothing over it.
            //
            // What it must also not do is claim to be an update (codex round 2, MAJOR 9). Every
            // progressive emit carries `startedAt` as its `refreshedAt`, so returning the last one
            // handed the shell a brand-new timestamp for a refresh that never finished: `AppModel`
            // went idle and said "Updated just now", and the presenter only shows its stale-row
            // warning while a refresh is running, so nothing on screen said otherwise. The
            // cancelled answer therefore keeps the timestamp of the refresh that really finished
            // and marks every row this one did not reload, which is the same treatment the
            // deadline gives its unfinished rows.
            for (index, repo) in ordered.enumerated() where !loaded.contains(repo.id) {
                rows[index].isStale = true
            }
            let previousRefreshedAt = lastSnapshot?.refreshedAt ?? previous?.refreshedAt
            lastOutcome = .cancelled
            finish(persisted: nil)
            return Snapshot(repos: rows, refreshedAt: previousRefreshedAt, tools: tools)
        }

        // 6. Whatever the deadline cut off keeps its previous row and says so, rather than
        // vanishing or pretending to be current
        // (`refreshHonorsOverallDeadlineAndMarksUnfinishedReposStale`).
        for (index, repo) in ordered.enumerated() where !loaded.contains(repo.id) {
            rows[index].isStale = true
            rows[index].errors.append(RepoError(
                stage: .deadlineExceeded,
                message: "the \(Int(policy.overallDeadline)) s refresh deadline elapsed before this repo finished"))
        }

        lastOutcome = deadlineHit ? .deadline : .completed
        let snapshot = Snapshot(repos: rows, refreshedAt: startedAt, tools: tools)
        // The scan is the only source of truth for which repos exist, so a PR entry for a repo it
        // no longer lists is dead weight that would outlive the repo.
        let live = Set(ordered.map(\.id))

        // Re-read before writing (REVIEW CR-03). `cacheFile` was loaded when this refresh
        // started, and a first refresh on a big home folder runs for the better part of a minute.
        // Writing the whole struct back reverted anything the shell persisted in between — the
        // root the user just picked in "Add folder…" (which is the TCC rescue the whole plan
        // leans on, and which then coalesces into this very refresh), a repo they hid, a section
        // they collapsed. The refresh owns `scan`, `prCache` and `lastSnapshot`; everything else
        // belongs to the user and comes from the file as it stands now.
        var merged = (try? cache.load()).flatMap { $0 } ?? cacheFile
        merged.schemaVersion = CacheFile.currentSchemaVersion
        merged.scan = cacheFile.scan
        merged.lastSnapshot = snapshot
        merged.prCache = cacheFile.prCache.filter { live.contains($0.key) }
        // A root added mid-refresh was not scanned by this refresh, so it rides into the policy
        // here and the next rescan walks it.
        if var scan = merged.scan {
            var roots = scan.policy.extraRoots
            for root in merged.manuallyAddedRepos where !roots.contains(root) { roots.append(root) }
            scan.policy.extraRoots = roots
            merged.scan = scan
        }
        try? cache.save(merged)

        finish(persisted: snapshot)
        return snapshot
    }

    /// What one bounded scan hands back.
    private enum ScanOutcome: Sendable {
        case finished(ScanResult?)
        case deadline
    }

    /// Runs the discovery walk **inside** a deadline, which is the whole point of packet 3.3: the
    /// scan used to run ahead of the deadline-bearing task group, so a walk that blocked — on
    /// packet 4.1's first launch, in `~/Documents` behind a pending TCC dialog — hung the refresh
    /// with nothing able to end it.
    ///
    /// `policy.scanDeadline` is a bound, not a delay: a scan that finishes returns immediately.
    /// When the bound wins, the runner is cancelled and its **partial** result is taken, so the
    /// refresh proceeds with the repos already discovered, `ScanResult.truncatedByDeadline`
    /// makes the next refresh rescan, and the folders the walk never reached ride the snapshot
    /// path as `unreadableDirectories`, which the presenter already turns into the "Not scanned"
    /// notice and its action.
    ///
    /// The race below is the **cooperative** half, and it is all this layer can do on its own
    /// (codex round 2, BLOCKER 1): cancelling a task cannot end a listing already inside
    /// `open()`/`readdir()`, so a walk blocked on an unanswered TCC dialog, a stalled automount,
    /// or a dead network volume kept this method waiting forever and first launch stayed on
    /// "Looking for repos…". The hard half belongs to the runner: `HelperProcessScanRunner`
    /// enforces the same deadline as a SIGTERM/SIGKILL to a helper process, which the kernel does
    /// honour. Both bounds are kept, because the in-process runner is still what the CLI and every
    /// unit test use.
    private func scanWithinDeadline(_ scanPolicy: ScanPolicy) async -> ScanResult? {
        await withTaskGroup(of: ScanOutcome.self, returning: ScanResult?.self) { [scanRunner, sleep, policy] group in
            group.addTask {
                .finished(try? await scanRunner.scan(policy: scanPolicy))
            }
            group.addTask {
                try? await sleep(policy.scanDeadline)
                return .deadline
            }

            var result: ScanResult?
            for await outcome in group {
                switch outcome {
                case .deadline:
                    // Cancel the walk and keep waiting: it answers with what it found.
                    group.cancelAll()
                case .finished(let scan):
                    result = scan
                    group.cancelAll()
                    return result
                }
            }
            return result
        }
    }

    /// Clears the in-flight slot and records what the debounce measures from. Called on the
    /// actor from inside the refresh task, so the second caller either coalesced already or
    /// starts a genuinely new refresh.
    private func finish(persisted: Snapshot?) {
        if let persisted {
            lastSnapshot = persisted
            lastRefreshFinishedAt = now()
        }
        inFlight = nil
    }

    /// One repo, off the actor: `loadOne` is `nonisolated` so `policy.maxConcurrentRepos` repos
    /// really do run at once instead of serializing on the coordinator's executor.
    private func addRepoTask(
        to group: inout TaskGroup<Outcome>,
        index: Int,
        ordered: [DiscoveredRepo],
        previousByID: [RepoID: Repo],
        eagerIDs: Set<RepoID>,
        cacheFile: CacheFile,
        bypassPRCache: Bool,
        at startedAt: Date
    ) {
        let repo = ordered[index]
        // A previous row is only worth handing back when it holds a real branch list; the empty
        // placeholder a brand-new repo starts as would come back as a stale row of nothing.
        let previous = previousByID[repo.id].flatMap { $0.branches.isEmpty ? nil : $0 }
        let wantsPullRequests = eagerIDs.contains(repo.id)
        let cachedPRs = bypassPRCache ? nil : cacheFile.prCache[repo.id]
        group.addTask { [self] in
            let result = await loadOne(
                repo,
                wantsPullRequests: wantsPullRequests,
                cachedPRs: cachedPRs,
                previous: previous,
                at: startedAt)
            return .loaded(index: index, result: result)
        }
    }

    private nonisolated func loadOne(
        _ repo: DiscoveredRepo,
        wantsPullRequests: Bool,
        cachedPRs: PRCacheEntry?,
        previous: Repo?,
        at startedAt: Date
    ) async -> RepoLoader.LoadResult {
        let loader = makeLoader?(repo) ?? self.loader
        return await loader.loadReportingPRCache(
            repo,
            wantsPullRequests: wantsPullRequests,
            cachedPRs: cachedPRs,
            now: startedAt,
            previous: previous)
    }

    // MARK: - Order and policy

    /// PLAN.md §3: "most recent first; new repos appended alphabetically". "New" is "absent from
    /// the previous snapshot"; ties keep the previous snapshot's own order so a machine whose
    /// repos all share a date does not reshuffle on every refresh.
    static func stableOrder(
        discovered: [DiscoveredRepo],
        previousByID: [RepoID: Repo],
        previousRank: [RepoID: Int]
    ) -> [DiscoveredRepo] {
        var seen: Set<RepoID> = []
        let unique = discovered.filter { seen.insert($0.id).inserted }

        let known = unique.filter { previousByID[$0.id] != nil }.sorted { left, right in
            let leftDate = previousByID[left.id]?.lastActivity ?? .distantPast
            let rightDate = previousByID[right.id]?.lastActivity ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return (previousRank[left.id] ?? 0) < (previousRank[right.id] ?? 0)
        }
        let fresh = unique.filter { previousByID[$0.id] == nil }.sorted { left, right in
            let leftName = name(of: left)
            let rightName = name(of: right)
            if leftName != rightName { return leftName < rightName }
            return left.path < right.path
        }
        return known + fresh
    }

    static func name(of repo: DiscoveredRepo) -> String {
        (repo.path as NSString).lastPathComponent
    }

    /// Whether a cached scan can stand in for walking the tree again.
    ///
    /// Three ways it cannot, and one that used to be a fourth by mistake:
    ///
    /// - It was cut short (`truncatedByDeadline`), so the list it holds is not the whole truth.
    /// - It is older than `scanMaxAge`.
    /// - It is dated **in the future** (codex MAJOR 2). The age check is a subtraction, so a
    ///   `scannedAt` a year ahead made every age check pass and froze the repo list forever. A
    ///   timestamp that has not happened is not evidence of anything.
    ///
    /// An **empty** scan is not one of them (codex MINOR 5). A machine with no repos, or one
    /// whose repos are all inside a folder macOS denied, was walking its whole home folder — and
    /// re-triggering that TCC exposure — on every refresh, forever. What separates "the walk ran
    /// and found nothing" from the placeholder a machine that has never scanned leaves behind is
    /// `candidatesExamined`: a finished walk opened directories even when none held a repo.
    static func isUsable(_ scan: ScanResult, at now: Date) -> Bool {
        guard !scan.truncatedByDeadline else { return false }
        let age = now.timeIntervalSince(scan.scannedAt)
        guard age >= 0, age <= scanMaxAge else { return false }
        return !scan.repos.isEmpty || scan.candidatesExamined > 0
    }

    /// The policy a scan runs under, rebuilt from what this process trusts.
    ///
    /// It used to be `CacheFile.scan?.policy` — the policy the last scan recorded, read back out
    /// of a JSON file in Application Support that any process running as the user can write
    /// (codex MAJOR 2). That policy decides which folders BranchBar opens: a `homeRoot` of `/`
    /// with an empty `skipDirectoryNames` and a `maxDepth` of 99 turns a refresh into a full-disk
    /// walk, TCC prompts and all. So the shape comes from the injected default (the app's own
    /// `ScanPolicy`, or this machine's home folder), and the only thing the cache contributes is
    /// `manuallyAddedRepos` — the roots the folder picker wrote, each of which the user chose in
    /// a macOS panel (PLAN.md §3).
    private func resolvedScanPolicy(from cacheFile: CacheFile) -> ScanPolicy {
        var policy = self.scanPolicy ?? ScanPolicy(homeRoot: fileSystem.homeDirectory())
        var roots = policy.extraRoots
        for root in cacheFile.manuallyAddedRepos where !roots.contains(root) {
            roots.append(root)
        }
        policy.extraRoots = roots
        return policy
    }
}
