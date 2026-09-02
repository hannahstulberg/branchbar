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

    public func fileExists(atPath path: String) -> Bool {
        let normalized = Self.normalized(path)
        lock.lock(); defer { lock.unlock() }
        return files[normalized] != nil || directories.contains(normalized)
    }

    public func isExecutableFile(atPath path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return executables.contains(Self.normalized(path))
    }

    public func readFile(atPath path: String) throws -> Data {
        let normalized = Self.normalized(path)
        lock.lock(); defer { lock.unlock() }
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

    public func homeDirectory() -> String { home }

    public func pathEnvironment() -> String { self.path }
}
