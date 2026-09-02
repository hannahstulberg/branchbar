import Foundation
import Testing

@testable import BranchBarCore

/// The cache is a latency optimisation, never a source of truth (PLAN.md §3), so every way it
/// can be wrong has to read as "no cache" rather than as an error the user sees. And the write
/// has to be atomic: a crash mid-save must leave the previous cache loadable
/// (`interruptedSaveLeavesPreviousCacheIntact`).
@Suite("FileCacheStore loads forgivingly and saves atomically")
struct FileCacheStoreTests {

    /// Whole seconds only: `.iso8601` has no fractional-second component, so a `Date` with a
    /// fractional part would not survive the round trip and the equality check would be a lie
    /// about the encoder rather than about the store.
    private static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private static func sampleCache() -> CacheFile {
        CacheFile(
            schemaVersion: CacheFile.currentSchemaVersion,
            scan: nil,
            manuallyAddedRepos: ["/Users/tester/work", "/Users/tester/Dropbox/repos"],
            hiddenRepoIDs: [RepoID(commonDir: "/Users/tester/work/old/.git")],
            collapsedRepoIDs: [RepoID(commonDir: "/Users/tester/work/big/.git")],
            prCache: [
                RepoID(commonDir: "/Users/tester/work/branchbar/.git"): PRCacheEntry(
                    fetchedAt: date(1_756_000_000),
                    prs: [
                        PRInfo(
                            number: 12,
                            url: "https://github.com/tester/branchbar/pull/12",
                            state: "OPEN",
                            isDraft: false,
                            reviewDecision: "",
                            updatedAt: date(1_755_900_000),
                            baseRefName: "main",
                            headRefName: "-my-branch",
                            headRefOid: "0123456789abcdef0123456789abcdef01234567",
                            headRepositoryOwnerLogin: "tester"
                        )
                    ],
                    authorPRs: []
                )
            ],
            lastSnapshot: nil
        )
    }

    private func store(in temp: Packet25TempDir) -> FileCacheStore {
        FileCacheStore(fileURL: temp.file("cache.json"))
    }

