import Foundation
import Testing

@testable import BranchBarCore

/// Packet 1.1 ships contracts, and a contract that does not round-trip or a double that does not
/// record is a bug every later packet inherits. These exercise the frozen types and the three
/// test doubles once, here, so 2.x can trust them.

@Suite("Frozen types round-trip through the cache")
struct FrozenTypeTests {

    /// The whole point of "all `Hashable, Codable, Sendable`": `CacheFile` holds a `Snapshot`,
    /// and `RefreshCoordinator` persists it every refresh. `prCache` is keyed by `RepoID`, which
    /// is not a `String`, so `JSONEncoder` writes it as an alternating key/value array — this
    /// asserts that shape survives a decode rather than leaving packet 2.5 to discover it.
    @Test("A fully populated CacheFile encodes and decodes unchanged")
    func cacheFileRoundTrips() throws {
        let id = RepoID(commonDir: "/Users/tester/demo/.git")
        let slug = try #require(GitHubSlug(remoteURL: "git@github.nytimes.com:newsroom/demo.git"))
        let now = Date(timeIntervalSince1970: 1_788_310_842)

        let pr = PRInfo(
            number: 42,
            url: "https://github.nytimes.com/newsroom/demo/pull/42",
            state: "OPEN",
            isDraft: false,
            reviewDecision: "",
            updatedAt: now,
            baseRefName: "main",
            headRefName: "feature/x",
            headRefOid: "1111111111111111111111111111111111111111",
            headRepositoryOwnerLogin: "contributor"
        )

        let branch = Branch(
            name: "feature/x",
            tipSHA: "1111111111111111111111111111111111111111",
            committerDate: now,
            upstream: Upstream(ref: "origin/feature/x", remote: "origin", ahead: 2),
            worktreePath: "/Users/tester/demo/.claude/worktrees/x",
            isCheckedOutInPrimary: false,
            pr: pr,
            prStatus: .open,
            push: PushInfo(
                observedPushAt: now,
                observedPushOID: "1111111111111111111111111111111111111111",
                originMovedSince: true,
                source: .reflogObserved,
                hasUpstream: true,
                aheadOfLastKnownRemote: 2,
                remoteRefObservedAt: now
            ),
            group: .active
        )

        let repo = Repo(
            id: id,
            name: "demo",
            path: "/Users/tester/demo",
            remoteURL: "git@github.nytimes.com:newsroom/demo.git",
            githubSlug: slug,
            worktrees: [Worktree(path: "/Users/tester/demo", headSHA: "1111", branch: "refs/heads/main", isPrimary: true)],
            branches: [branch],
            openPRsNotOnThisMac: [pr],
            prAvailability: .unavailable(.ghNotAuthenticated(host: "github.nytimes.com"), detail: "HTTP 401: Bad credentials"),
            prFetchedAt: now,
            prLoadState: .stale,
            lastRefreshed: now,
            errors: [RepoError(stage: .reflog, message: "unreadable")],
            isStale: true,
            lastActivity: now
        )

        let cache = CacheFile(
            scan: ScanResult(
                policy: ScanPolicy(homeRoot: "/Users/tester", extraRoots: ["/Volumes/Work"]),
                scannedAt: now,
                repos: [DiscoveredRepo(path: "/Users/tester/demo", id: id)],
                candidatesExamined: 812,
                unreadableDirectories: ["/Users/tester/Documents"],
                depthCutDirectories: 37,
                skippedHiddenDirectories: 194,
                skippedWorktreeCheckouts: ["/Users/tester/demo/.claude/worktrees/x"],
                skippedSubmodules: ["/Users/tester/demo/vendor/lib"]
            ),
            manuallyAddedRepos: ["/Volumes/Work"],
            hiddenRepoIDs: [id],
            collapsedRepoIDs: [id],
            prCache: [id: PRCacheEntry(fetchedAt: now, prs: [pr], authorPRs: [pr])],
            lastSnapshot: Snapshot(
                repos: [repo],
                refreshedAt: now,
                tools: ToolStatus(
                    gitPath: "/usr/bin/git",
                    gitVersion: "git version 2.39.5 (Apple Git-154)",
                    ghPath: "/opt/homebrew/bin/gh",
                    ghAuthByHost: ["github.nytimes.com": false]
                )
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(CacheFile.self, from: encoder.encode(cache))
        #expect(decoded == cache)
        #expect(decoded.prCache[id]?.prs.first?.headRepositoryOwnerLogin == "contributor")
        #expect(decoded.lastSnapshot?.repos.first?.prAvailability == cache.lastSnapshot?.repos.first?.prAvailability)
    }

    /// PLAN.md §5 fixes ten PR states, and §5a item 4 owes each one a color in light and dark.
    @Test("PRStatus has exactly the ten frozen cases")
    func prStatusCaseCount() {
        #expect(PRStatus.allCases.count == 10)
        #expect(PRStatus.allCases.contains(.notChecked))
        #expect(PRStatus.allCases.contains(.notLoaded))
        #expect(PRStatus.allCases.contains(.none))
    }

    /// PLAN.md §3 and §5 fix these numbers; a silent edit changes the product.
    @Test("RefreshPolicy defaults match the frozen numbers")
    func refreshPolicyDefaults() {
        let p = RefreshPolicy.default
        #expect(p.debounce == 30)
        #expect(p.overallDeadline == 45)
        #expect(p.maxConcurrentRepos == 4)
        #expect(p.prCacheTTL == 600)
        #expect(p.eagerPRRepoCount == 5)
        #expect(p.perHeadFallbackCap == 20)
        #expect(p.gitTimeout == 10)
        #expect(p.ghListTimeout == 25)
    }

    /// PLAN.md §3: depth 6 on the home root only, hidden directories skipped, no descent into a
    /// repo that was already found; extra roots carry no depth limit.
    @Test("ScanPolicy defaults match the frozen discovery rules")
    func scanPolicyDefaults() {
        let p = ScanPolicy(homeRoot: "/Users/tester")
        #expect(p.maxDepth == 6)
        #expect(p.skipHiddenDirectories)
        #expect(p.descendIntoRepos == false)
        #expect(p.extraRoots.isEmpty)
        #expect(p.skipDirectoryNames == ScanPolicy.defaultSkipDirectoryNames)
        #expect(p.skipDirectoryNames.contains("Library"))
        #expect(p.skipDirectoryNames.contains("node_modules"))
    }

    /// The environments frozen in PLAN.md §5. The gh set exists because a GUI-launched `gh` must
    /// never prompt, page, colorize, or check for updates.
    @Test("The frozen git and gh environments are exactly what PLAN.md §5 lists")
    func frozenEnvironments() {
        // Two entries until codex MAJOR 13 (the git half): `GIT_NO_LAZY_FETCH=1` keeps a partial
        // clone from reaching the network behind a read contracted never to fetch, and keeps the
        // helper that read would spawn from outliving cancellation.
        #expect(GitClient.frozenEnvironment
            == ["LC_ALL": "C", "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_LAZY_FETCH": "1"])
        #expect(GHClient.frozenEnvironment == [
            "GH_PROMPT_DISABLED": "1",
            "GH_NO_UPDATE_NOTIFIER": "1",
            "GH_PAGER": "cat",
            "NO_COLOR": "1",
            "CLICOLOR": "0",
        ])
        #expect(GHClient.jsonFields == "number,url,state,isDraft,reviewDecision,mergedAt,updatedAt,baseRefName,headRefName,headRefOid,headRepositoryOwner,mergeCommit")
    }

    /// A branch name that starts with `-` must reach git as an operand. `Command` holds an
    /// argument array, never a shell string, which is what makes that possible.
    @Test("Command keeps arguments as an array, so a leading dash is data")
    func commandArgumentsAreAnArray() {
        let command = Command(
            executable: "/usr/bin/git",
            arguments: ["-C", "/Users/tester/demo", "reflog", "show", "--date=unix", "refs/remotes/origin/-weird"],
            timeout: 10
        )
        #expect(command.arguments.last == "refs/remotes/origin/-weird")
        #expect(command.displayString.hasPrefix("git -C "))
    }
}

