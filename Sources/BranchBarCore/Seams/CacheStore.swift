import Foundation

/// The persistence seam. PLAN.md §5: writes go to a temp file and land with `replaceItemAt`,
/// so an interrupted save leaves the previous cache intact
/// (`interruptedSaveLeavesPreviousCacheIntact`).
public protocol CacheStore: Sendable {
    /// Returns nil when there is no cache, it cannot be read, or its `schemaVersion` is unknown
    /// (`unknownSchemaVersionLoadsNil`). A corrupt cache is never an error the user sees.
    func load() throws -> CacheFile?
    func save(_ cache: CacheFile) throws
}
