import Foundation

/// Why a bounded read refused (codex round 2, BLOCKER 2 and MINOR 3).
public enum FileReadError: Error, Hashable, Sendable {
    case openFailed(path: String, code: Int32)
    case notARegularFile(path: String)
    case readFailed(path: String, code: Int32)
    case entryTypeUnknown(path: String)
}

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

        return try urls.map { url in
            let name = url.lastPathComponent
            // Built in the string domain from the path the caller gave, not from the URL: a URL
            // listing resolves `/var` to `/private/var`, and the scanner's dedupe keys and the
            // reflog paths are the caller's own strings.
            let entryPath = (path as NSString).appendingPathComponent(name)

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let flags = try Self.entryFlags(
                isDirectory: values?.isDirectory,
                isSymbolicLink: values?.isSymbolicLink,
                path: entryPath)

            return DirectoryEntry(
                name: name,
                path: entryPath,
                isDirectory: flags.isDirectory,
                isSymbolicLink: flags.isSymbolicLink
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

    /// One `open(O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)` and a close (codex round 3,
    /// BLOCKER 1). Each flag answers a different half of the question the row action asks:
    ///
    /// - `O_DIRECTORY` makes the kernel refuse anything that is not a directory, so a regular
    ///   file — a `.command` document Terminal would execute — never reaches an action payload.
    /// - `O_NOFOLLOW` refuses a symlink, because "the thing at this path" is what the row claims
    ///   to open, not wherever it points today.
    /// - `O_NONBLOCK` keeps a device or a FIFO at that path from parking this call in the kernel,
    ///   which is the same unkillable state `readBoundedRegularFile` exists to avoid.
    /// - `O_CLOEXEC` keeps the descriptor out of the children `ProcessCommandRunner` spawns.
    ///
    /// No `stat` of a path and no `FileManager.fileExists(atPath:isDirectory:)`: both answer for a
    /// path that can change between the answer and its use, and both follow symlinks.
    public func isDirectoryNoFollow(atPath path: String) -> Bool {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    /// The same primitive `readBoundedRegularFile` opens with, stopping at the `fstat` (codex
    /// round 3, BLOCKER 2).
    ///
    /// Absence is the **open's** errno and not a `fileExists` preflight: the preflight was a
    /// second path lookup that answered a moment earlier about a path rather than about the
    /// descriptor the answer would be used with, and `FETCH_HEAD`'s modification time came from a
    /// URL resource-value read that follows symlinks and blocks on a FIFO — outside the killable
    /// helper, on the startup path.
    ///
    /// `ENOENT` and `ENOTDIR` are "there is nothing here", which is nil. `ELOOP` is a symlink this
    /// call refused to follow, which is also nothing this reader will vouch for. Everything else —
    /// `EACCES` above all — is a failure the caller reports, because reading it as absence would
    /// render "never pushed" for a branch whose history this process simply may not read. A path
    /// that opens and is not `S_IFREG` throws too: a FIFO where a reflog belongs is a fact, not an
    /// absence.
    public func statRegularFile(atPath path: String) throws -> RegularFileStat? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR || code == ELOOP { return nil }
            throw FileReadError.openFailed(path: path, code: code)
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw FileReadError.openFailed(path: path, code: errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw FileReadError.notARegularFile(path: path)
        }
        return RegularFileStat(
            size: max(0, Int(status.st_size)),
            modificationDate: Date(
                timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                    + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000))
    }

    /// One `openat(… O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)` per path component, each from the
    /// descriptor the previous one produced (codex round 4, MAJOR 3).
    ///
    /// `isDirectoryNoFollow` refuses a symlink at the **last** component and says nothing about the
    /// ones in front of it, so `/Users/name/link/System` — where `link` is a symlink the user's own
    /// account may replace at any moment — passed a check whose whole purpose was to bound where an
    /// unbounded-depth scan may go. Walking descriptors rather than re-resolving the pathname also
    /// closes the gap between the answer and its use: each `openat` starts from a directory this
    /// process is already holding open, so a component renamed mid-walk cannot redirect the rest.
    ///
    /// `O_NONBLOCK` for the same reason every other open in this file carries it: a component that
    /// is an automount or a dead network mount must fail rather than park the caller in the kernel.
    public func isDirectoryPathWithoutSymlinks(atPath path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { return false }
        guard components.allSatisfy({ $0 != "." && $0 != ".." }) else { return false }

        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        for component in components {
            let next = openat(
                descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { return false }
            descriptor = next
        }
        close(descriptor)
        return true
    }

    /// `statfs` on the volume root a path sits under, or `.local` for a path that is not under a
    /// mount point at all (codex round 4, BLOCKER 3).
    ///
    /// The filesystem type is the fact worth having: `nfs`, `smbfs`, `afpfs`, and `webdav` mounts
    /// are served by another machine, and when that machine goes away every `open()` against the
    /// mount blocks uninterruptibly. `statfs` failing is the same answer arrived at sooner — a
    /// stale mount point already refuses to describe itself.
    public func volumeKind(for path: String) -> VolumeKind {
        var buffer = statfs()
        guard statfs(path, &buffer) == 0 else { return .unreachable(code: errno) }
        let type = withUnsafeBytes(of: buffer.f_fstypename) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return Self.networkFilesystemTypes.contains(type.lowercased())
            ? .network(type: type)
            : .local
    }

    /// The `f_fstypename` values that mean "another machine answers every read".
    public static let networkFilesystemTypes: Set<String> = ["nfs", "smbfs", "afpfs", "webdav", "ftp"]

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

extension RealFileSystem {
    /// The one primitive every bounded read goes through: `.git` markers, reflog files, and the
    /// cache file (codex round 2, BLOCKER 2).
    ///
    /// `FileHandle(forReadingFrom:)` is `open(O_RDONLY)` with symlinks followed and no type check.
    /// A `.git`, a reflog, or a `cache.json` that is really a FIFO — or a symlink to one — parked
    /// the caller inside the kernel until a writer appeared, which for an attacker-planted pipe is
    /// never. That is BLOCKER 1's unkillable state reached through a file instead of a directory,
    /// and no deadline above it helps.
    ///
    /// Four flags and a check, in this order, and each one is load-bearing:
    ///
    /// - `O_NOFOLLOW` refuses a symlink outright. The walk was told to stay inside a tree, and a
    ///   marker that points somewhere else is not a marker this code will vouch for.
    /// - `O_NONBLOCK` makes the **open** return even when the path is a FIFO with no writer.
    /// - `O_CLOEXEC` keeps the descriptor out of the children `ProcessCommandRunner` spawns.
    /// - `fstat` on the descriptor already opened (never a path, which could have changed
    ///   underneath) must say `S_IFREG`. A directory, a FIFO, a device, or a socket is refused
    ///   here rather than blocking in the read.
    ///
    /// Then one `pread` of the bounded window: `pread` rather than `read` because `O_NONBLOCK` is
    /// still set and an offset read needs no seek. A short read is a short file, not an error.
    public func readBoundedRegularFile(path: String, maxBytes: Int, tail: Bool) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw FileReadError.openFailed(path: path, code: errno) }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw FileReadError.openFailed(path: path, code: errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw FileReadError.notARegularFile(path: path)
        }

        let bound = max(0, maxBytes)
        let size = max(0, Int(status.st_size))
        let count = min(bound, size)
        guard count > 0 else { return Data() }
        // The tail is what a reflog wants: its newest lines are its last ones.
        let offset = tail ? size - count : 0

        var buffer = [UInt8](repeating: 0, count: count)
        var read = 0
        while read < count {
            let got = buffer[read...].withUnsafeMutableBufferPointer { slice in
                pread(descriptor, slice.baseAddress, count - read, off_t(offset + read))
            }
            if got > 0 {
                read += got
                continue
            }
            if got == 0 { break }  // the file shrank under us; what was read is what there is
            if errno == EINTR { continue }
            throw FileReadError.readFailed(path: path, code: errno)
        }
        return Data(buffer.prefix(read))
    }

    /// What one directory entry's two resource values mean, with "the lookup failed" kept apart
    /// from "the answer is no" (codex round 2, MINOR 3).
    ///
    /// A failed lookup used to collapse to `false/false`, so a directory on a degraded or unusual
    /// filesystem was silently walked past as a file: no repo found inside it and nothing on
    /// screen saying why. An entry whose type nobody can establish throws, and the caller reports
    /// the **parent** directory as not scanned — the row the user can act on, and the same row a
    /// TCC denial produces.
    ///
    /// A known symlink needs no directory answer: the walk never follows one, so the target is
    /// never touched and its absence is not a failure.
    static func entryFlags(
        isDirectory: Bool?, isSymbolicLink: Bool?, path: String
    ) throws -> (isDirectory: Bool, isSymbolicLink: Bool) {
        if isSymbolicLink == true { return (isDirectory: false, isSymbolicLink: true) }
        guard let isDirectory, isSymbolicLink != nil else {
            throw FileReadError.entryTypeUnknown(path: path)
        }
        return (isDirectory: isDirectory, isSymbolicLink: false)
    }
}

extension RealFileSystem: BoundedFileReading {
    /// A bounded prefix of a regular file, and nothing else — see `readBoundedRegularFile`.
    public func readFile(atPath path: String, maximumBytes: Int) throws -> Data {
        try readBoundedRegularFile(path: path, maxBytes: maximumBytes, tail: false)
    }

    /// The last `maximumBytes` of a regular file, for a reflog whose newest lines are last.
    public func readFileTail(atPath path: String, maximumBytes: Int) throws -> Data {
        try readBoundedRegularFile(path: path, maxBytes: maximumBytes, tail: true)
    }
}