@Suite("Test doubles behave the way later packets will rely on")
struct TestDoubleTests {

    @Test("RecordedCommandRunner matches on basename, arguments, and working directory")
    func recordedRunnerMatching() async throws {
        let runner = RecordedCommandRunner()
        runner.stub(.init(
            executableName: "git",
            arguments: ["-C", "/repo", "worktree", "list", "--porcelain", "-z"],
            workingDirectory: nil,
            result: .stdout("worktree /repo\n")
        ))

        // Homebrew git and /usr/bin/git differ per machine; the basename is what a stub matches.
        let output = try await runner.run(Command(
            executable: "/opt/homebrew/bin/git",
            arguments: ["-C", "/repo", "worktree", "list", "--porcelain", "-z"]
        ))
        #expect(output.standardOutputText == "worktree /repo\n")
        #expect(output.exitCode == 0)
        #expect(runner.callCount == 1)
        #expect(runner.calls(matchingExecutable: "git").count == 1)
    }

    @Test("RecordedCommandRunner surfaces a configured failure")
    func recordedRunnerFailure() async {
        let runner = RecordedCommandRunner()
        runner.stub(.init(
            executableName: "gh",
            arguments: ["auth", "status", "--hostname", "github.com"],
            result: .failure(.nonZeroExit(exitCode: 1, standardError: "HTTP 401: Bad credentials"))
        ))

        await #expect(throws: CommandError.self) {
            try await runner.run(Command(executable: "/opt/homebrew/bin/gh",
                                         arguments: ["auth", "status", "--hostname", "github.com"]))
        }
    }

    /// The probe that backs `peakConcurrencyNeverExceedsCap` in packet 3.2.
    @Test("RecordedCommandRunner tracks peak in-flight calls when asked")
    func recordedRunnerConcurrencyProbe() async throws {
        let runner = RecordedCommandRunner()
        runner.tracksConcurrency = true
        runner.stub(.init(executableName: "git", arguments: ["slow"], result: .stdout("ok"), delay: 0.05))

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    _ = try? await runner.run(Command(executable: "/usr/bin/git", arguments: ["slow"]))
                }
            }
        }
        #expect(runner.callCount == 3)
        #expect(runner.peakInFlight > 1, "three overlapping calls must be observed as overlapping")
        #expect(runner.peakInFlight <= 3)
    }

    @Test("InMemoryFileSystem lists a tree and throws on an unreadable directory")
    func inMemoryFileSystemTree() throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Users/tester/code/demo")
        fs.addDirectory("/Users/tester/code/notes")
        fs.addDirectory("/Users/tester/.cache/tool")
        fs.addFile("/Users/tester/code/demo/README.md", contents: "hi")
        fs.markUnreadable("/Users/tester/Documents")
        fs.addDirectory("/Users/tester/Documents")

        let home = try fs.contentsOfDirectory(atPath: "/Users/tester").map(\.name)
        #expect(home.contains("code"))
        #expect(home.contains(".cache"), "hidden directories are listed; skipping them is the scanner's decision, not the seam's")

        let code = try fs.contentsOfDirectory(atPath: "/Users/tester/code")
        #expect(code.map(\.name) == ["demo", "notes"])
        #expect(code.allSatisfy { $0.isDirectory })

        // `.git` present as a real directory is the repo marker.
        #expect(fs.fileExists(atPath: "/Users/tester/code/demo/.git"))
        #expect(fs.homeDirectory() == "/Users/tester")
        #expect(fs.pathEnvironment() == "/usr/bin:/bin:/usr/sbin:/sbin", "a GUI app's PATH has no Homebrew")

        #expect(throws: InMemoryFileSystem.PermissionDenied.self) {
            _ = try fs.contentsOfDirectory(atPath: "/Users/tester/Documents")
        }
    }

    @Test("InMemoryFileSystem reads a .git file the way a worktree checkout writes it")
    func inMemoryFileSystemGitFile() throws {
        let fs = InMemoryFileSystem()
        fs.addGitFile(at: "/Users/tester/demo/.claude/worktrees/x", gitdir: "/Users/tester/demo/.git/worktrees/x")
        let contents = String(decoding: try fs.readFile(atPath: "/Users/tester/demo/.claude/worktrees/x/.git"), as: UTF8.self)
        #expect(contents == "gitdir: /Users/tester/demo/.git/worktrees/x\n")
    }

    @Test("InMemoryCacheStore stores, counts, and can be made to fail")
    func inMemoryCacheStore() throws {
        let store = InMemoryCacheStore()
        #expect(try store.load() == nil)

        try store.save(CacheFile(manuallyAddedRepos: ["/Volumes/Work"]))
        #expect(store.saveCount == 1)
        #expect(try store.load()?.manuallyAddedRepos == ["/Volumes/Work"])

        store.saveError = InMemoryFileSystem.PermissionDenied(path: "/cache.json")
        #expect(throws: InMemoryFileSystem.PermissionDenied.self) {
            try store.save(CacheFile())
        }
        #expect(store.current?.manuallyAddedRepos == ["/Volumes/Work"], "a failed save leaves the previous cache intact")
    }
}

