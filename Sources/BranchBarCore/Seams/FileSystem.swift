import Foundation

/// One entry of a directory listing, with the facts the scanner needs so it never has to stat
/// a second time. PLAN.md §5 `protocol FileSystem`.
public struct DirectoryEntry: Hashable, Codable, Sendable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    /// A `.git` **file** (worktree checkout or submodule) is not a directory; the scanner
    /// classifies it by reading the `gitdir:` line.
    public var isSymbolicLink: Bool

    public init(name: String, path: String, isDirectory: Bool, isSymbolicLink: Bool = false) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
    }
}

/// The filesystem seam: the home scan, the reflog files, and the cache all go through it, so a
/// unit test never touches the real home folder. Synchronous on purpose — the calls are
/// `readdir` and `read`, and the concurrency that matters lives one level up in
/// `RefreshCoordinator`.
public protocol FileSystem: Sendable {
    /// Throws when the directory is unreadable (TCC denial), which the scanner reports rather
    /// than swallowing (`unreadableDirectoryIsReportedNotSilentlySkipped`).
    func contentsOfDirectory(atPath path: String) throws -> [DirectoryEntry]
    func fileExists(atPath path: String) -> Bool
    func isExecutableFile(atPath path: String) -> Bool
    func readFile(atPath path: String) throws -> Data
    /// `FETCH_HEAD` mtime backs the ahead-count tooltip (PLAN.md §3).
    func modificationDate(atPath path: String) throws -> Date
    func homeDirectory() -> String
    /// The GUI app's `PATH`, `/usr/bin:/bin:/usr/sbin:/sbin`; read by `ToolLocator`.
    // depends on ToolLocator (packet 0.3)
    func pathEnvironment() -> String
}
