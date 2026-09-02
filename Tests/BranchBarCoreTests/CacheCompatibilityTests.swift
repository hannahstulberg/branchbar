import Foundation
import Testing

@testable import BranchBarCore

// Packet F12 — a field added after the packet 1.1 freeze must not throw away the cache.
//
// Every field added since 4ac815f carries a comment saying it is "defaulted so a cache written
// before the field existed still decodes". For a non-optional stored property that sentence was
// false: a *synthesized* `init(from:)` calls `decode(_:forKey:)` for every non-optional property
// and never consults the property's default, so one missing key threw `keyNotFound`,
// `FileCacheStore.load` swallowed it as "no cache", and the user paid a cold rescan and an empty
// popover on the first launch after every upgrade that added one.
//
// The fix is an explicit `init(from:)` per type that gained a field: `decodeIfPresent` with the
// intended default for the added keys, plain `decode` for everything frozen in 1.1 — so a file
// that is missing a *required* key is still not a cache (`corruptJSONLoadsNil`), and only the
// keys that postdate the freeze are optional to read. `encode` stays synthesized: a cache this
// version writes always carries every key.

/// The whole-file case: a `cache.json` in the shapes packet 1.1 froze, hand-written from
/// `git show 4ac815f:Sources/BranchBarCore/Models/*.swift`, loaded through the real store.
@Suite("A cache written before the added fields still loads")
struct CacheCompatibilityTests {

    /// Decoded straight, so a failure names the missing key instead of the store's nil.
    @Test("cacheWrittenBeforeAddedFieldsStillDecodes")
    func cacheWrittenBeforeAddedFieldsStillDecodes() throws {
        let data = Fixture.data("cache-1.1-era.json")

        let cache: CacheFile
        do {
            cache = try FileCacheStore.makeDecoder().decode(CacheFile.self, from: data)
        } catch {
            Issue.record("a 1.1-era cache no longer decodes: \(error)")
            return
        }

        // The parts of the file that were already there survive unchanged.
        #expect(cache.schemaVersion == 1)
        #expect(cache.manuallyAddedRepos == ["/Users/tester/work"])
        #expect(cache.hiddenRepoIDs == [RepoID(commonDir: "/Users/tester/work/old/.git")])
        #expect(cache.scan?.repos.count == 1)
        #expect(cache.scan?.unreadableDirectories == ["/Users/tester/Documents"])
        #expect(cache.lastSnapshot?.repos.count == 1)

        // And every key added after the freeze reads as its documented default.
        #expect(cache.scan?.truncatedByDeadline == false)
        let entry = try #require(cache.prCache[RepoID(commonDir: "/Users/tester/work/branchbar/.git")])
        #expect(entry.queriedHeads == [])
        #expect(entry.prs.count == 1)
        let repo = try #require(cache.lastSnapshot?.repos.first)
        #expect(repo.remoteOwners == [:])
        let push = try #require(repo.branches.first?.push)
        #expect(push.remoteTipCommitDate == nil)
        #expect(push.remoteName == nil)
        #expect(push.remoteRefExists == false)
        // The frozen half of the same struct is read, not defaulted.
        #expect(push.hasUpstream)
        #expect(push.source == .reflogObserved)
    }

    /// The same file through `FileCacheStore.load`, which is where the cost was paid: a throw
    /// there is indistinguishable from no cache at all, so the launch scanned from scratch.
    @Test("theStoreLoadsA11EraCacheRatherThanTreatingItAsAbsent")
    func storeLoadsA11EraCache() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }
        try Fixture.data("cache-1.1-era.json").write(to: temp.file("cache.json"))

        let loaded = try FileCacheStore(fileURL: temp.file("cache.json")).load()

        let cache = try #require(loaded, "a 1.1-era cache loaded as no cache at all")
        #expect(cache.lastSnapshot?.repos.first?.name == "branchbar")
    }

    /// A file missing a key that 1.1 itself required is still not a cache. The added-field
    /// leniency is per key, not a blanket "decode whatever is there".
    @Test("aCacheMissingAFrozenKeyIsStillNoCache")
    func missingFrozenKeyIsStillNoCache() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }
        var object = try #require(
            try JSONSerialization.jsonObject(with: Fixture.data("cache-1.1-era.json")) as? [String: Any])
        var scan = try #require(object["scan"] as? [String: Any])
        scan.removeValue(forKey: "scannedAt")
        object["scan"] = scan
        try JSONSerialization.data(withJSONObject: object).write(to: temp.file("cache.json"))

        #expect(try FileCacheStore(fileURL: temp.file("cache.json")).load() == nil)
    }
}

// MARK: - One per type that gained a field