@Suite("The recorded and synthetic fixtures hold what the inventory says")
struct FixtureInventoryTests {

    /// Recorded on 2026-09-01 from `hannah-personal-agent`: 3 local branches, 1 worktree,
    /// 19 remote refs, 17 PRs. Re-record with `make record-fixtures`.
    @Test("Recorded git fixtures carry the row counts docs/TEST-PLAN.md claims")
    func recordedGitFixtures() {
        let heads = Fixture.text("recorded-hannah-personal-agent-for-each-ref-heads.txt")
        #expect(heads.hasSuffix("\n"), "fixtures are recorded byte for byte, trailing newline included")
        let headRows = heads.split(separator: "\n")
        #expect(headRows.count == 3)
        #expect(headRows.allSatisfy { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).count == 7 })
        #expect(!heads.contains("%1f"), "the format atom must emit U+001F, not its own text")

        let remotes = Fixture.text("recorded-hannah-personal-agent-for-each-ref-remotes.txt")
        #expect(remotes.split(separator: "\n").count == 19)
        #expect(remotes.contains("refs/remotes/origin/HEAD"), "git really prints the symbolic ref; the parser skips it")

        // NUL-delimited since codex MAJOR 12 re-froze the invocation with `-z`: every field ends
        // with `\0` and a record with one more, so the file carries no newline at all.
        let worktrees = Fixture.data("recorded-hannah-personal-agent-worktree-list.txt")
        #expect(worktrees.suffix(2) == Data([0, 0]), "the last record is closed by an empty field")
        #expect(!worktrees.contains(UInt8(ascii: "\n")), "-z prints no newlines")
        let worktreeFields = worktrees.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        #expect(worktreeFields.first?.hasPrefix("worktree /") == true)
        #expect(worktreeFields.contains("branch refs/heads/main"))

        let revParse = Fixture.text("recorded-branchbar-rev-parse.txt")
        #expect(revParse.split(separator: "\n").count == 2)

        #expect(Fixture.text("recorded-branchbar-config-remote-origin-url.txt")
            .trimmingCharacters(in: .whitespacesAndNewlines) == "https://github.com/hannahstulberg/branchbar.git")
    }

    /// The 0-byte reflog file that made "reflog files can exist and be empty" a rule.
    @Test("The recorded reflog fixtures include a real 0-byte file and a real push file")
    func recordedReflogFixtures() {
        let empty = Fixture.data("recorded-reflog-hannah-personal-agent-origin-updates-3-29-26.txt")
        #expect(empty.isEmpty)

        let pushes = Fixture.text("recorded-reflog-hannah-personal-agent-origin-main.txt")
        #expect(pushes.contains("\tupdate by push"))
        #expect(pushes.split(separator: "\n").count >= 20)

        let show = Fixture.text("recorded-hannah-personal-agent-reflog-show-origin-main.txt")
        #expect(show.contains("origin/main@{"))
        #expect(show.split(separator: "\n").allSatisfy {
            $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).count == 3
        })
    }

    /// `headRepositoryOwner` is an object and `reviewDecision` is `""` — both verified against
    /// gh 2.89 and both easy to get wrong from memory.
    @Test("The recorded gh fixture has the JSON shape CLAUDE.md warns about")
    func recordedGHFixture() throws {
        let data = Fixture.data("recorded-gh-pr-list-hannah-personal-agent.json")
        let rows = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(rows.count == 17)

        let first = try #require(rows.first)
        #expect(first["headRepositoryOwner"] is [String: Any], "headRepositoryOwner is an object; use .login")
        #expect(first["reviewDecision"] as? String == "", "gh returns an empty string, not null")
        #expect(rows.contains { $0["mergeCommit"] is NSNull }, "a closed-unmerged PR has a null mergeCommit")

        // Recorded byte for byte, trailing newline included, so a parser is tested against what
        // gh actually writes rather than a stripped copy.
        let authored = Fixture.text("recorded-gh-pr-list-author-me-hannah-personal-agent.json")
        #expect(authored == "[]\n",
                "an author with no open PRs is an honest empty answer, which Gate 1.1 allows")
    }

    @Test("Synthetic fixtures cover the cases this machine's repos cannot produce")
    func syntheticFixtures() throws {
        // The synthetic worktree fixtures moved to the `-z` form with codex MAJOR 12, so the
        // record shape is asserted on fields between NULs rather than on lines.
        let worktreeFields = Fixture.data("synthetic-worktree-list-multi.txt")
            .split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        #expect(worktreeFields.contains("detached"))
        #expect(worktreeFields.contains("bare"))
        #expect(worktreeFields.contains { $0.hasPrefix("locked waiting on") })
        #expect(worktreeFields.contains { $0.hasPrefix("prunable gitdir file points") })
        #expect(worktreeFields.contains { $0.contains("repos with spaces") })

        let heads = Fixture.text("synthetic-for-each-ref-heads-mixed.txt")
        let rows = heads.split(separator: "\n")
        #expect(rows.count == 8)
        #expect(rows.allSatisfy { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).count == 7 })
        #expect(heads.contains("ahead 2"))
        #expect(heads.contains("ahead 1, behind 4"))
        #expect(heads.contains("gone"))
        #expect(heads.contains("refs/tags/main"))

        // The deletion boundary: an all-zero **new** OID, which is field 2.
        let zero = String(repeating: "0", count: 40)
        let deletion = Fixture.text("synthetic-reflog-deletion-line.txt")
        let newestDeletionLine = try #require(deletion.split(separator: "\n").last)
        #expect(newestDeletionLine.split(separator: " ")[1] == Substring(zero))

        let recreate = Fixture.text("synthetic-reflog-delete-then-recreate.txt")
        #expect(recreate.split(separator: "\n").count == 3)
        #expect(recreate.contains(" \(zero) "), "the middle line is the deletion boundary")

        #expect(Fixture.data("synthetic-reflog-empty.txt").isEmpty)
        #expect(!Fixture.text("synthetic-reflog-fetch-only.txt").contains("update by push"))

        let mixed = try #require(try JSONSerialization.jsonObject(
            with: Fixture.data("synthetic-gh-pr-list-mixed.json")) as? [[String: Any]])
        #expect(mixed.count == 10)
        #expect(Set(mixed.compactMap { $0["state"] as? String }) == ["OPEN", "MERGED", "CLOSED"])
        #expect(Set(mixed.compactMap { $0["reviewDecision"] as? String })
            .isSuperset(of: ["", "REVIEW_REQUIRED", "CHANGES_REQUESTED", "APPROVED"]))
        #expect(mixed.filter { $0["headRefName"] as? String == "shared-head" }.count == 2,
                "two PRs on one head, so the owner-then-OPEN-then-latest tie-break has a fixture")
        #expect(mixed.contains { ($0["headRepositoryOwner"] as? [String: Any])?["login"] as? String == "contributor" },
                "a fork PR whose head owner differs from the repo owner")
        #expect(mixed.contains { $0["isDraft"] as? Bool == true })

        #expect(Fixture.text("synthetic-gh-pr-list-empty.json") == "[]\n")
        #expect(Fixture.text("synthetic-gh-auth-status-401.txt").contains("HTTP 401: Bad credentials"))
        #expect(Fixture.text("synthetic-gh-rate-limit-403.txt").contains("HTTP 403: API rate limit exceeded"))
        #expect(Fixture.text("synthetic-gh-not-found.txt").contains("No such file or directory"))

        let ghe = try #require(GitHubSlug(remoteURL: Fixture.text("synthetic-config-remote-origin-url-ghe.txt")))
        #expect(ghe.host == "github.nytimes.com")
    }

    /// PLAN.md §3: "hand-extended cases are separate files marked `synthetic-`". Every synthetic
    /// fixture carries a sibling note whose first line is the `# synthetic:` header, because none
    /// of these formats has a comment syntax that a parser could safely skip.
    @Test("Every synthetic fixture has a sibling note with the synthetic header")
    func everySyntheticFixtureIsDocumented() throws {
        let names = Fixture.allNames()
        let synthetics = names.filter { $0.hasPrefix("synthetic-") && !$0.hasSuffix(".md") }
        #expect(synthetics.count >= 15)

        for fixture in synthetics {
            let note = (fixture as NSString).deletingPathExtension + ".md"
            #expect(names.contains(note), "\(fixture) has no sibling note \(note)")
            guard names.contains(note) else { continue }
            let firstLine = try String(contentsOf: Fixture.url(note), encoding: .utf8)
                .components(separatedBy: .newlines).first ?? ""
            #expect(firstLine.hasPrefix("# synthetic: "), "\(note) must open with the `# synthetic:` header, got \(firstLine)")
        }

        // Recorded fixtures are produced by the script and are never hand-edited.
        #expect(names.filter { $0.hasPrefix("recorded-") }.count >= 12)
    }
}
