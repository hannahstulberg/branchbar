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
        ghListTimeout: TimeInterval = 25
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
    }
}