    @Test("roundTripsCacheFile")
    func roundTripsCacheFile() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }
        let store = store(in: temp)
        let cache = Self.sampleCache()

        try store.save(cache)
        let loaded = try store.load()

        #expect(loaded == cache)
        // `prCache` is keyed by `RepoID`, which is not a `String`, so it lands as a flat
        // alternating key/value array — key object, then value object. That is what PLAN.md §5
        // specifies (Models/Cache.swift), and it round-trips.
        let text = try String(contentsOf: temp.file("cache.json"), encoding: .utf8)
        #expect(text.contains("\"prCache\":[{\"commonDir\""))
    }

    @Test("savedJSONUsesISO8601DatesAndSortedKeys")
    func savedJSONUsesISO8601DatesAndSortedKeys() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }
        try store(in: temp).save(Self.sampleCache())

        let text = try String(contentsOf: temp.file("cache.json"), encoding: .utf8)

        // `.iso8601`, not a bare `Double` seconds-since-reference-date.
        #expect(text.contains("2025-08-24T01:46:40Z"))
        // `.sortedKeys`: a stable byte-for-byte file, so an unchanged cache is an unchanged file.
        let collapsed = try #require(text.range(of: "\"collapsedRepoIDs\"")).lowerBound
        let hidden = try #require(text.range(of: "\"hiddenRepoIDs\"")).lowerBound
        let manual = try #require(text.range(of: "\"manuallyAddedRepos\"")).lowerBound
        let schema = try #require(text.range(of: "\"schemaVersion\"")).lowerBound
        #expect(collapsed < hidden)
        #expect(hidden < manual)
        #expect(manual < schema)
    }

    @Test("missingFileLoadsNil")
    func missingFileLoadsNil() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }

        #expect(try store(in: temp).load() == nil)

        // A cache directory that does not exist yet is the first-launch case, also nil.
        let neverCreated = FileCacheStore(fileURL: temp.url.appendingPathComponent("no/such/dir/cache.json"))
        #expect(try neverCreated.load() == nil)
    }

    @Test("corruptJSONLoadsNil")
    func corruptJSONLoadsNil() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }

        try Data("{ this is not json".utf8).write(to: temp.file("cache.json"))
        #expect(try store(in: temp).load() == nil)

        // Valid JSON of the wrong shape is equally "no cache", not a thrown decode error.
        try Data("[1, 2, 3]".utf8).write(to: temp.file("cache.json"))
        #expect(try store(in: temp).load() == nil)

        // So is an empty file, which is what a truncated write would leave.
        try Data().write(to: temp.file("cache.json"))
        #expect(try store(in: temp).load() == nil)
    }

    /// PLAN.md §5: an unknown `schemaVersion` loads nil rather than migrating.
    @Test("unknownSchemaVersionLoadsNil")
    func unknownSchemaVersionLoadsNil() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }

        var future = Self.sampleCache()
        future.schemaVersion = CacheFile.currentSchemaVersion + 41
        try store(in: temp).save(future)

        // The file is well-formed and decodable — only the version is unknown.
        #expect(try store(in: temp).load() == nil)

        var older = Self.sampleCache()
        older.schemaVersion = 0
        try store(in: temp).save(older)
        #expect(try store(in: temp).load() == nil)
    }

    /// The write lands with `replaceItemAt` from a temp file in the same directory, so a save
    /// that fails partway leaves the previous `cache.json` byte-for-byte intact. The failure is
    /// simulated by making the directory unwritable, which is where a real interruption
    /// (full disk, crash before the rename) would show up.
    @Test("interruptedSaveLeavesPreviousCacheIntact")
    func interruptedSaveLeavesPreviousCacheIntact() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }
        let manager = FileManager.default
        let store = store(in: temp)

        let good = Self.sampleCache()
        try store.save(good)
        let bytesBefore = try Data(contentsOf: temp.file("cache.json"))

        var replacement = Self.sampleCache()
        replacement.manuallyAddedRepos = ["/Users/tester/should-never-land"]

        // r-x: the existing cache.json is still readable, but no temp file can be created and
        // no rename can happen.
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: temp.url.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.url.path) }

        #expect(throws: (any Error).self) { try store.save(replacement) }

        #expect(try Data(contentsOf: temp.file("cache.json")) == bytesBefore)
        #expect(try store.load() == good)

        // And no half-written scratch file is left behind once the directory is writable again.
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.url.path)
        let leftovers = try manager.contentsOfDirectory(atPath: temp.url.path)
        #expect(leftovers == ["cache.json"], "unexpected leftovers: \(leftovers)")
    }

    @Test("savingCreatesTheApplicationSupportDirectoryOnFirstLaunch")
    func savingCreatesTheDirectory() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }

        let nested = temp.url
            .appendingPathComponent("Library/Application Support/BranchBar", isDirectory: true)
            .appendingPathComponent("cache.json", isDirectory: false)
        let store = FileCacheStore(fileURL: nested)

        try store.save(Self.sampleCache())

        #expect(FileManager.default.fileExists(atPath: nested.path))
        #expect(try store.load() == Self.sampleCache())
    }

    @Test("defaultFileURLIsUnderApplicationSupport")
    func defaultFileURLIsUnderApplicationSupport() {
        let url = FileCacheStore.defaultFileURL(homeDirectory: "/Users/tester")

        #expect(url.path == "/Users/tester/Library/Application Support/BranchBar/cache.json")
    }
}

// MARK: - Packet F3 — codex MAJOR 2, the cheap half of "a cache file is not evidence"

/// `cache.json` lives in Application Support, which any process running as the user can write.
/// Decoding plus a schema check was the whole of the validation, so a crafted file could make the
/// app read an unbounded blob at launch and hold a scan valid forever by dating it in the future.
@Suite("FileCacheStore refuses an oversized file and a timestamp that has not happened")
struct FileCacheStoreTrustTests {

    private func store(in temp: Packet25TempDir) -> FileCacheStore {
        FileCacheStore(fileURL: temp.file("cache.json"))
    }

