import Foundation

@testable import BranchBarCore

/// An in-memory `CacheStore` that also counts saves, so a test can assert a refresh persisted
/// once rather than once per progressive emit.
public final class InMemoryCacheStore: CacheStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CacheFile?
    private var _saveCount = 0
    private var _loadCount = 0

    /// Set to throw from `save`, to exercise `interruptedSaveLeavesPreviousCacheIntact`.
    public var saveError: (any Error)?
    /// Set to throw from `load`.
    public var loadError: (any Error)?

    public init(initial: CacheFile? = nil) {
        self.stored = initial
    }

    public var current: CacheFile? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    public var saveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _saveCount
    }

    public var loadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _loadCount
    }

    public func load() throws -> CacheFile? {
        if let loadError { throw loadError }
        lock.lock(); defer { lock.unlock() }
        _loadCount += 1
        return stored
    }

    public func save(_ cache: CacheFile) throws {
        if let saveError { throw saveError }
        lock.lock(); defer { lock.unlock() }
        _saveCount += 1
        stored = cache
    }
}
