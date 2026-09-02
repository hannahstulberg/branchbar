import Foundation
import Testing

@testable import BranchBarCore

// Packet 3.3 — the bounded, prompt-safe home scan.
//
// Packet 4.1's first launch hung at 0% CPU inside
// `RealFileSystem.contentsOfDirectory → attributesOfItem → getxattr` while macOS held TCC consent
// dialogs open, and `RepoScanner.scan` ran *before* the deadline-bearing task group in
// `RefreshCoordinator.run`, so nothing in the refresh could time it out. Three facts follow, and
// this file pins the two that belong to `RealFileSystem` and `RepoScanner`; the coordinator's
// half (`scanThatExceedsTheDeadlineYieldsPartialReposAndMarksScanStale`) is appended to
// `RefreshCoordinatorTests.swift`, where the repo stubs and the harness already live.
//
// 1. **One directory read per listing.** `contentsOfDirectory` asks `FileManager` for the entries
//    and the two resource keys the scanner needs in a single call, and reads the prefetched values
//    back per URL. `attributesOfItem` — which builds the whole attribute dictionary and reaches
//    xattrs — is gone from the file, pinned by `realFileSystemNeverCallsAttributesOfItem`, and the
//    listing cost is pinned by `realFileSystemListsFiveThousandEntriesUnderOneSecond`.
// 2. **The walk is cooperatively cancellable and reports the truncation.** A cancelled scan
//    returns the repos it already found with `ScanResult.truncatedByDeadline == true` instead of
//    throwing away the work or throwing `CancellationError`, so a deadline can cut a scan short
//    without costing the user the repos it had already discovered.
// 3. **TCC-gated folders go last.** Desktop, Documents and Downloads are the three folders under
//    the home root that macOS gates behind a consent dialog. The walk enumerates them after every
//    other directory it will ever open, so a pending dialog can only ever block the tail of the
//    scan — every repo outside them is already found.

// MARK: - Test-local doubles

/// Records the order in which directories were listed, forwarding everything to an
/// `InMemoryFileSystem`. `InMemoryFileSystem` is packet 1.1's shared double and outside this
/// packet's write boundary, so the recorder lives here.
private final class RecordingFileSystem: FileSystem, @unchecked Sendable {
    let base: InMemoryFileSystem
    private let lock = NSLock()
    private var storage: [String] = []

    init(_ base: InMemoryFileSystem) { self.base = base }

    /// Every path `contentsOfDirectory` was called with, in call order.
    var listedPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func contentsOfDirectory(atPath path: String) throws -> [DirectoryEntry] {
        lock.lock()
        storage.append(path)
        lock.unlock()
        return try base.contentsOfDirectory(atPath: path)
    }

    func fileExists(atPath path: String) -> Bool { base.fileExists(atPath: path) }
    func isExecutableFile(atPath path: String) -> Bool { base.isExecutableFile(atPath: path) }
    func readFile(atPath path: String) throws -> Data { try base.readFile(atPath: path) }
    func modificationDate(atPath path: String) throws -> Date { try base.modificationDate(atPath: path) }
    func homeDirectory() -> String { base.homeDirectory() }
    func pathEnvironment() -> String { base.pathEnvironment() }
}

/// Blocks inside `contentsOfDirectory` for any path at or under `gate` until the task running the
/// walk is cancelled — the shape a TCC consent dialog gives a listing that never returns. The
/// hard stop keeps a regression from hanging the suite: an implementation that never checks
/// cancellation fails on the assertions rather than by timing out.
private final class ScanGateFileSystem: FileSystem, @unchecked Sendable {
    let base: InMemoryFileSystem
    let gate: String
    private let lock = NSLock()
    private var _reachedGate = false

    init(_ base: InMemoryFileSystem, gate: String) {
        self.base = base
        self.gate = gate
    }

    var reachedGate: Bool {
        lock.lock(); defer { lock.unlock() }
        return _reachedGate
    }

