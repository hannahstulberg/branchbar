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

    /// Both facts about each entry come from one pass, so the scanner never has to stat again.
    ///
    /// `isDirectory` follows the link (can this be descended into?) while `isSymbolicLink` looks
    /// at the entry itself (should it be?) — a symlinked repo is both, and PLAN.md §5's scan
    /// rules need to tell them apart. Throws when the directory is unreadable, which is what a
    /// TCC denial on `~/Documents` looks like
    /// (`unreadableDirectoryIsReportedNotSilentlySkipped`); an empty listing would read as
    /// "no repos here", which is a lie.
    public func contentsOfDirectory(atPath path: String) throws -> [DirectoryEntry] {
        let names = try manager.contentsOfDirectory(atPath: path)
        return names.map { name in
            let entryPath = (path as NSString).appendingPathComponent(name)

            var isDirectory: ObjCBool = false
            let resolvedExists = manager.fileExists(atPath: entryPath, isDirectory: &isDirectory)

            // `attributesOfItem` does not traverse the final symlink, so this is the entry's own
            // type rather than its target's.
            let attributes = try? manager.attributesOfItem(atPath: entryPath)
            let isSymbolicLink = (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink

            return DirectoryEntry(
                name: name,
                path: entryPath,
                isDirectory: resolvedExists && isDirectory.boolValue,
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

    /// `FETCH_HEAD`'s mtime backs the ahead-count tooltip (PLAN.md §3).
    public func modificationDate(atPath path: String) throws -> Date {
        let attributes = try manager.attributesOfItem(atPath: path)
        guard let date = attributes[.modificationDate] as? Date else {
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
