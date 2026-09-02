import Foundation

/// The real `CacheStore`: one JSON file under Application Support, written atomically.
///
/// The cache is a latency optimisation, never a source of truth (PLAN.md §3), so every way it
/// can be wrong reads as "no cache" rather than as an error the user sees.
public struct FileCacheStore: CacheStore {
    private let fileURL: URL

    /// `~/Library/Application Support/BranchBar/cache.json`.
    public static func defaultFileURL(homeDirectory: String) -> URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Library/Application Support/BranchBar", isDirectory: true)
            .appendingPathComponent("cache.json", isDirectory: false)
    }

    /// Past this size the file loads as "no cache" (codex MAJOR 2). The load is synchronous and
    /// on the launch path; a real cache for 30 repos is well under a megabyte.
    public static let maximumFileBytes = 16 * 1024 * 1024

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `.iso8601` so a cache file is readable when someone opens it to debug a stale row, and
    /// `.sortedKeys` so an unchanged cache is a byte-for-byte unchanged file.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Absent, unreadable, undecodable, or an unknown `schemaVersion` all load nil. PLAN.md §5
    /// says an unknown version loads nil rather than migrating
    /// (`unknownSchemaVersionLoadsNil`) — a cache written by a newer BranchBar is discarded and
    /// rebuilt on the next refresh, which costs a scan and never shows wrong rows.
    /// One more way it can be wrong, and the reason this read goes through `RealFileSystem`'s
    /// bounded primitive rather than `FileManager.contents` (codex round 2, BLOCKER 2): the cache
    /// lives at a fixed path under Application Support that any process running as the user can
    /// replace, the load is synchronous and on the launch path, and `FileManager.contents` on a
    /// FIFO — or on a symlink to one — blocks inside `open()` until a writer appears. That hung
    /// app initialization with nothing able to end it. A cache file that is not a plain regular
    /// file is simply not a cache.
    public func load() throws -> CacheFile? {
        // One descriptor, no path preflight in front of it (codex round 4, BLOCKER 3). The bound
        // used to come from `FileManager.attributesOfItem`, which is a second pathname resolution
        // that follows symlinks and carries no `O_NONBLOCK` — on the synchronous launch path, so a
        // `cache.json` symlinked at a stalled automount parked app initialization where nothing
        // above it could end it. `readBoundedRegularFile` already refuses a symlink, refuses
        // anything that is not `S_IFREG`, and never blocks in its `open`; asking it for one byte
        // more than the cap makes the *read* enforce the size, so a file past the bound is still
        // "no cache" and the expensive half — the decode — is still skipped.
        guard let data = try? RealFileSystem().readBoundedRegularFile(
            path: fileURL.path, maxBytes: Self.maximumFileBytes + 1, tail: false)
        else { return nil }
        guard data.count <= Self.maximumFileBytes else { return nil }
        guard !data.isEmpty else { return nil }
        guard let cache = try? Self.makeDecoder().decode(CacheFile.self, from: data) else { return nil }
        guard cache.schemaVersion == CacheFile.currentSchemaVersion else { return nil }
        // Schema, then dates, then meaning (codex round 5, MINOR 8): a file can satisfy the first
        // two and still hold a `PushInfo` that says a push was observed and does not say when.
        return Self.withoutFutureDates(cache).validated()
    }

    /// Drops every part of the cache whose timestamp has not happened yet (codex MAJOR 2).
    ///
    /// Each of the three is an age the app measures against: `scan.scannedAt` decides whether to
    /// rescan, `lastSnapshot.refreshedAt` is what the footer reports, and `PRCacheEntry.fetchedAt`
    /// decides whether to re-ask GitHub. A date in the future makes all three subtractions
    /// negative, so the scan never expires, the rows never look stale, and the PR list is never
    /// refetched. Each part is dropped on its own, so the parts of the file that are still
    /// credible — the roots the user picked, the repos they hid — survive and the missing parts
    /// are simply rebuilt.
    ///
    /// The tolerance is for clock skew, not for a hostile file: a cache written seconds ago on a
    /// machine whose clock has just stepped backwards is still a real cache.
    static func withoutFutureDates(_ cache: CacheFile, now: Date = Date()) -> CacheFile {
        let horizon = now.addingTimeInterval(futureTolerance)
        var cache = cache
        if let scan = cache.scan, scan.scannedAt > horizon { cache.scan = nil }
        if let snapshot = cache.lastSnapshot, let refreshedAt = snapshot.refreshedAt,
           refreshedAt > horizon {
            cache.lastSnapshot = nil
        }
        cache.prCache = cache.prCache.filter { $0.value.fetchedAt <= horizon }
        return cache
    }

    /// How far ahead of now a timestamp may be and still be believed.
    static let futureTolerance: TimeInterval = 60

    /// Encodes to a scratch file in the same directory and lands it with `replaceItemAt`, so a
    /// save that dies partway leaves the previous `cache.json` intact
    /// (`interruptedSaveLeavesPreviousCacheIntact`). Same directory, because `replaceItemAt`
    /// is only atomic within one volume.
    public func save(_ cache: CacheFile) throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let data = try Self.makeEncoder().encode(cache)
        let scratch = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )

        do {
            try data.write(to: scratch, options: [])
            if manager.fileExists(atPath: fileURL.path) {
                _ = try manager.replaceItemAt(fileURL, withItemAt: scratch)
            } else {
                try manager.moveItem(at: scratch, to: fileURL)
            }
        } catch {
            // Never leave a half-written scratch file behind for the next launch to trip over.
            try? manager.removeItem(at: scratch)
            throw error
        }
    }
}