    func contentsOfDirectory(atPath path: String) throws -> [DirectoryEntry] {
        if path == gate || path.hasPrefix(gate + "/") {
            lock.lock(); _reachedGate = true; lock.unlock()
            let hardStop = Date().addingTimeInterval(10)
            while !Task.isCancelled && Date() < hardStop {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        return try base.contentsOfDirectory(atPath: path)
    }

    func fileExists(atPath path: String) -> Bool { base.fileExists(atPath: path) }
    func isExecutableFile(atPath path: String) -> Bool { base.isExecutableFile(atPath: path) }
    func readFile(atPath path: String) throws -> Data { try base.readFile(atPath: path) }
    func modificationDate(atPath path: String) throws -> Date { try base.modificationDate(atPath: path) }
    func homeDirectory() -> String { base.homeDirectory() }
    func pathEnvironment() -> String { base.pathEnvironment() }
}

/// Polls until `condition` holds or `timeout` elapses; used only to sequence a cancel against a
/// walk that is already running.
private func waitForScan(_ timeout: TimeInterval = 5, _ condition: @Sendable () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

// MARK: - RealFileSystem: one directory read per listing

@Suite("RealFileSystem lists a directory in one read, without per-entry attribute lookups")
struct RealFileSystemListingCostTests {

    /// The 4.1 hang was inside `attributesOfItem`'s `getxattr`. The two facts the scanner needs
    /// (`isDirectory` following the link, `isSymbolicLink` about the entry) both come out of the
    /// listing's prefetched resource values, so the call has no business left there.
    /// `modificationDate` reads `.contentModificationDateKey` for the same reason.
    @Test("realFileSystemNeverCallsAttributesOfItem")
    func realFileSystemNeverCallsAttributesOfItem() throws {
        let file = RepoRoot.url.appendingPathComponent("Sources/BranchBarCore/RealFileSystem.swift")
        let source = try String(contentsOf: file, encoding: .utf8)

        var offenders: [String] = []
        for (index, line) in source.components(separatedBy: .newlines).enumerated() {
            // The doc comments explain why the call is gone, so only code lines count.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
            for banned in ["attributesOfItem", "getxattr"] where line.contains(banned) {
                offenders.append("RealFileSystem.swift:\(index + 1) \(banned)")
            }
        }

        #expect(offenders.isEmpty, "per-entry attribute lookups are back: \(offenders)")
    }

    /// The perf-style stand-in for "one `readdir` per listing": 5,000 entries is roughly what a
    /// busy `~/Downloads` holds, and a per-entry `attributesOfItem` walk over it costs seconds.
    @Test("realFileSystemListsFiveThousandEntriesUnderOneSecond")
    func realFileSystemListsFiveThousandEntriesUnderOneSecond() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }
        let manager = FileManager.default

        // Empty files: the test is about the cost of *listing* 5,000 entries, so it should not
        // spend its time writing them, and it shares the machine with the suite's timing tests.
        for index in 0..<4_900 {
            #expect(manager.createFile(atPath: temp.file("entry-\(index)").path, contents: nil))
        }
        for index in 0..<100 {
            try manager.createDirectory(at: temp.file("dir-\(index)"), withIntermediateDirectories: false)
        }

        let fileSystem = RealFileSystem()
        let started = Date()
        let entries = try fileSystem.contentsOfDirectory(atPath: temp.url.path)
        let elapsed = Date().timeIntervalSince(started)

        #expect(entries.count == 5_000)
        #expect(entries.filter(\.isDirectory).count == 100)
        #expect(entries.allSatisfy { !$0.isSymbolicLink })
        #expect(elapsed < 1, "listing 5,000 entries took \(elapsed) s")
    }
}

// MARK: - RepoScanner: cancellation and TCC ordering

@Suite("RepoScanner stops cooperatively and leaves the TCC-gated folders for last")
struct RepoScannerBoundedWalkTests {

    /// A cancelled walk is a *partial* answer, not a lost one: the repos found before the cut
    /// survive, and `truncatedByDeadline` is what tells the coordinator the list is incomplete and
    /// the cache entry may not be trusted as a finished scan.
    @Test("scanIsCooperativelyCancellable")
    func scanIsCooperativelyCancellable() async throws {
        let inMemory = InMemoryFileSystem(home: "/Users/tester")
        inMemory.addRepository(at: "/Users/tester/alpha")
        inMemory.addRepository(at: "/Users/tester/beta")
        // Reached last (it is TCC-gated), and never returns until the task is cancelled.
        inMemory.addRepository(at: "/Users/tester/Documents/notes")
        let fileSystem = ScanGateFileSystem(inMemory, gate: "/Users/tester/Documents")

        let scanner = RepoScanner(fileSystem: fileSystem)
        let task = Task { try await scanner.scan(policy: ScanPolicy(homeRoot: "/Users/tester")) }
        await waitForScan { fileSystem.reachedGate }
        task.cancel()

        let result = try await task.value

        #expect(result.truncatedByDeadline)
        #expect(result.repos.map(\.path) == ["/Users/tester/alpha", "/Users/tester/beta"])
        // The folder the walk was cut off before it could read is reported the same way a folder
        // macOS refused is: "not scanned", with the same recovery.
        #expect(result.unreadableDirectories.contains("/Users/tester/Documents"))
    }