/// The per-type half: each of these decodes the smallest JSON that 1.1 could have written for
/// that type and asserts the added key's default. They are the regression guard for the next
/// field somebody adds — a new stored property with no matching `decodeIfPresent` line fails
/// here, not on a user's next launch.
@Suite("Every field added after the 1.1 freeze decodes to its default when the key is missing")
struct AddedFieldDefaultTests {

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try FileCacheStore.makeDecoder().decode(type, from: Data(json.utf8))
    }

    /// `PRCacheEntry.queriedHeads`, added so a warm cache can tell "asked, no PR" from "never
    /// asked". Empty means "this entry proves nothing was queried", which is what a 1.1 entry is.
    @Test("prCacheEntryQueriedHeadsDefaultsToEmpty")
    func prCacheEntryDefault() throws {
        let entry = try Self.decode(
            PRCacheEntry.self,
            #"{"fetchedAt":"2026-08-24T01:46:40Z","prs":[],"authorPRs":[]}"#)

        #expect(entry.queriedHeads == [])
        // 2026-08-24T01:46:40Z, read through the store's `.iso8601` decoder.
        #expect(entry.fetchedAt == Date(timeIntervalSince1970: 1_787_536_000))
    }

    /// `Repo.remoteOwners`, the per-remote owner map. Empty is the honest default: a cache
    /// written before the lookup existed knows nothing about who owns `fork`.
    @Test("repoRemoteOwnersDefaultsToEmpty")
    func repoDefault() throws {
        let repo = try Self.decode(
            Repo.self,
            #"""
            {"id":{"commonDir":"/Users/tester/demo/.git"},"name":"demo","path":"/Users/tester/demo",
             "worktrees":[],"branches":[],"openPRsNotOnThisMac":[],
             "prAvailability":{"available":{}},"prLoadState":"notLoaded","errors":[],"isStale":false}
            """#)

        #expect(repo.remoteOwners == [:])
        #expect(repo.name == "demo")
    }

    /// The three `PushInfo` fields from codex round 2 MAJOR 5 and MAJOR 7. `remoteRefExists` is
    /// the one that mattered: a `Bool` with a default is still a required key to a synthesized
    /// decoder, so every branch of every cached repo threw on it.
    @Test("pushInfoAddedFieldsDefault")
    func pushInfoDefaults() throws {
        let push = try Self.decode(
            PushInfo.self,
            #"""
            {"originMovedSince":false,"source":"tipCommitDate","hasUpstream":true,
             "upstreamGone":false}
            """#)

        #expect(push.remoteTipCommitDate == nil)
        #expect(push.remoteName == nil)
        #expect(push.remoteRefExists == false)
        #expect(push.hasUpstream)
        #expect(push.hasConfiguredUpstream)
    }

    /// `RefreshPolicy.scanDeadline`, added by packet 3.3. The default is the shipped 20 s, not
    /// zero — a policy read back with a zero deadline would cut every scan short instantly.
    @Test("refreshPolicyScanDeadlineDefaultsToTwentySeconds")
    func refreshPolicyDefault() throws {
        let policy = try Self.decode(
            RefreshPolicy.self,
            #"""
            {"debounce":30,"overallDeadline":45,"maxConcurrentRepos":4,"prCacheTTL":600,
             "eagerPRRepoCount":5,"perHeadFallbackCap":20,"gitTimeout":10,"ghAuthTimeout":10,
             "ghListTimeout":25}
            """#)

        #expect(policy.scanDeadline == 20)
        #expect(policy.scanDeadline == RefreshPolicy.default.scanDeadline)
        #expect(policy.overallDeadline == 45)
    }

    /// `ScanResult.truncatedByDeadline`. False is the safe default: a 1.1 scan ran to completion
    /// by construction, and reading it as truncated would throw away a usable repo list.
    @Test("scanResultTruncatedByDeadlineDefaultsToFalse")
    func scanResultDefault() throws {
        let result = try Self.decode(
            ScanResult.self,
            #"""
            {"policy":{"homeRoot":"/Users/tester","extraRoots":[],"maxDepth":6,
             "skipHiddenDirectories":true,"skipDirectoryNames":["Library"],"descendIntoRepos":false},
             "scannedAt":"2026-08-24T01:46:40Z","repos":[],"candidatesExamined":7,
             "unreadableDirectories":[],"depthCutDirectories":0,"skippedHiddenDirectories":0,
             "skippedWorktreeCheckouts":[],"skippedSubmodules":[]}
            """#)

        #expect(result.truncatedByDeadline == false)
        #expect(result.candidatesExamined == 7)
    }

    /// The view models are recorded to disk as state fixtures and replayed by the suite, so the
    /// same rule holds for them: a fixture recorded before `path` and `host` existed still reads.
    @Test("repoSectionVMAddedFieldsDefaultToNil")
    func repoSectionDefaults() throws {
        let section = try Self.decode(
            RepoSectionVM.self,
            #"""
            {"id":{"commonDir":"/Users/tester/demo/.git"},"title":"demo","isCollapsed":false,
             "active":[],"openElsewhere":[],"merged":[],"closedUnmerged":[]}
            """#)

        #expect(section.path == nil)
        #expect(section.host == nil)
        #expect(section.title == "demo")
    }

    @Test("branchRowVMPRURLDefaultsToNil")
    func branchRowDefault() throws {
        let row = try Self.decode(
            BranchRowVM.self,
            #"""
            {"title":"main","pushLabel":"Pushed from this Mac 2 days ago",
             "pushTooltip":"Last push observed in this clone's reflog",
             "primaryAction":{"label":"Open PR","kind":"openURL",
             "payload":"https://github.com/tester/demo/pull/12"},
             "accessibilityLabel":"main"}
            """#)

        #expect(row.prURL == nil)
        #expect(row.title == "main")
    }

    /// codex round 3, MAJOR 4. `Repo.remoteOwners` was `[String: String]`; every cache on disk
    /// holds bare logins. A `RemoteIdentity` decodes one as an owner with no host, and the host it
    /// could only ever have meant is origin's — reading it as "unknown host" instead would strip
    /// the PR match off every cached fork-tracking row until the next refresh.
    @Test("remoteOwnersFromAnOlderCacheDecodeWithOriginsHost")
    func remoteOwnersFromAnOlderCacheDecodeWithOriginsHost() throws {
        let repo = try Self.decode(
            Repo.self,
            #"""
            {"id":{"commonDir":"/Users/tester/demo/.git"},"name":"demo","path":"/Users/tester/demo",
             "githubSlug":{"host":"github.nytimes.com","owner":"newsroom","name":"demo"},
             "remoteOwners":{"origin":"newsroom","fork":"contributor"},
             "worktrees":[],"branches":[],"openPRsNotOnThisMac":[],
             "prAvailability":{"available":{}},"prLoadState":"loaded","errors":[],"isStale":false}
            """#)

        #expect(repo.remoteOwners["origin"] == RemoteIdentity(host: "github.nytimes.com", owner: "newsroom"))
        #expect(repo.remoteOwners["fork"] == RemoteIdentity(host: "github.nytimes.com", owner: "contributor"))
        // And the folder check a pre-round-3 cache never recorded reads as "it was a folder",
        // which is what the refresh that wrote the cache had established by walking to it.
        #expect(repo.pathIsDirectory)

        // A value written by this build keeps the host it was written with.
        let current = try Self.decode(
            Repo.self,
            #"""
            {"id":{"commonDir":"/Users/tester/demo/.git"},"name":"demo","path":"/Users/tester/demo",
             "githubSlug":{"host":"github.com","owner":"tester","name":"demo"},
             "remoteOwners":{"fork":{"host":"gitlab.com","owner":"contributor"}},
             "pathIsDirectory":false,
             "worktrees":[],"branches":[],"openPRsNotOnThisMac":[],
             "prAvailability":{"available":{}},"prLoadState":"loaded","errors":[],"isStale":false}
            """#)
        #expect(current.remoteOwners["fork"] == RemoteIdentity(host: "gitlab.com", owner: "contributor"))
        #expect(!current.pathIsDirectory)
    }

    /// The two fields packet F13 added to `PushInfo`, read the way every post-freeze field is.
    @Test("pushInfoRemoteRefsKnownDefaultsToTrue")
    func pushInfoRemoteRefsKnownDefaultsToTrue() throws {
        let push = try Self.decode(
            PushInfo.self,
            #"""
            {"originMovedSince":false,"source":"none","hasUpstream":false,"upstreamGone":false}
            """#)

        #expect(push.remoteRefsKnown, "a cache written before the field read as an unread remote")
        #expect(push.source == .none)
    }

    /// codex round 3, BLOCKER 1 made `BranchRowVM.primaryAction` optional; a recorded row that
    /// carries one still decodes it.
    @Test("branchRowVMPrimaryActionIsOptionalAndStillDecodes")
    func branchRowPrimaryActionOptional() throws {
        let withAction = try Self.decode(
            BranchRowVM.self,
            #"""
            {"title":"main","pushLabel":"Pushed from this Mac 2 days ago","pushTooltip":"t",
             "primaryAction":{"label":"Open in Cursor","kind":"openURL","payload":"/Users/tester/demo"},
             "accessibilityLabel":"main"}
            """#)
        #expect(withAction.primaryAction?.payload == "/Users/tester/demo")

        let without = try Self.decode(
            BranchRowVM.self,
            #"""
            {"title":"main","pushLabel":"","pushTooltip":"","accessibilityLabel":"main"}
            """#)
        #expect(without.primaryAction == nil)
    }

    @Test("emptyStateVMNoticeDefaultsToNil")
    func emptyStateDefault() throws {
        let empty = try Self.decode(
            EmptyStateVM.self,
            #"""
            {"title":"No repos found","message":"message",
             "action":{"label":"Add folder…","kind":"addFolder"}}
            """#)

        #expect(empty.notice == nil)
        #expect(empty.title == "No repos found")
    }
}
