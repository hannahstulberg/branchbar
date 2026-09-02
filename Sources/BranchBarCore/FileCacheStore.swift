import Foundation

/// The real `CacheStore`: one JSON file under Application Support, written atomically.
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

    /// OWNER: packet 2.5 — decode the cache file and return it, returning nil when the file is
    /// absent, unreadable, undecodable, or carries a `schemaVersion` other than
    /// `CacheFile.currentSchemaVersion`, so a corrupt cache is never an error the user sees.
    public func load() throws -> CacheFile? {
        fatalError("OWNER: packet 2.5 — decode the cache file, returning nil for absent, corrupt, or unknown-schemaVersion contents.")
    }

    /// OWNER: packet 2.5 — encode the cache to a temp file in the same directory and land it with
    /// `FileManager.replaceItemAt`, so an interrupted save leaves the previous cache intact.
    public func save(_ cache: CacheFile) throws {
        fatalError("OWNER: packet 2.5 — write the cache to a temp file and land it with replaceItemAt so an interrupted save leaves the previous file intact.")
    }
}
