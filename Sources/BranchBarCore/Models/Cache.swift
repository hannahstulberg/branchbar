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

    /// This cache with every model invariant enforced (codex round 5, MINOR 8).
    ///
    /// `FileCacheStore.load` already checks the schema version, the size, and the dates; none of
    /// those look at whether a value means anything. A decoded `PushInfo` claiming an observation
    /// it carries no date for is the one that reaches the screen as a sentence — "Pushed from this
    /// Mac" over a date taken from somewhere else — so the restored snapshot is walked and each
    /// branch's push facts are held to what they can support.
    public func validated() -> CacheFile {
        guard var snapshot = lastSnapshot else { return self }
        snapshot.repos = snapshot.repos.map { repo in
            var repo = repo
            repo.branches = repo.branches.map { branch in
                var branch = branch
                branch.push = branch.push.withoutUnsupportedClaims()
                return branch
            }
            return repo
        }
        var validated = self
        validated.lastSnapshot = snapshot
        return validated
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
    /// read in the other direction). Read with `decodeIfPresent` below, so an entry written
    /// before the field existed loads as "recorded nothing about what it asked".
    public var queriedHeads: [String] = []
    /// The repository this entry was fetched **for**, both halves of it (codex round 5, MAJOR 1).
    ///
    /// The map is keyed by `RepoID` alone, and a `RepoID` is a path: point the same checkout at a
    /// second GitHub repository, or delete and recreate a repo at the cached path, and a fresh
    /// entry fetched for `nytimes/repo-a` answered for `nytimes/repo-b` — its pills, and an
    /// "Open PR" that led to another repository's pull request on an allowed host. An entry is
    /// therefore used only when it names both the slug the refresh has just resolved and the
    /// common directory `git rev-parse` has just re-resolved; anything else is treated as no
    /// cache at all and refetched. Read with `decodeIfPresent`, so an entry written before this
    /// field records neither and is discarded rather than believed.
    public var repoID: RepoID?
    /// The `origin` slug the PRs in this entry were fetched from (codex round 5, MAJOR 1).
    public var slug: GitHubSlug?

    public init(
        fetchedAt: Date,
        prs: [PRInfo] = [],
        authorPRs: [PRInfo] = [],
        queriedHeads: [String] = [],
        repoID: RepoID? = nil,
        slug: GitHubSlug? = nil
    ) {
        self.fetchedAt = fetchedAt
        self.prs = prs
        self.authorPRs = authorPRs
        self.queriedHeads = queriedHeads
        self.repoID = repoID
        self.slug = slug
    }

    /// Does this entry answer for the repository this refresh is looking at?
    ///
    /// Both halves have to match, and an entry that recorded neither matches nothing: "no slug
    /// recorded" is not "the slug you have". Slug comparison is case-folded on all three parts
    /// because GitHub hosts, owners, and repository names are case-insensitive and the casing in
    /// a clone URL is whatever was typed.
    public func answers(repoID: RepoID, slug: GitHubSlug?) -> Bool {
        guard let recordedID = self.repoID, recordedID == repoID else { return false }
        guard let recordedSlug = self.slug, let slug else { return false }
        return recordedSlug.hostKey == slug.hostKey
            && recordedSlug.ownerKey == slug.ownerKey
            && recordedSlug.nameKey == slug.nameKey
    }

    /// Explicit because a *synthesized* `init(from:)` calls `decode(_:forKey:)` for every
    /// non-optional property and never consults that property's default (packet F12). A stored
    /// property added after the 1.1 freeze was therefore a required key: `queriedHeads` missing
    /// threw `keyNotFound`, the enclosing `CacheFile` failed with it, and `FileCacheStore.load`
    /// swallowed that as "no cache" — a cold rescan and an empty popover on the first launch
    /// after the upgrade that added the field. Keys frozen in 1.1 stay required, so a file of the
    /// wrong shape is still not a cache (`corruptJSONLoadsNil`); only the added keys are read
    /// with `decodeIfPresent`. `encode` stays synthesized: what this version writes carries
    /// every key.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        prs = try container.decode([PRInfo].self, forKey: .prs)
        authorPRs = try container.decode([PRInfo].self, forKey: .authorPRs)
        queriedHeads = try container.decodeIfPresent([String].self, forKey: .queriedHeads) ?? []
        repoID = try container.decodeIfPresent(RepoID.self, forKey: .repoID)
        slug = try container.decodeIfPresent(GitHubSlug.self, forKey: .slug)
    }
}
