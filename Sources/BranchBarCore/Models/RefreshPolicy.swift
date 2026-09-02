import Foundation

/// Every number PLAN.md §3 and §5 fix about a refresh, in one value so tests can shrink the
/// deadline instead of waiting 45 s. Seconds are `TimeInterval` rather than `Duration` so the
/// whole policy stays trivially `Codable` alongside the rest of the model.
public struct RefreshPolicy: Hashable, Codable, Sendable {
    /// Popover-open refreshes closer together than this coalesce; manual Refresh bypasses it.
    public var debounce: TimeInterval
    /// Whole refresh. Unfinished repos are marked stale and their children terminated.
    public var overallDeadline: TimeInterval
    /// `peakConcurrencyNeverExceedsCap`.
    public var maxConcurrentRepos: Int
    public var prCacheTTL: TimeInterval
    /// Collapsed repos beyond the 5 most recently active issue no `gh` calls.
    public var eagerPRRepoCount: Int
    /// Per repo per refresh; branches past the cap render `notChecked`, never `none`.
    public var perHeadFallbackCap: Int
    /// PLAN.md §5 "Timeouts: git 10 s".
    public var gitTimeout: TimeInterval
    /// "`gh auth status` 10 s".
    public var ghAuthTimeout: TimeInterval
    /// "`gh pr list` 25 s".
    public var ghListTimeout: TimeInterval
    /// The repo *discovery* walk, which runs inside the refresh rather than ahead of it (packet
    /// 3.3). Shorter than `overallDeadline` on purpose: a scan that has not finished in 20 s is
    /// blocked on something — on packet 4.1's first launch, a pending TCC consent dialog — and
    /// the repos it already found are worth more than the ones it might still reach. Read with
    /// `decodeIfPresent` below (packet F12), so a policy encoded before the field existed comes
    /// back with the shipped 20 s rather than a zero that would cut every scan short at once.
    public var scanDeadline: TimeInterval = 20

    public static let `default` = RefreshPolicy()

    public init(
        debounce: TimeInterval = 30,
        overallDeadline: TimeInterval = 45,
        maxConcurrentRepos: Int = 4,
        prCacheTTL: TimeInterval = 600,
        eagerPRRepoCount: Int = 5,
        perHeadFallbackCap: Int = 20,
        gitTimeout: TimeInterval = 10,
        ghAuthTimeout: TimeInterval = 10,
        ghListTimeout: TimeInterval = 25,
        scanDeadline: TimeInterval = 20
    ) {
        self.debounce = debounce
        self.overallDeadline = overallDeadline
        self.maxConcurrentRepos = maxConcurrentRepos
        self.prCacheTTL = prCacheTTL
        self.eagerPRRepoCount = eagerPRRepoCount
        self.perHeadFallbackCap = perHeadFallbackCap
        self.gitTimeout = gitTimeout
        self.ghAuthTimeout = ghAuthTimeout
        self.ghListTimeout = ghListTimeout
        self.scanDeadline = scanDeadline
    }

    /// Explicit for the reason spelled out on `PRCacheEntry.init(from:)` (packet F12): a
    /// synthesized decoder ignores a stored property's default, so `scanDeadline` was a required
    /// key of every encoded policy. Frozen keys stay required.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        debounce = try container.decode(TimeInterval.self, forKey: .debounce)
        overallDeadline = try container.decode(TimeInterval.self, forKey: .overallDeadline)
        maxConcurrentRepos = try container.decode(Int.self, forKey: .maxConcurrentRepos)
        prCacheTTL = try container.decode(TimeInterval.self, forKey: .prCacheTTL)
        eagerPRRepoCount = try container.decode(Int.self, forKey: .eagerPRRepoCount)
        perHeadFallbackCap = try container.decode(Int.self, forKey: .perHeadFallbackCap)
        gitTimeout = try container.decode(TimeInterval.self, forKey: .gitTimeout)
        ghAuthTimeout = try container.decode(TimeInterval.self, forKey: .ghAuthTimeout)
        ghListTimeout = try container.decode(TimeInterval.self, forKey: .ghListTimeout)
        scanDeadline = try container.decodeIfPresent(TimeInterval.self, forKey: .scanDeadline) ?? 20
    }
}
