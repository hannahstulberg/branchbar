import Foundation

@testable import BranchBarCore

/// A dictionary-backed `FileSystem`. Lets the scanner tests build a home folder with a repo at
/// depth 6 and one at depth 7, a `.git` file pointing into `…/worktrees/…`, and a directory that
/// throws EPERM, without touching the real disk or a TCC prompt.
public final class InMemoryFileSystem: FileSystem, @unchecked Sendable {

    /// Raised for a path in `unreadableDirectories`; shaped like the error a TCC denial produces.
    public struct PermissionDenied: Error, CustomStringConvertible {
        public var path: String
        public var description: String { "Operation not permitted: \(path)" }
    }

    private let lock = NSLock()
    private var directories: Set<String> = []
    private var files: [String: Data] = [:]
    private var mtimes: [String: Date] = [:]
    private var executables: Set<String> = []
    private var symlinks: Set<String> = []
    /// Reading these throws, the way a TCC-denied Documents folder does.
    private var unreadable: Set<String> = []
    /// Volume roots this tree models as something other than a local disk (codex round 4,
    /// BLOCKER 3). Keyed by the exact path `volumeKind(for:)` is asked about.
    private var volumeKinds: [String: VolumeKind] = [:]

    public var home: String
    public var path: String

    public init(home: String = "/Users/tester", path: String = "/usr/bin:/bin:/usr/sbin:/sbin") {
        self.home = home
        self.path = path
        addDirectory(home)
    }

    // MARK: Building a tree

    /// Adds the directory and every ancestor.
    public func addDirectory(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        var current = Self.normalized(path)
        while current != "/" && !current.isEmpty {
            directories.insert(current)
            current = (current as NSString).deletingLastPathComponent
        }
    }

    public func addFile(_ path: String, contents: String, modified: Date = Date(timeIntervalSince1970: 0)) {
        addFile(path, data: Data(contents.utf8), modified: modified)
    }

    public func addFile(_ path: String, data: Data, modified: Date = Date(timeIntervalSince1970: 0)) {
        let normalized = Self.normalized(path)
        addDirectory((normalized as NSString).deletingLastPathComponent)
        lock.lock(); defer { lock.unlock() }
        files[normalized] = data
        mtimes[normalized] = modified
    }

    /// A repo marker: `<repo>/.git/` as a real directory.
    public func addRepository(at path: String, commonDirectory: String? = nil) {
        let normalized = Self.normalized(path)
        addDirectory((commonDirectory ?? (normalized + "/.git")))
    }

    /// A `.git` file, as a linked worktree or a submodule writes it.
    public func addGitFile(at path: String, gitdir: String) {
        addFile(Self.normalized(path) + "/.git", contents: "gitdir: \(gitdir)\n")
    }

    public func addExecutable(_ path: String) {
        addFile(path, contents: "")
        lock.lock(); defer { lock.unlock() }
        executables.insert(Self.normalized(path))
    }

    public func addSymbolicLink(_ path: String) {
        let normalized = Self.normalized(path)
        addDirectory((normalized as NSString).deletingLastPathComponent)
        lock.lock(); defer { lock.unlock() }
        directories.insert(normalized)
        symlinks.insert(normalized)
    }

    /// Models a mount: `/Volumes/nas` served over `smbfs`, or a mount point whose `statfs`
    /// fails the way a disconnected one does.
    public func setVolumeKind(_ kind: VolumeKind, for path: String) {
        lock.lock(); defer { lock.unlock() }
        volumeKinds[Self.normalized(path)] = kind
    }

    public func markUnreadable(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        unreadable.insert(Self.normalized(path))
    }

