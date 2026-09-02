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

/// What one `fstat` on an already-open descriptor says about a regular file (codex round 3,
/// BLOCKER 2). The two facts every caller in this package wanted, taken from the descriptor
/// rather than from a second path lookup that could resolve somewhere else.
public struct RegularFileStat: Hashable, Sendable {
    public var size: Int
    public var modificationDate: Date

    public init(size: Int, modificationDate: Date) {
        self.size = size
        self.modificationDate = modificationDate
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

    /// Is this path an existing directory, without following a symlink and without blocking?
    ///
    /// codex round 3, BLOCKER 1: a worktree path and a cached repo path are repository-owned
    /// strings that become the payload of a row's primary action, and the last editor in the
    /// fallback chain is Terminal, which *executes* a `.command` document. A crafted
    /// `.git/worktrees` record naming `/tmp/payload.command` therefore turned a click into
    /// execution. Nothing may be offered as "open this folder" until something has established
    /// that it is a folder.
    ///
    /// Answers false rather than throwing: a path that cannot be established as a directory is
    /// not one this app will vouch for, whatever the reason.
    func isDirectoryNoFollow(atPath path: String) -> Bool

    /// Size and modification time of a regular file, from a descriptor opened without following a
    /// symlink and without blocking (codex round 3, BLOCKER 2).
    ///
    /// Returns nil when the path does not exist — which is how absence is decided, instead of a
    /// `fileExists` preflight that races the read behind it and answers for a path rather than for
    /// a descriptor. Throws when something *is* there and this process may not read it, or when it
    /// is not a regular file: a FIFO where a reflog belongs is a fact the caller reports, never an
    /// absence it reports as "never pushed".
    func statRegularFile(atPath path: String) throws -> RegularFileStat?
}

extension FileSystem {
    /// The fallback for a seam double with no descriptors of its own: a directory is a path whose
    /// listing succeeds. `RealFileSystem` overrides it with the `open(O_DIRECTORY | O_NOFOLLOW |
    /// O_NONBLOCK)` this finding is actually about, and the in-memory double overrides it with its
    /// own directory table; the default exists so adding this requirement to a frozen protocol
    /// (PLAN.md §5) breaks no conformer.
    public func isDirectoryNoFollow(atPath path: String) -> Bool {
        (try? contentsOfDirectory(atPath: path)) != nil
    }

    /// The fallback, for the same reason. It cannot be the FD primitive, so it answers from the
    /// two calls the frozen protocol already has; `RealFileSystem` overrides it with one `open`
    /// plus one `fstat`.
    public func statRegularFile(atPath path: String) throws -> RegularFileStat? {
        guard fileExists(atPath: path) else { return nil }
        return RegularFileStat(size: 0, modificationDate: try modificationDate(atPath: path))
    }
}