    /// The load is synchronous and on the launch path, so an unbounded file is an unbounded
    /// launch. Past the bound it reads as "no cache", which costs a scan and never shows a row.
    @Test("oversizedCacheLoadsNil")
    func oversizedCacheLoadsNil() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }
        let store = store(in: temp)

        // Valid JSON, over the bound: the size check has to come before the decode, which is
        // the expensive part this exists to skip.
        let padding = String(repeating: "a", count: FileCacheStore.maximumFileBytes + 1024)
        let json = "{\"schemaVersion\":1,\"manuallyAddedRepos\":[\"\(padding)\"],"
            + "\"hiddenRepoIDs\":[],\"collapsedRepoIDs\":[],\"prCache\":[]}"
        try Data(json.utf8).write(to: temp.file("cache.json"))
        #expect(json.utf8.count > FileCacheStore.maximumFileBytes)

        #expect(try store.load() == nil)
    }

    /// A `scannedAt`, `refreshedAt` or `fetchedAt` in the future is not evidence of anything: it
    /// makes every age check pass, so the scan never expires, the snapshot never looks stale, and
    /// the PR cache never refetches. Each is dropped on its own, so the parts of the file that
    /// are still credible — the roots the user picked, the repos they hid — survive.
    @Test("futureDatesAreDroppedFromTheLoadedCache")
    func futureDatesAreDropped() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }
        let store = store(in: temp)

        let ahead = Date().addingTimeInterval(365 * 86_400)
        let repoID = RepoID(commonDir: "/Users/tester/work/branchbar/.git")
        try store.save(CacheFile(
            scan: ScanResult(policy: ScanPolicy(homeRoot: "/Users/tester"), scannedAt: ahead,
                             repos: [DiscoveredRepo(path: "/Users/tester/work/branchbar", id: repoID)]),
            manuallyAddedRepos: ["/Users/tester/work"],
            hiddenRepoIDs: [repoID],
            prCache: [repoID: PRCacheEntry(fetchedAt: ahead)],
            lastSnapshot: Snapshot(repos: [], refreshedAt: ahead)))

        let loaded = try #require(try store.load())
        #expect(loaded.scan == nil, "a scan dated in the future was loaded as a usable scan")
        #expect(loaded.lastSnapshot == nil, "a snapshot dated in the future was loaded")
        #expect(loaded.prCache.isEmpty, "a PR entry fetched in the future was loaded")
        #expect(loaded.manuallyAddedRepos == ["/Users/tester/work"], "the user's own roots survive")
        #expect(loaded.hiddenRepoIDs == [repoID])
    }

    /// The complement, so the future check cannot quietly discard a normal cache: everything
    /// written a moment ago loads back whole.
    @Test("aCacheWrittenNowLoadsBackWhole")
    func presentDatesSurvive() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }
        let store = store(in: temp)

        let justNow = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 5).rounded())
        let repoID = RepoID(commonDir: "/Users/tester/work/branchbar/.git")
        let cache = CacheFile(
            scan: ScanResult(policy: ScanPolicy(homeRoot: "/Users/tester"), scannedAt: justNow),
            prCache: [repoID: PRCacheEntry(fetchedAt: justNow)],
            lastSnapshot: Snapshot(repos: [], refreshedAt: justNow))
        try store.save(cache)

        let loaded = try #require(try store.load())
        #expect(loaded.scan?.scannedAt == justNow)
        #expect(loaded.prCache[repoID]?.fetchedAt == justNow)
        #expect(loaded.lastSnapshot?.refreshedAt == justNow)
    }

    // MARK: - Packet F18 — codex round 5, MINOR 8

    /// codex round 5, MINOR 8. The load checks the schema version, the size, and the dates, and
    /// checked nothing about meaning: a valid JSON entry could say `source: reflogObserved` with
    /// no `observedPushAt`, and the presenter filled the hole with the branch's own commit date
    /// and rendered it as "Pushed from this Mac". The cache is documented as untrusted, so a claim
    /// with nothing behind it is taken back out at the boundary.
    @Test("cacheEntryClaimingAnObservationWithoutADateIsDowngraded")
    func cacheEntryClaimingAnObservationWithoutADateIsDowngraded() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }
        let store = store(in: temp)

        let committed = Date(timeIntervalSince1970: 1_788_000_000)
        let branch = Branch(
            name: "main",
            tipSHA: "1111111111111111111111111111111111111111",
            committerDate: committed,
            upstream: Upstream(ref: "origin/main", remote: "origin"),
            isCheckedOutInPrimary: true,
            prStatus: PRStatus.none,
            push: PushInfo(
                // The shape a tampered or corrupted file can carry: a push claimed and no date.
                observedPushAt: nil,
                observedPushOID: "2222222222222222222222222222222222222222",
                originMovedSince: true,
                source: .reflogObserved,
                hasUpstream: true,
                remoteName: "origin",
                remoteRefExists: true),
            group: .active)
        let repo = Repo(
            id: RepoID(commonDir: "/Users/tester/demo/.git"),
            name: "demo",
            path: "/Users/tester/demo",
            remoteURL: "https://github.com/tester/demo.git",
            githubSlug: GitHubSlug(host: "github.com", owner: "tester", name: "demo"),
            branches: [branch],
            prLoadState: .loaded,
            lastRefreshed: committed)
        try store.save(CacheFile(
            lastSnapshot: Snapshot(repos: [repo], refreshedAt: committed)))

        let loaded = try #require(try store.load())
        let restored = try #require(loaded.lastSnapshot?.repos.first?.branches.first)
        #expect(restored.push.source == .unavailable,
                "a push claimed with no date was loaded as an observation")
        #expect(restored.push.observedPushAt == nil)
        #expect(restored.push.observedPushOID == nil)
        #expect(!restored.push.originMovedSince, "a moved-since comparison needs an OID to compare")

        // And nothing downstream fills the hole with a commit date.
        let restoredRepo = try #require(loaded.lastSnapshot?.repos.first)
        let row = try #require(SnapshotPresenter().present(
            Snapshot(repos: [restoredRepo], refreshedAt: committed),
            refreshState: .idle(lastRefreshedAt: committed),
            collapsedRepoIDs: [],
            scanResult: nil,
            appVersion: "0.9.0",
            now: committed).sections.first?.active.first)
        #expect(!row.pushLabel.contains("Pushed from this Mac"), "\(row.pushLabel)")
        #expect(row.pushLabel == Strings.pushHistoryUnavailable)
    }
}

