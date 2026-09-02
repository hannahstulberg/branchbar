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
    /// `isDirectory` follows the link (can this be descended into?) while `isSymbolicLink` looks
    /// at the entry itself (should it be?) — a symlinked repo is both, and PLAN.md §5's scan
    /// rules need to tell them apart. The prefetched `.isDirectoryKey` describes the **entry**,
    /// not its target, so the following answer costs one `stat` per symlink and nothing at all
    /// for the ordinary entries that make up a home folder.
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

            let isDirectory: Bool
            if isSymbolicLink {
                // One `stat` for the rare entry that needs it; a dangling link answers false.
                var resolved: ObjCBool = false
                isDirectory = manager.fileExists(atPath: entryPath, isDirectory: &resolved)
                    && resolved.boolValue
            } else {
                isDirectory = values?.isDirectory ?? false
            }

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
