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
    public func load() throws -> CacheFile? {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return nil }
        guard let cache = try? Self.makeDecoder().decode(CacheFile.self, from: data) else { return nil }
        guard cache.schemaVersion == CacheFile.currentSchemaVersion else { return nil }
        return cache
    }

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