    static func normalized(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: FileSystem

    public func contentsOfDirectory(atPath path: String) throws -> [DirectoryEntry] {
        let parent = Self.normalized(path)
        lock.lock(); defer { lock.unlock() }
        if unreadable.contains(parent) { throw PermissionDenied(path: parent) }
        guard directories.contains(parent) else { throw PermissionDenied(path: parent) }

        let prefix = parent == "/" ? "/" : parent + "/"
        var seen: [String: DirectoryEntry] = [:]

        for candidate in directories.union(files.keys) where candidate.hasPrefix(prefix) && candidate != parent {
            let remainder = candidate.dropFirst(prefix.count)
            guard let first = remainder.split(separator: "/").first else { continue }
            let name = String(first)
            let childPath = prefix + name
            seen[name] = DirectoryEntry(
                name: name,
                path: childPath,
                isDirectory: directories.contains(childPath),
                isSymbolicLink: symlinks.contains(childPath)
            )
        }
        return seen.values.sorted { $0.name < $1.name }
    }

    /// Counted so `reflogAbsenceIsDeterminedByOpenErrno` can prove the reflog reader stopped
    /// preflighting with it (codex round 3, BLOCKER 2).
    public private(set) var fileExistsCallCount = 0

    public func fileExists(atPath path: String) -> Bool {
        let normalized = Self.normalized(path)
        lock.lock(); defer { lock.unlock() }
        fileExistsCallCount += 1
        return files[normalized] != nil || directories.contains(normalized)
    }

    /// The double's answer to the no-follow directory check: an entry this tree holds as a
    /// directory and does not hold as a symlink. A symlink is refused for the same reason
    /// `RealFileSystem` passes `O_NOFOLLOW` — the row claims to open the thing at this path.
    public func isDirectoryNoFollow(atPath path: String) -> Bool {
        let normalized = Self.normalized(path)
        lock.lock(); defer { lock.unlock() }
        return directories.contains(normalized) && !symlinks.contains(normalized)
    }

    /// nil for a path this tree does not hold at all; throws for one it holds as unreadable or as
    /// something that is not a regular file — the two answers `RealFileSystem` gives from one
    /// `open` plus one `fstat`, with no `fileExists` in front of either.
    /// Counted so `repoOnANetworkVolumeSkipsDirectFileReads` can prove the loader never opened a
    /// descriptor against a mount that cannot be trusted to answer.
    public private(set) var statRegularFileCallCount = 0
    public private(set) var readFileCallCount = 0

    public func statRegularFile(atPath path: String) throws -> RegularFileStat? {
        let normalized = Self.normalized(path)
        lock.lock(); defer { lock.unlock() }
        statRegularFileCallCount += 1
        if unreadable.contains(normalized) { throw PermissionDenied(path: normalized) }
        if let data = files[normalized] {
            return RegularFileStat(
                size: data.count,
                modificationDate: mtimes[normalized] ?? Date(timeIntervalSince1970: 0))
        }
        if directories.contains(normalized) {
            throw FileReadError.notARegularFile(path: normalized)
        }
        return nil
    }

    public func isExecutableFile(atPath path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return executables.contains(Self.normalized(path))
    }

    public func readFile(atPath path: String) throws -> Data {
        let normalized = Self.normalized(path)
        lock.lock(); defer { lock.unlock() }
        readFileCallCount += 1
        if unreadable.contains(normalized) { throw PermissionDenied(path: normalized) }
        guard let data = files[normalized] else { throw PermissionDenied(path: normalized) }
        return data
    }

    public func modificationDate(atPath path: String) throws -> Date {
        let normalized = Self.normalized(path)
        lock.lock(); defer { lock.unlock() }
        guard let date = mtimes[normalized] else { throw PermissionDenied(path: normalized) }
        return date
    }

    /// The tree's own mount table; anything it does not name is a local disk.
    public func volumeKind(for path: String) -> VolumeKind {
        let normalized = Self.normalized(path)
        lock.lock(); defer { lock.unlock() }
        return volumeKinds[normalized] ?? .local
    }

    public func homeDirectory() -> String { home }

    public func pathEnvironment() -> String { self.path }
}
