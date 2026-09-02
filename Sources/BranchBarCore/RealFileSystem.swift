import Foundation

/// The real `FileSystem`, backed by `FileManager`. Every unit test uses `InMemoryFileSystem`
/// instead, so this type is the only thing in BranchBarCore that reads the user's disk.
///
/// Synchronous, like the protocol: the calls are `readdir` and `read`, and the concurrency that
/// matters lives one level up in `RefreshCoordinator`.
public struct RealFileSystem: FileSystem {
    public init() {}

    /// Not a stored property: `FileManager` is not `Sendable`, and `FileSystem` is. `.default`
    /// is documented as safe to use from multiple threads for these calls.
    private var manager: FileManager { FileManager.default }

    /// The two facts about each entry the scanner needs, from one directory read.
    ///
    /// `contentsOfDirectory(at:includingPropertiesForKeys:)` fetches the listing and the two
    /// resource keys in a single bulk pass and caches them on the returned URLs, so
    /// `resourceValues(forKeys:)` below reads the cached values rather than hitting the disk per
    /// entry. Packet 4.1's first launch hung at 0% CPU inside the previous implementation's
    /// per-entry full-attribute-dictionary lookup, which reaches extended attributes, while
    /// macOS held TCC consent dialogs open. That lookup is gone from this file, and
    /// `realFileSystemNeverCallsAttributesOfItem` keeps it gone.
    ///
    /// Both facts describe the **entry**, never its target (codex BLOCKER 2). The scanner does
    /// not follow symlinks under any circumstances, so following one here to find out whether it
    /// leads to a directory answered a question nobody asks, and paid for the answer with a
    /// `stat` that a stalled automount, an unreachable network volume, or a `~/Library/
    /// CloudStorage` mount can block forever — inside a synchronous call that the scan deadline
    /// cannot cancel, because a task blocked in `open()` never reaches a cancellation check. A
    /// symlink is therefore reported `isDirectory: false, isSymbolicLink: true` whatever it
    /// points at, and the listing costs one `readdir` and no `stat` at all.
    ///
    /// Throws when the directory is unreadable, which is what a TCC denial on `~/Documents` looks
    /// like (`unreadableDirectoryIsReportedNotSilentlySkipped`); an empty listing would read as
    /// "no repos here", which is a lie.
    public func contentsOfDirectory(atPath path: String) throws -> [DirectoryEntry] {
        let urls = try manager.contentsOfDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )

        return urls.map { url in
            let name = url.lastPathComponent
            // Built in the string domain from the path the caller gave, not from the URL: a URL
            // listing resolves `/var` to `/private/var`, and the scanner's dedupe keys and the
            // reflog paths are the caller's own strings.
            let entryPath = (path as NSString).appendingPathComponent(name)

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isSymbolicLink = values?.isSymbolicLink ?? false
            // A link is never a directory to descend into, so the target is never touched.
            let isDirectory = isSymbolicLink ? false : (values?.isDirectory ?? false)

            return DirectoryEntry(
                name: name,
                path: entryPath,
                isDirectory: isDirectory,
                isSymbolicLink: isSymbolicLink
            )
        }
    }

    public func fileExists(atPath path: String) -> Bool {
        manager.fileExists(atPath: path)
    }

    public func isExecutableFile(atPath path: String) -> Bool {
        manager.isExecutableFile(atPath: path)
    }

    public func readFile(atPath path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path), options: [])
    }

    /// `FETCH_HEAD`'s mtime backs the ahead-count tooltip (PLAN.md §3). One resource-value read
    /// rather than the whole attribute dictionary, for the same reason the listing above stopped
    /// asking for one; a missing file throws, which is what the reflog reader's fallback expects.
    public func modificationDate(atPath path: String) throws -> Date {
        let values = try URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.contentModificationDateKey])
        guard let date = values.contentModificationDate else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        return date
    }

    public func homeDirectory() -> String {
        manager.homeDirectoryForCurrentUser.path
    }

    /// A GUI-launched `.app` inherits launchd's `PATH`, not the user's shell `PATH`; the
    /// fallback is that launchd default, so `ToolLocator` always has something to split.
    public func pathEnvironment() -> String {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.isEmpty ? "/usr/bin:/bin:/usr/sbin:/sbin" : path
    }
}

/// A `FileSystem` that can read a bounded slice of a file without reading it whole.
///
/// codex MAJOR 15: `.git` markers, reflogs, and command output are all repository-controlled and
/// were all read to EOF into memory. The `FileSystem` seam is frozen (PLAN.md §5), so the bound
/// is a refinement rather than a new requirement on it: `RealFileSystem` reads exactly the bytes
/// asked for, and the in-memory double a unit test uses falls through to the default below, which
/// slices what it already holds. The dispatch is a one-line downcast in that default, which is
/// what a protocol extension needs to reach an implementation that is not a requirement.
public protocol BoundedFileReading: FileSystem {
    /// At most `maximumBytes` from the start of the file. Throws for an unreadable file, exactly
    /// as `readFile` does.
    func readFile(atPath path: String, maximumBytes: Int) throws -> Data
    /// At most `maximumBytes` from the **end** of the file, for a log whose newest lines are last.
    func readFileTail(atPath path: String, maximumBytes: Int) throws -> Data
}

extension FileSystem {
    public func readFile(atPath path: String, maximumBytes: Int) throws -> Data {
        if let bounded = self as? any BoundedFileReading {
            return try bounded.readFile(atPath: path, maximumBytes: maximumBytes)
        }
        return Data(try readFile(atPath: path).prefix(maximumBytes))
    }

    public func readFileTail(atPath path: String, maximumBytes: Int) throws -> Data {
        if let bounded = self as? any BoundedFileReading {
            return try bounded.readFileTail(atPath: path, maximumBytes: maximumBytes)
        }
        return Data(try readFile(atPath: path).suffix(maximumBytes))
    }
}

extension RealFileSystem: BoundedFileReading {
    /// One `open` and one `read` of at most `maximumBytes`, so the size of the file on disk never
    /// becomes the size of an allocation here.
    public func readFile(atPath path: String, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        return try handle.read(upToCount: max(0, maximumBytes)) ?? Data()
    }

    /// Seeks to `size - maximumBytes` and reads forward, so a reflog of any size costs one seek
    /// and one bounded read.
    public func readFileTail(atPath path: String, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let bound = UInt64(max(0, maximumBytes))
        try handle.seek(toOffset: size > bound ? size - bound : 0)
        return try handle.readToEnd() ?? Data()
    }
}
