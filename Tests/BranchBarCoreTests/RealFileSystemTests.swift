import Foundation
import Testing

@testable import BranchBarCore

/// A scratch directory under the system temporary directory, removed by the test that made it.
/// Named for packet 2.5 so it cannot collide with a helper another packet adds to this module.
struct Packet25TempDir {
    let url: URL

    init(name: String = "branchbar-2.5-\(UUID().uuidString)") throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name, isDirectory: false) }

    /// Restores permissions first, so a directory a test made unreadable still cleans up.
    func remove() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }
}

/// The `FileSystem` seam exists so the home scan and the reflog reader never touch the real home
/// folder in a unit test (PLAN.md §4). `RealFileSystem` is the one implementation that does, so
/// these tests give it a temp directory and check the two facts the scanner depends on:
/// symlinks are reported as symlinks, and an unreadable directory throws rather than reading as
/// empty (`unreadableDirectoryIsReportedNotSilentlySkipped`).
@Suite("RealFileSystem over a temp directory")
struct RealFileSystemTests {

    @Test("realFileSystemReportsSymlinksAndUnreadableDirs")
    func realFileSystemReportsSymlinksAndUnreadableDirs() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }
        let manager = FileManager.default
        let fileSystem = RealFileSystem()

        // A plain directory, a plain file, a symlink to the directory, and a symlink to the file.
        let realDirectory = temp.file("repo")
        try manager.createDirectory(at: realDirectory, withIntermediateDirectories: false)
        let realFile = temp.file("HEAD")
        try Data("ref: refs/heads/main\n".utf8).write(to: realFile)
        let linkToDirectory = temp.file("linked-repo")
        try manager.createSymbolicLink(at: linkToDirectory, withDestinationURL: realDirectory)
        let linkToFile = temp.file("linked-HEAD")
        try manager.createSymbolicLink(at: linkToFile, withDestinationURL: realFile)

        let entries = try fileSystem.contentsOfDirectory(atPath: temp.url.path)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

        #expect(Set(byName.keys) == ["repo", "HEAD", "linked-repo", "linked-HEAD"])

        #expect(byName["repo"]?.isDirectory == true)
        #expect(byName["repo"]?.isSymbolicLink == false)
        #expect(byName["repo"]?.path == realDirectory.path)

        #expect(byName["HEAD"]?.isDirectory == false)
        #expect(byName["HEAD"]?.isSymbolicLink == false)

        // A symlink to a directory is both: the scanner needs `isDirectory` to decide whether to
        // descend and `isSymbolicLink` to decide whether it should.
        #expect(byName["linked-repo"]?.isSymbolicLink == true)
        #expect(byName["linked-repo"]?.isDirectory == true)
        #expect(byName["linked-HEAD"]?.isSymbolicLink == true)
        #expect(byName["linked-HEAD"]?.isDirectory == false)

        // An unreadable directory is reported, not silently skipped. A TCC denial on
        // ~/Documents looks exactly like this.
        let unreadable = temp.file("locked")
        try manager.createDirectory(at: unreadable, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: unreadable.appendingPathComponent("inside"))
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadable.path) }

        #expect(throws: (any Error).self) {
            _ = try fileSystem.contentsOfDirectory(atPath: unreadable.path)
        }

        // A directory that does not exist throws too, rather than returning an empty listing.
        #expect(throws: (any Error).self) {
            _ = try fileSystem.contentsOfDirectory(atPath: temp.file("absent").path)
        }
    }

    @Test("readFile, fileExists, isExecutableFile and modificationDate answer about real files")
    func readsFilesAndAttributes() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }
        let fileSystem = RealFileSystem()

        let file = temp.file("FETCH_HEAD")
        let contents = Data("abc123\tbranch 'main' of github.com\n".utf8)
        try contents.write(to: file)

        #expect(fileSystem.fileExists(atPath: file.path))
        #expect(!fileSystem.fileExists(atPath: temp.file("nope").path))
        #expect(try fileSystem.readFile(atPath: file.path) == contents)
        #expect(throws: (any Error).self) {
            _ = try fileSystem.readFile(atPath: temp.file("nope").path)
        }

        // FETCH_HEAD's mtime backs the ahead-count tooltip (PLAN.md §3).
        let modified = try fileSystem.modificationDate(atPath: file.path)
        #expect(abs(modified.timeIntervalSinceNow) < 60)
        #expect(throws: (any Error).self) {
            _ = try fileSystem.modificationDate(atPath: temp.file("nope").path)
        }

        #expect(!fileSystem.isExecutableFile(atPath: file.path))
        #expect(fileSystem.isExecutableFile(atPath: "/bin/sh"))
    }

    @Test("homeDirectory and pathEnvironment report the process's own values")
    func reportsHomeAndPath() {
        let fileSystem = RealFileSystem()

        #expect(fileSystem.homeDirectory() == FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(fileSystem.homeDirectory().hasPrefix("/"))

        // A GUI-launched app inherits launchd's PATH; the value is whatever this process has,
        // and it is never empty, because `ToolLocator` splits it.
        #expect(!fileSystem.pathEnvironment().isEmpty)
        #expect(fileSystem.pathEnvironment().contains("/usr/bin"))
    }
}