// MARK: - Packet F6 — codex round 2, BLOCKER 2

/// "A tampered cache FIFO can hang app initialization at FileCacheStore.swift:44." The cache load
/// is synchronous and on the launch path, and its path is a fixed one under Application Support
/// that any process running as the user can replace. Every way the cache can be wrong already
/// reads as "no cache"; a file that is not a regular file is one more of them.
@Suite("A cache file that is not a regular file loads nil rather than blocking")
struct FileCacheStoreSpecialFileTests {

    @Test("fifoCacheFileLoadsNil")
    func fifoCacheFileLoadsNil() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }
        let url = temp.file("cache.json")
        #expect(mkfifo(url.path, 0o600) == 0, "mkfifo failed: \(String(cString: strerror(errno)))")

        let started = Date()
        #expect(try FileCacheStore(fileURL: url).load() == nil)
        #expect(Date().timeIntervalSince(started) < 5, "the cache load blocked on a FIFO")
    }

    /// A symlinked cache file loads nil too: the store reads the path it owns, never wherever
    /// something else points it.
    @Test("aSymlinkedCacheFileLoadsNil")
    func symlinkedCacheFileLoadsNil() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }
        let real = temp.file("real.json")
        try FileCacheStore.makeEncoder().encode(CacheFile()).write(to: real)
        let link = temp.file("cache.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(try FileCacheStore(fileURL: link).load() == nil)
    }
}

// MARK: - Packet F15 — codex round 4, BLOCKER 3 (the cheap half)

/// "The claimed 'nonblocking FD reads' remain blockable through pathname resolution."
///
/// `load` opened the descriptor with `O_NOFOLLOW | O_NONBLOCK` and then, in front of it, asked
/// `FileManager.attributesOfItem` for the size. That preflight is a second pathname resolution
/// that follows symlinks and has no `O_NONBLOCK` of its own, on the synchronous launch path, so a
/// `cache.json` symlinked at a stalled automount parked app initialization with nothing above it
/// able to end it. The bound the preflight enforced is enforced by the read itself instead.
@Suite("The cache load has no path preflight in front of its descriptor")
struct CachePreflightTests {

    @Test("cacheLoadNeverStatsThePathBeforeReadingIt")
    func cacheLoadNeverStatsThePathBeforeReadingIt() throws {
        let file = RepoRoot.url.appendingPathComponent("Sources/BranchBarCore/FileCacheStore.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let lines = source.components(separatedBy: .newlines)

        // Only `load`'s own body: `save` legitimately uses `FileManager` to create the directory
        // and land the file, and it is not on the launch path.
        let start = try #require(lines.firstIndex { $0.contains("public func load() throws") })
        let end = try #require(lines[start...].firstIndex { $0 == "    }" })

        var offenders: [String] = []
        for index in start...end {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            // The doc comment explains why the call is gone, so only code lines count.
            if trimmed.hasPrefix("//") { continue }
            for banned in ["attributesOfItem", "FileManager"] where lines[index].contains(banned) {
                offenders.append("FileCacheStore.swift:\(index + 1) \(banned)")
            }
        }

        #expect(offenders.isEmpty,
                "a path preflight is back in front of the bounded read: \(offenders)")
    }

    /// The bound survives the preflight's removal: it is now the read that refuses, by asking for
    /// one byte more than the cap and rejecting an answer that fills it.
    @Test("aCacheOneByteOverTheBoundStillLoadsNil")
    func cacheOneByteOverTheBoundStillLoadsNil() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }
        let url = temp.file("cache.json")

        // Exactly one byte past the cap, so nothing but the read's own bound can catch it.
        var bytes = Data(repeating: UInt8(ascii: "a"), count: FileCacheStore.maximumFileBytes + 1)
        bytes[0] = UInt8(ascii: "{")
        try bytes.write(to: url)

        #expect(try FileCacheStore(fileURL: url).load() == nil)
    }
}
