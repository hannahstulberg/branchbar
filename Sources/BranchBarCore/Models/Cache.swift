import Foundation

/// The on-disk cache. PLAN.md §5: `schemaVersion` is 1 and an unknown version loads nil
/// (`unknownSchemaVersionLoadsNil`) rather than migrating.
///
/// Note for packet 2.5: `prCache` is keyed by `RepoID`, which is not a `String`, so
/// `JSONEncoder` writes it as an alternating key/value array rather than a JSON object.
/// That is what PLAN.md §5 specifies; the round-trip test belongs to `FileCacheStore`.
public struct CacheFile: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var scan: ScanResult?
    /// Roots added through "Add folder…", persisted so the next launch scans them again.
    public var manuallyAddedRepos: [String]
    public var hiddenRepoIDs: [RepoID]
    public var collapsedRepoIDs: [RepoID]
    public var prCache: [RepoID: PRCacheEntry]
    public var lastSnapshot: Snapshot?

    public init(
        schemaVersion: Int = CacheFile.currentSchemaVersion,
        scan: ScanResult? = nil,
        manuallyAddedRepos: [String] = [],
        hiddenRepoIDs: [RepoID] = [],
        collapsedRepoIDs: [RepoID] = [],
        prCache: [RepoID: PRCacheEntry] = [:],
        lastSnapshot: Snapshot? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.scan = scan
        self.manuallyAddedRepos = manuallyAddedRepos
        self.hiddenRepoIDs = hiddenRepoIDs
        self.collapsedRepoIDs = collapsedRepoIDs
        self.prCache = prCache
        self.lastSnapshot = lastSnapshot
    }
}

/// One repo's cached `gh` results. TTL is `RefreshPolicy.prCacheTTL` (600 s); "Refresh PRs now"
/// bypasses it. PLAN.md §3: the cache is for latency, not quota.
public struct PRCacheEntry: Hashable, Codable, Sendable {
    public var fetchedAt: Date
    /// The recent-100 list plus anything the per-head fallback added.
    public var prs: [PRInfo]
    /// `gh pr list --state open --author @me`.
    public var authorPRs: [PRInfo]
    /// The heads this entry's fetch actually asked GitHub about: the recent-100 list answers for
    /// every head it names, and the per-head fallback answers for each head it spent the cap on.
    /// Persisted because a warm cache serves the whole answer without re-querying, and without
    /// this a branch the fetch *did* ask about and found nothing for would come back
    /// `notChecked` on the next launch instead of `none` (`unqueriedBranchIsNotCheckedNeverNone`
    /// read in the other direction). Defaulted so a cache written before this field decodes.
    public var queriedHeads: [String] = []

    public init(
        fetchedAt: Date,
        prs: [PRInfo] = [],
        authorPRs: [PRInfo] = [],
        queriedHeads: [String] = []
    ) {
        self.fetchedAt = fetchedAt
        self.prs = prs
        self.authorPRs = authorPRs
        self.queriedHeads = queriedHeads
    }
}