    /// An uncancelled scan says so, so `truncatedByDeadline` cannot quietly become a permanent
    /// "rescan every time" flag.
    @Test("aScanThatFinishesIsNotMarkedTruncated")
    func aScanThatFinishesIsNotMarkedTruncated() async throws {
        let inMemory = InMemoryFileSystem(home: "/Users/tester")
        inMemory.addRepository(at: "/Users/tester/alpha")
        inMemory.addRepository(at: "/Users/tester/Documents/notes")

        let result = try await RepoScanner(fileSystem: inMemory)
            .scan(policy: ScanPolicy(homeRoot: "/Users/tester"))

        #expect(!result.truncatedByDeadline)
        #expect(result.repos.map(\.path) == ["/Users/tester/Documents/notes", "/Users/tester/alpha"])
    }

    /// PLAN.md §3's scan is auto-triggered on first launch, so the consent dialogs for Desktop,
    /// Documents and Downloads arrive while it is running. Enumerating those three last means a
    /// dialog can only block work that has no repos left behind it: everything else has already
    /// been walked and every repo outside them is already in the result.
    @Test("tccGatedFoldersAreEnumeratedLast")
    func tccGatedFoldersAreEnumeratedLast() async throws {
        let inMemory = InMemoryFileSystem(home: "/Users/tester")
        inMemory.addRepository(at: "/Users/tester/code/app")
        inMemory.addRepository(at: "/Users/tester/Documents/notes")
        inMemory.addRepository(at: "/Users/tester/Desktop/scratch")
        inMemory.addRepository(at: "/Users/tester/Downloads/clone")
        // A directory only the deepest leg of the walk reaches, to prove the ordering is not just
        // "gated folders after the home root's other children".
        inMemory.addDirectory("/Users/tester/src/a/b/c/d")
        // Same names, one level down: the rule is about the three folders macOS gates, which are
        // children of the home root, not about the words.
        inMemory.addRepository(at: "/Users/tester/src/Documents/inner")

        let fileSystem = RecordingFileSystem(inMemory)
        let result = try await RepoScanner(fileSystem: fileSystem)
            .scan(policy: ScanPolicy(homeRoot: "/Users/tester"))

        // Ordering never costs a repo.
        #expect(result.repos.map(\.path) == [
            "/Users/tester/Desktop/scratch",
            "/Users/tester/Documents/notes",
            "/Users/tester/Downloads/clone",
            "/Users/tester/code/app",
            "/Users/tester/src/Documents/inner",
        ])

        let listed = fileSystem.listedPaths
        let gatedRoots = ["/Users/tester/Desktop", "/Users/tester/Documents", "/Users/tester/Downloads"]
        let isGated: (String) -> Bool = { path in
            gatedRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        let firstGated = try #require(listed.firstIndex(where: isGated))
        let lastUngated = try #require(listed.lastIndex(where: { !isGated($0) }))
        #expect(
            lastUngated < firstGated,
            "\(listed[lastUngated]) was listed after \(listed[firstGated])"
        )

        // The deep leg and the same-named folder one level down are on the early side of the line.
        let deepest = try #require(listed.firstIndex(of: "/Users/tester/src/a/b/c/d"))
        let innerDocuments = try #require(listed.firstIndex(of: "/Users/tester/src/Documents"))
        #expect(deepest < firstGated)
        #expect(innerDocuments < firstGated)
        for root in gatedRoots { #expect(listed.contains(root), "\(root) was never listed") }
    }

    /// The deferral applies to the home root, which is the only root macOS gates by name. A folder
    /// the user added through "Add folder…" is walked in its own right, so a `Documents` inside it
    /// is not held back — there is no consent dialog left to wait for once the panel granted it.
    @Test("anAddedRootNamedDocumentsIsWalkedWithoutDeferral")
    func anAddedRootNamedDocumentsIsWalkedWithoutDeferral() async throws {
        let inMemory = InMemoryFileSystem(home: "/Users/tester")
        inMemory.addRepository(at: "/Volumes/Work/Documents/project")
        inMemory.addDirectory("/Volumes/Work/other")

        let fileSystem = RecordingFileSystem(inMemory)
        let result = try await RepoScanner(fileSystem: fileSystem).scan(
            policy: ScanPolicy(homeRoot: "/Users/tester", extraRoots: ["/Volumes/Work"]))

        #expect(result.repos.map(\.path) == ["/Volumes/Work/Documents/project"])
        let listed = fileSystem.listedPaths
        let documents = try #require(listed.firstIndex(of: "/Volumes/Work/Documents"))
        let other = try #require(listed.firstIndex(of: "/Volumes/Work/other"))
        // Plain breadth-first order, whichever the listing yields first — not "Documents last".
        #expect(abs(documents - other) == 1)
    }
}
