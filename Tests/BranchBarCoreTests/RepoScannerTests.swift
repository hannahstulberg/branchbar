import Foundation
import Testing

@testable import BranchBarCore

// Packet 2.4 — `RepoScanner`. PLAN.md §3 (repo discovery), §5 (`ScanPolicy`, `ScanResult`),
// §7 (named invariants). Every tree here is built in `InMemoryFileSystem`, so no test touches
// the real home folder, and no test can trip a TCC prompt.
//
// Five things the contract left implicit; these tests decide them, and the decision is stated
// beside the assertion that pins it:
//
// 1. **Depth numbering.** `policy.homeRoot` is depth 0, its children are depth 1. A directory
//    at depth <= `maxDepth` is opened, so a repo root at depth 6 is found with the default
//    policy; a directory at depth `maxDepth + 1` is never opened and counts once in
//    `depthCutDirectories`. That is the reading that makes PLAN.md §7's
//    `repoAtDepthSixIsFoundAndDepthSevenIsNot` true.
// 2. **`.git` is never a hidden skip.** `skippedHiddenDirectories` counts directories the walk
//    declined to enter because their name starts with `.`. The `.git` marker is read, not
//    entered, so it never lands in that count.
// 3. **`skipDirectoryNames` entries containing `/` match a path suffix.** The frozen list holds
//    one such entry, the literal `"go/pkg"`. A single-component entry (`node_modules`) matches a
//    directory *name* at any depth; a multi-component entry matches only a directory whose path
//    ends in that entry, so `~/go/pkg` is skipped while `~/src/pkg` and `~/go/src` are walked.
//    Pinned by `goPkgSkipEntryMatchesThePathSuffixNotABareNamedDirectory`.
// 4. **A worktree checkout's classification carries the common directory, not the stub.** The
//    frozen enum labels the worktree payload `commonDirectory` and the other two `gitDirectory`;
//    for `…/.git/worktrees/<name>` the common directory is everything before `/worktrees/`.
//    Pinned by `worktreeClassificationCarriesTheCommonDirectoryNotTheWorktreeStub`.
// 5. **Dedupe is asserted through `ScanResult`, not through the process seam.** The frozen stub
//    takes a `FileSystem` and nothing else, so these tests cannot inject a `RecordedCommandRunner`
//    and do not assert that `git rev-parse --path-format=absolute --git-common-dir
//    --show-toplevel` ran. `twoCandidatesSharingCommonDirDedupeToOne` states the observable rule
//    instead — one repo survives, and it is the one whose `.git` is a directory — so an
//    implementation that shells out to `rev-parse` and one that derives the common dir from the
//    filesystem both satisfy it. The call sites below are written `try await` so that adding a
//    `CommandRunner` (as a **defaulted** init parameter) and making `scan` `async` needs no test
//    edit.

/// The scanner under test. A helper, not a literal, so a defaulted init parameter added later
/// does not ripple through twenty call sites.
private func makeScanner(_ fileSystem: InMemoryFileSystem) -> RepoScanner {
    RepoScanner(fileSystem: fileSystem)
}

private func paths(_ result: ScanResult) -> [String] {
    result.repos.map(\.path)
}

@Suite("RepoScanner walks the home root to depth 6 and added roots without a limit")
struct RepoScannerScanTests {

    // MARK: Hidden directories

    /// PLAN.md §3: "skipping every hidden directory (name starts with `.`) except the `.git`
    /// marker itself". Hannah's own machine has 7 of its 30 `.git` entries under `.cache`,
    /// `.claude`, and `.codex` (PLAN.md §2), and none of them is a repo she works in.
    @Test("hiddenDirectoriesUnderHomeAreSkipped")
    func hiddenDirectoriesUnderHomeAreSkipped() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Users/tester/.claude/projects/tool")
        fs.addRepository(at: "/Users/tester/.cache/vendored/dep")
        fs.addRepository(at: "/Users/tester/code/app")

        let result = try await makeScanner(fs).scan(policy: ScanPolicy(homeRoot: "/Users/tester"))

        #expect(paths(result) == ["/Users/tester/code/app"])
        // `.claude` and `.cache`; the `.git` inside `code/app` is a marker, never a hidden skip.
        #expect(result.skippedHiddenDirectories == 2)
    }

    // MARK: Depth

    @Test("repoAtDepthSixIsFoundAndDepthSevenIsNot")
    func repoAtDepthSixIsFoundAndDepthSevenIsNot() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Users/tester/a1/a2/a3/a4/a5/a6")
        fs.addRepository(at: "/Users/tester/b1/b2/b3/b4/b5/b6/b7")

        let result = try await makeScanner(fs).scan(policy: ScanPolicy(homeRoot: "/Users/tester"))

        #expect(paths(result) == ["/Users/tester/a1/a2/a3/a4/a5/a6"])
        // The repo's id is its `--git-common-dir`, absolute.
        #expect(result.repos.first?.id == RepoID(commonDir: "/Users/tester/a1/a2/a3/a4/a5/a6/.git"))
        #expect(result.depthCutDirectories >= 1, "b7 sits one level past maxDepth and must be reported as a cut")
    }

    /// The summary the user reads ("hidden folders, Library, depth > 6, folders inside repos")
    /// is built from these three counters, so each one is pinned exactly, in a tree small enough
    /// that "directories opened" is unambiguous: the root, `work`, and `notes`.
    @Test("scanSummaryReportsDepthCutAndHiddenSkips")
    func scanSummaryReportsDepthCutAndHiddenSkips() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Users/tester/work")
        fs.addDirectory("/Users/tester/notes/inner")
        fs.addDirectory("/Users/tester/.cache/tool")

        let policy = ScanPolicy(homeRoot: "/Users/tester", maxDepth: 1)
        let before = Date()
        let result = try await makeScanner(fs).scan(policy: policy)

        #expect(paths(result) == ["/Users/tester/work"])
        #expect(result.candidatesExamined == 3, "the root, work, and notes were opened; .cache and inner were not")
        #expect(result.depthCutDirectories == 1, "inner sits at depth 2 with maxDepth 1")
        #expect(result.skippedHiddenDirectories == 1, ".cache only; the .git marker inside work is not a hidden skip")
        #expect(result.unreadableDirectories.isEmpty)
        #expect(result.skippedWorktreeCheckouts.isEmpty)
        #expect(result.skippedSubmodules.isEmpty)
        #expect(result.policy == policy, "the summary reads the policy back to the user")
        #expect(result.scannedAt >= before, "scannedAt is stamped when the scan ran")
    }

    // MARK: Extra roots

    /// PLAN.md §3: "Add folder…" roots are walked "recursively with no depth limit (same skip
    /// list)", which is how a repo on Drive, Dropbox, or nine levels down is reachable at all.
    @Test("extraRootScansRecursivelyWithoutDepthLimit")
    func extraRootScansRecursivelyWithoutDepthLimit() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addDirectory("/Volumes/Work")
        fs.addRepository(at: "/Volumes/Work/a/b/c/d/e/f/g/h/deep")
        fs.addRepository(at: "/Volumes/Work/node_modules/dep")

        let result = try await makeScanner(fs).scan(
            policy: ScanPolicy(homeRoot: "/Users/tester", extraRoots: ["/Volumes/Work"], maxDepth: 6)
        )

        #expect(paths(result) == ["/Volumes/Work/a/b/c/d/e/f/g/h/deep"], "nine levels down, and the skip list still applies")
        #expect(result.depthCutDirectories == 0, "maxDepth governs the home root only")
    }

    @Test("extraRootThatIsARepoYieldsItself")
    func extraRootThatIsARepoYieldsItself() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Volumes/Work/proj")
        fs.addRepository(at: "/Volumes/Work/proj/packages/inner")

        let result = try await makeScanner(fs).scan(
            policy: ScanPolicy(homeRoot: "/Users/tester", extraRoots: ["/Volumes/Work/proj"])
        )

        #expect(paths(result) == ["/Volumes/Work/proj"], "the added folder is itself the repo, and nothing under it is entered")
    }

    /// PLAN.md §2 measured this on Hannah's machine: the real repos live at
    /// `~/gt/deacon/dogs/alpha/…`, deeper than a depth-4 scan reaches. It is the whole reason
    /// the home depth is 6 and "Add folder…" has no limit at all.
    @Test("hannahsDeepLayoutNeedsDepthSixOrAnExtraRoot")
    func hannahsDeepLayoutNeedsDepthSixOrAnExtraRoot() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Users/tester/gt/deacon/dogs/alpha/repo")
        let deep = "/Users/tester/gt/deacon/dogs/alpha/repo"

        let shallow = try await makeScanner(fs).scan(
            policy: ScanPolicy(homeRoot: "/Users/tester", maxDepth: 4)
        )
        #expect(paths(shallow).isEmpty, "at depth 4 the home scan never opens the repo directory")
        #expect(shallow.depthCutDirectories >= 1, "and it says so rather than pretending the folder was empty")

        let added = try await makeScanner(fs).scan(
            policy: ScanPolicy(homeRoot: "/Users/tester", extraRoots: ["/Users/tester/gt/deacon"], maxDepth: 4)
        )
        #expect(paths(added) == [deep], "adding the folder finds it even though the home depth did not change")

        let deeper = try await makeScanner(fs).scan(
            policy: ScanPolicy(homeRoot: "/Users/tester", maxDepth: 6)
        )
        #expect(paths(deeper) == [deep], "and the shipped depth of 6 finds it without adding anything")
    }

    // MARK: Skip list

    @Test("skipListNamesAreSkippedAtAnyDepth")
    func skipListNamesAreSkippedAtAnyDepth() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Users/tester/node_modules/pkg-a")
        fs.addRepository(at: "/Users/tester/Library/Containers/tool")
        fs.addRepository(at: "/Users/tester/src/tools/node_modules/dep")
        fs.addRepository(at: "/Users/tester/src/tools/vendor/dep")
        fs.addRepository(at: "/Users/tester/src/app")

        let result = try await makeScanner(fs).scan(policy: ScanPolicy(homeRoot: "/Users/tester"))

        #expect(paths(result) == ["/Users/tester/src/app"])
        #expect(result.skippedHiddenDirectories == 0, "a skip-list name is not a hidden directory")
    }

    /// `"go/pkg"` is the one multi-component entry in the frozen list, and it is there because
    /// Go's module cache lives at `~/go/pkg/mod` — not because every directory named `pkg` is
    /// uninteresting. So the entry matches a path suffix, and `~/src/pkg` and `~/go/src` are
    /// still walked.
    @Test("goPkgSkipEntryMatchesThePathSuffixNotABareNamedDirectory")
    func goPkgSkipEntryMatchesThePathSuffixNotABareNamedDirectory() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Users/tester/go/pkg/mod/example.com/dep")
        fs.addRepository(at: "/Users/tester/go/src/app")
        fs.addRepository(at: "/Users/tester/src/pkg/tool")

        let result = try await makeScanner(fs).scan(policy: ScanPolicy(homeRoot: "/Users/tester"))

        #expect(paths(result) == ["/Users/tester/go/src/app", "/Users/tester/src/pkg/tool"])
    }

    // MARK: `.git` files

    /// A linked worktree writes `gitdir: <main>/.git/worktrees/<name>` into its `.git` file.
    /// PLAN.md §3: "worktree checkouts and submodules never listed as repos" — a worktree is a
    /// row *inside* its repo, and listing it again as a repo double-counts every branch.
    @Test("gitFilePointingIntoWorktreesIsExcludedAndReported")
    func gitFilePointingIntoWorktreesIsExcludedAndReported() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Users/tester/code/app")
        fs.addGitFile(at: "/Users/tester/wt/app-feature", gitdir: "/Users/tester/code/app/.git/worktrees/app-feature")

        let result = try await makeScanner(fs).scan(policy: ScanPolicy(homeRoot: "/Users/tester"))

        #expect(paths(result) == ["/Users/tester/code/app"])
        #expect(result.skippedWorktreeCheckouts == ["/Users/tester/wt/app-feature"], "excluded, and reported by path")
        #expect(result.skippedSubmodules.isEmpty)
    }

    @Test("gitFilePointingIntoModulesIsExcluded")
    func gitFilePointingIntoModulesIsExcluded() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Users/tester/code/app")
        fs.addGitFile(at: "/Users/tester/checkouts/lib", gitdir: "/Users/tester/code/app/.git/modules/lib")

        let result = try await makeScanner(fs).scan(policy: ScanPolicy(homeRoot: "/Users/tester"))

        #expect(paths(result) == ["/Users/tester/code/app"])
        #expect(result.skippedSubmodules == ["/Users/tester/checkouts/lib"])
        #expect(result.skippedWorktreeCheckouts.isEmpty)
    }

    // MARK: Descent, symlinks, unreadable directories

    /// `descendIntoRepos` is a constant `false` (PLAN.md §5): a repo inside a monorepo is
    /// reachable by adding it as a root, never by the home scan walking through its parent.
    @Test("doesNotDescendIntoDiscoveredRepo")
    func doesNotDescendIntoDiscoveredRepo() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Users/tester/mono")
        fs.addRepository(at: "/Users/tester/mono/packages/inner")

        let result = try await makeScanner(fs).scan(policy: ScanPolicy(homeRoot: "/Users/tester"))

        #expect(paths(result) == ["/Users/tester/mono"])
    }

    /// Following symlinks turns a home scan into an unbounded walk of anything the user ever
    /// linked, and can revisit the same repo under two paths. PLAN.md §3: "symlinks not
    /// followed"; the symlink target is reachable by adding it as a root.
    @Test("doesNotFollowSymlinks")
    func doesNotFollowSymlinks() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Users/tester/real/app")
        fs.addSymbolicLink("/Users/tester/link")
        fs.addRepository(at: "/Users/tester/link/app")

        let result = try await makeScanner(fs).scan(policy: ScanPolicy(homeRoot: "/Users/tester"))

        #expect(paths(result) == ["/Users/tester/real/app"])
        #expect(paths(result).allSatisfy { !$0.hasPrefix("/Users/tester/link") })
    }

    /// A TCC denial on Documents or Desktop is the normal case on a managed Mac, and PLAN.md §3
    /// puts it in the UI as a "Not scanned" row with a button that re-triggers access. Swallowing
    /// the error would make that row impossible and the scan silently incomplete.
    @Test("unreadableDirectoryIsReportedNotSilentlySkipped")
    func unreadableDirectoryIsReportedNotSilentlySkipped() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Users/tester/code/app")
        fs.addDirectory("/Users/tester/Documents")
        fs.markUnreadable("/Users/tester/Documents")

        let result = try await makeScanner(fs).scan(policy: ScanPolicy(homeRoot: "/Users/tester"))

        #expect(result.unreadableDirectories == ["/Users/tester/Documents"])
        #expect(paths(result) == ["/Users/tester/code/app"], "one denied folder does not abort the scan")
    }

    /// codex round 5, MINOR 7. The `.git` **file** of a linked worktree or a separate-git-directory
    /// checkout was read with `try?`, so a refusal, a FIFO where the marker belongs, or a TCC
    /// denial became an empty string — which classifies as "not a marker we can vouch for" and the
    /// folder was walked past in silence. A repo that cannot be inspected is reported, by the
    /// folder the user would go looking for, exactly as an unreadable directory is.
    @Test("unreadableGitMarkerIsReportedNotHidden")
    func unreadableGitMarkerIsReportedNotHidden() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Users/tester/code/app")
        fs.addGitFile(at: "/Users/tester/code/linked", gitdir: "/Users/tester/code/main/.git")
        fs.markUnreadable("/Users/tester/code/linked/.git")

        /// A recorder safe to hand a `@Sendable` callback.
        final class Announced: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [String] = []
            func append(_ path: String) { lock.lock(); storage.append(path); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return storage }
        }

        let announced = Announced()
        let scanner = RepoScanner(
            fileSystem: fs,
            onProgress: { event in
                if case .unreadable(let path) = event { announced.append(path) }
            })
        let result = try await scanner.scan(policy: ScanPolicy(homeRoot: "/Users/tester"))

        #expect(result.unreadableDirectories.contains("/Users/tester/code/linked"),
                "a repo whose marker could not be read vanished: \(result.unreadableDirectories)")
        #expect(announced.all.contains("/Users/tester/code/linked"),
                "and the walk said so while there was still a process to say it")
        #expect(paths(result) == ["/Users/tester/code/app"],
                "it is reported, not invented as a repo, and the rest of the walk carries on")

        // The complement: a marker that reads fine and simply is not one stays silent, so the
        // report means "could not inspect" rather than "is not a repo".
        let plain = InMemoryFileSystem(home: "/Users/tester")
        plain.addRepository(at: "/Users/tester/code/app")
        plain.addFile("/Users/tester/code/notes/.git", contents: "this is not a gitdir line\n")
        let quiet = try await makeScanner(plain).scan(policy: ScanPolicy(homeRoot: "/Users/tester"))
        #expect(quiet.unreadableDirectories.isEmpty, "\(quiet.unreadableDirectories)")
    }

    // MARK: Dedupe and order

    /// Two candidates can name the same `--git-common-dir`: a plain checkout beside a directory
    /// whose `.git` file points back into it. One repo must survive, and it must be the one whose
    /// `.git` is a real directory — even when the other sorts first, so the rule is "the `.git`
    /// directory wins", not "whichever the walk reached first".
    @Test("twoCandidatesSharingCommonDirDedupeToOne")
    func twoCandidatesSharingCommonDirDedupeToOne() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Users/tester/code/app")
        fs.addGitFile(at: "/Users/tester/code/aaa-mirror", gitdir: "/Users/tester/code/app/.git")

        let result = try await makeScanner(fs).scan(policy: ScanPolicy(homeRoot: "/Users/tester"))

        #expect(paths(result) == ["/Users/tester/code/app"])
        #expect(result.repos.first?.id == RepoID(commonDir: "/Users/tester/code/app/.git"))
    }

    /// Repo order in the menu is decided later by recent activity, but the scan's own output is
    /// sorted by path so a rescan of an unchanged machine produces an identical `ScanResult` and
    /// the cache does not churn.
    @Test("resultIsSortedByPath")
    func resultIsSortedByPath() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Users/tester/zeta")
        fs.addRepository(at: "/Users/tester/alpha")
        fs.addRepository(at: "/Users/tester/mid/deep")
        fs.addRepository(at: "/Volumes/Aardvark/proj")

        let result = try await makeScanner(fs).scan(
            policy: ScanPolicy(homeRoot: "/Users/tester", extraRoots: ["/Volumes/Aardvark"])
        )

        #expect(paths(result) == [
            "/Users/tester/alpha",
            "/Users/tester/mid/deep",
            "/Users/tester/zeta",
            "/Volumes/Aardvark/proj",
        ])
        #expect(paths(result) == paths(result).sorted())
    }
}

@Suite("RepoScanner.classifyGitFile reads the gitdir: line a .git file carries")
struct RepoScannerGitFileClassificationTests {

    @Test("A .git file pointing into .git/worktrees is a linked worktree checkout")
    func worktreeCheckoutIsClassified() {
        let classification = RepoScanner.classifyGitFile(
            contents: "gitdir: /Users/tester/code/app/.git/worktrees/feature\n"
        )

        guard case .worktreeCheckout = classification else {
            Issue.record("expected a worktree checkout, got \(classification)")
            return
        }
    }

    /// The frozen enum names this payload `commonDirectory`, not `gitDirectory`, and the common
    /// directory of a linked worktree is the main repo's `.git` — everything before
    /// `/worktrees/`. That is also the dedupe key, so a worktree checkout and its repo would
    /// otherwise collide under two different keys.
    @Test("worktreeClassificationCarriesTheCommonDirectoryNotTheWorktreeStub")
    func worktreeClassificationCarriesTheCommonDirectoryNotTheWorktreeStub() {
        let classification = RepoScanner.classifyGitFile(
            contents: "gitdir: /Users/tester/code/app/.git/worktrees/feature\n"
        )

        #expect(classification == .worktreeCheckout(commonDirectory: "/Users/tester/code/app/.git"))
    }

    @Test("A .git file pointing into .git/modules is a submodule, carrying the git directory")
    func submoduleIsClassified() {
        let classification = RepoScanner.classifyGitFile(
            contents: "gitdir: /Users/tester/code/app/.git/modules/vendor/lib\n"
        )

        #expect(classification == .submodule(gitDirectory: "/Users/tester/code/app/.git/modules/vendor/lib"))
    }

    /// A separated git directory (`git init --separate-git-dir`) is a real repo, not a checkout
    /// of one, so it stays a candidate and its common dir is the path on the line.
    @Test("Any other gitdir: path is a candidate repo whose common dir is that path")
    func plainGitdirIsACandidate() {
        #expect(
            RepoScanner.classifyGitFile(contents: "gitdir: /Users/tester/store/app.git\n")
                == .candidate(gitDirectory: "/Users/tester/store/app.git")
        )
    }

    @Test("Whitespace and a missing trailing newline do not change the path")
    func gitdirLineIsTrimmed() {
        #expect(
            RepoScanner.classifyGitFile(contents: "gitdir: /Users/tester/store/app.git")
                == .candidate(gitDirectory: "/Users/tester/store/app.git")
        )
        #expect(
            RepoScanner.classifyGitFile(contents: "  gitdir:   /Users/tester/store/app.git  \n")
                == .candidate(gitDirectory: "/Users/tester/store/app.git")
        )
    }

    /// Anything that is not a `gitdir:` line is `unrecognized` rather than a guess: a candidate
    /// invented here becomes a repo row the user never cloned.
    @Test("A file with no usable gitdir: line is unrecognized", arguments: [
        "",
        "\n",
        "ref: refs/heads/main\n",
        "gitdir:\n",
        "gitdir: \n",
        "this is not a git file\n",
    ])
    func unrecognizedContents(contents: String) {
        #expect(RepoScanner.classifyGitFile(contents: contents) == .unrecognized)
    }
}

// MARK: - Packet F3 — bounded reads (codex MAJOR 15) and a repo at the scan root (REVIEW WR-08)

@Suite("RepoScanner reads a bounded prefix of a .git file and never stops at a root that is a repo")
struct RepoScannerBoundedAndRootRepoTests {

    private func scanner(_ fileSystem: InMemoryFileSystem) -> RepoScanner {
        RepoScanner(fileSystem: fileSystem)
    }

    /// codex MAJOR 15: a `.git` file is a repository-controlled input, and the marker git writes
    /// is one short line. Only the first `RepoScanner.maximumGitFileBytes` are read, so a repo
    /// carrying a gigabyte `.git` file cannot be read into memory by the scan.
    @Test("gitFileIsClassifiedFromABoundedPrefix")
    func gitFileIsClassifiedFromABoundedPrefix() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")

        // The marker line comes first, then far more bytes than the bound: still classified.
        fs.addFile(
            "/Users/tester/code/worktree/.git",
            contents: "gitdir: /Users/tester/code/app/.git/worktrees/wt\n"
                + String(repeating: "#", count: RepoScanner.maximumGitFileBytes * 2))

        // The marker line sits past the bound: never read, so never classified, and the walk
        // treats the directory as an ordinary folder rather than inventing a repo row.
        fs.addFile(
            "/Users/tester/code/hidden/.git",
            contents: String(repeating: "#", count: RepoScanner.maximumGitFileBytes + 64)
                + "\ngitdir: /Users/tester/code/elsewhere/.git\n")
        fs.addRepository(at: "/Users/tester/code/hidden/inner")

        let result = try await scanner(fs).scan(policy: ScanPolicy(homeRoot: "/Users/tester"))

        #expect(result.skippedWorktreeCheckouts == ["/Users/tester/code/worktree"],
                "the marker in the first bytes is still read")
        #expect(!result.repos.map(\.path).contains("/Users/tester/code/hidden"))
        #expect(result.repos.map(\.path).contains("/Users/tester/code/hidden/inner"),
                "an unrecognized .git file does not stop the walk")
    }

    /// REVIEW WR-08. `git init` in `$HOME` with a `*` gitignore is a common dotfiles pattern.
    /// The `.git` check runs on a directory before its children are enqueued, so a repo at the
    /// scan root used to make that root the one and only candidate and end the walk there, with
    /// every real repo under it invisible. The root is a repo **and** a folder to walk.
    @Test("dotfilesRepoAtHomeRootDoesNotStopTheScan")
    func dotfilesRepoAtHomeRootDoesNotStopTheScan() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Users/tester")
        fs.addRepository(at: "/Users/tester/code/app")
        fs.addRepository(at: "/Users/tester/work/site")

        let result = try await scanner(fs).scan(policy: ScanPolicy(homeRoot: "/Users/tester"))

        #expect(result.repos.map(\.path) == [
            "/Users/tester", "/Users/tester/code/app", "/Users/tester/work/site",
        ])
    }

    /// The exception is the **home root only**. An "Add folder…" root that is itself a repo keeps
    /// the plain rule — it is the folder the user pointed at, and `extraRootThatIsARepoYieldsItself`
    /// has pinned that since packet 2.4. REVIEW WR-08 proposes extending the descent to added
    /// roots as well; that would overturn a green test and PLAN.md §5's `descendIntoRepos: false`,
    /// so it is left for whoever owns that decision. This test is the boundary between the two.
    @Test("addedRootThatIsARepoIsListedWithoutDescending")
    func addedRootThatIsARepoIsListedWithoutDescending() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addDirectory("/Volumes/work")
        fs.addRepository(at: "/Volumes/work/mono")
        fs.addRepository(at: "/Volumes/work/mono/packages/inner")

        let result = try await scanner(fs).scan(
            policy: ScanPolicy(homeRoot: "/Users/tester", extraRoots: ["/Volumes/work/mono"]))

        #expect(result.repos.map(\.path) == ["/Volumes/work/mono"])
    }
}

// MARK: - Packet F6 — codex round 2, BLOCKER 2 and MAJOR 3

/// A hand-built listing plus a record of every file the scanner opened. `InMemoryFileSystem`
/// reports a symlink as a directory, which is the opposite of what `RealFileSystem` does for the
/// case under test, so the entries are given verbatim here.
private final class MarkerFileSystem: FileSystem, @unchecked Sendable {
    private let listings: [String: [DirectoryEntry]]
    private let lock = NSLock()
    private var _opened: [String] = []

    init(_ listings: [String: [DirectoryEntry]]) { self.listings = listings }

    /// Every path a read was attempted on, in call order.
    var opened: [String] {
        lock.lock(); defer { lock.unlock() }
        return _opened
    }

    func contentsOfDirectory(atPath path: String) throws -> [DirectoryEntry] {
        guard let entries = listings[path] else {
            throw InMemoryFileSystem.PermissionDenied(path: path)
        }
        return entries
    }

    func fileExists(atPath path: String) -> Bool { listings[path] != nil }
    func isExecutableFile(atPath path: String) -> Bool { false }
    func readFile(atPath path: String) throws -> Data {
        lock.lock(); _opened.append(path); lock.unlock()
        throw InMemoryFileSystem.PermissionDenied(path: path)
    }
    func modificationDate(atPath path: String) throws -> Date {
        throw InMemoryFileSystem.PermissionDenied(path: path)
    }
    func homeDirectory() -> String { "/Users/tester" }
    func pathEnvironment() -> String { "/usr/bin:/bin" }
}

@Suite("A .git marker that is a symlink is never opened, and a newline in a path is part of it")
struct RepoScannerHostileMarkerTests {

    /// codex BLOCKER 2: "A `.git` symlink is reported as `isDirectory == false`, then RepoScanner
    /// treats it as a regular `.git` file … A repo containing `.git -> /path/to/FIFO` therefore
    /// blocks the scan in `open(O_RDONLY)` indefinitely."
    ///
    /// A symlink is not a marker this scanner will vouch for, so it is classified `unrecognized`
    /// and the walk carries on — the same answer a `.git` file with no `gitdir:` line gets. The
    /// assertion that matters is the one about `opened`: the file is never read at all, so there
    /// is nothing for a FIFO behind it to block.
    @Test("dotGitSymlinkIsNeverOpened")
    func dotGitSymlinkIsNeverOpened() async throws {
        let fileSystem = MarkerFileSystem([
            "/Users/tester": [
                DirectoryEntry(name: "hostile", path: "/Users/tester/hostile", isDirectory: true),
                DirectoryEntry(name: "plain", path: "/Users/tester/plain", isDirectory: true),
            ],
            "/Users/tester/hostile": [
                // What `RealFileSystem` reports for `.git -> /tmp/fifo`: a link, never a directory.
                DirectoryEntry(
                    name: ".git", path: "/Users/tester/hostile/.git",
                    isDirectory: false, isSymbolicLink: true),
            ],
            "/Users/tester/plain": [
                DirectoryEntry(name: ".git", path: "/Users/tester/plain/.git", isDirectory: true),
            ],
        ])

        let result = try await RepoScanner(fileSystem: fileSystem)
            .scan(policy: ScanPolicy(homeRoot: "/Users/tester"))

        #expect(result.repos.map(\.path) == ["/Users/tester/plain"],
                "a symlinked .git was vouched for as a repo marker")
        #expect(!fileSystem.opened.contains("/Users/tester/hostile/.git"),
                "the scanner opened a symlinked .git: \(fileSystem.opened)")
    }

    /// codex MAJOR 3: "A legal folder such as `project\narchive` shifts the common-directory/
    /// top-level fields. Dedupe uses the wrong ID, subsequent commands use a fragment as their
    /// working directory."
    ///
    /// The dedupe asks `rev-parse` for the two paths as **two invocations**, each stripped of
    /// exactly one trailing record newline, so a newline inside a path stays inside it.
    @Test("repoPathWithNewlineKeepsItsIdentity")
    func repoPathWithNewlineKeepsItsIdentity() async throws {
        let path = "/Users/tester/project\narchive"
        let commonDirectory = path + "/.git"

        let fileSystem = InMemoryFileSystem(home: "/Users/tester")
        fileSystem.addRepository(at: path)

        let runner = RecordedCommandRunner()
        runner.stubGit(
            ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            stdout: commonDirectory + "\n")
        runner.stubGit(
            ["-C", path, "rev-parse", "--path-format=absolute", "--show-toplevel"],
            stdout: path + "\n")

        let result = try await RepoScanner(fileSystem: fileSystem, commandRunner: runner)
            .scan(policy: ScanPolicy(homeRoot: "/Users/tester"))

        #expect(result.repos.map(\.path) == [path])
        #expect(result.repos.first?.id == RepoID(commonDir: commonDirectory))
    }
}

// Packet F11 — one walk, two consumers.
//
// The `branchbar-cli scan` helper has to publish a repo the moment it is deduped, or a kill takes
// every repo the walk had already found (F10). Rather than give the CLI a second walk that would
// drift from this one, `RepoScanner` reports what it is doing through `onProgress` and the CLI
// turns each event into a line of NDJSON. `InProcessScanRunner` passes no callback, so the app's
// in-process path is unchanged.
@Suite("RepoScanner reports what it found while it is still walking")
struct RepoScannerProgressTests {

    /// A recorder that is safe to hand a `@Sendable` callback.
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ScanEvent] = []
        func append(_ event: ScanEvent) { lock.lock(); storage.append(event); lock.unlock() }
        var all: [ScanEvent] { lock.lock(); defer { lock.unlock() }; return storage }
        var repos: [String] { all.compactMap { if case .repo(let r) = $0 { return r.path } else { return nil } } }
        var unreadable: [String] { all.compactMap { if case .unreadable(let p) = $0 { return p } else { return nil } } }
        var entering: [String] { all.compactMap { if case .entering(let p) = $0 { return p } else { return nil } } }
        var counters: [ScanCounters] { all.compactMap { if case .skipped(let c) = $0 { return c } else { return nil } } }
    }

    @Test("scannerReportsEachRepoAsItIsDeduped")
    func scannerReportsEachRepoAsItIsDeduped() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Users/tester/alpha")
        fs.addRepository(at: "/Users/tester/beta")
        fs.addDirectory("/Users/tester/locked")
        fs.markUnreadable("/Users/tester/locked")

        let events = Events()
        let scanner = RepoScanner(fileSystem: fs, onProgress: { events.append($0) })
        let result = try await scanner.scan(policy: ScanPolicy(homeRoot: "/Users/tester"))

        #expect(events.repos.sorted() == ["/Users/tester/alpha", "/Users/tester/beta"])
        #expect(events.repos.sorted() == result.repos.map(\.path).sorted())
        #expect(events.unreadable == ["/Users/tester/locked"])
        #expect(!events.counters.isEmpty, "the walk never reported its skip counters")
        #expect(events.counters.last?.candidatesExamined == result.candidatesExamined)
    }

    /// The event the "Not scanned" row is built from when the process dies inside a listing: the
    /// gated folder is announced *before* the call that can block, because nothing after it will
    /// run if macOS never answers.
    @Test("scannerAnnouncesAGatedFolderBeforeListingIt")
    func scannerAnnouncesAGatedFolderBeforeListingIt() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Users/tester/alpha")
        fs.addRepository(at: "/Users/tester/Documents/notes")

        let events = Events()
        let scanner = RepoScanner(fileSystem: fs, onProgress: { events.append($0) })
        _ = try await scanner.scan(policy: ScanPolicy(homeRoot: "/Users/tester"))

        #expect(events.entering.contains("/Users/tester/Documents"))
        // Was "only the folders macOS gates are announced" until codex round 3, MAJOR 2. That
        // narrowness was the bug: a helper killed inside an ordinary directory left a truncated
        // result naming no folder at all, and the presenter suppressed its warning on exactly that
        // emptiness. Everything at depth 1 under the home root is announced now, so the folder the
        // walk was inside is always on the wire; nothing deeper is, because "Not scanned:
        // Documents" is a row the user can act on and `Documents/notes/vendor` is not.
        #expect(events.entering.allSatisfy { path in
            let parent = (path as NSString).deletingLastPathComponent
            return path == "/Users/tester" || parent == "/Users/tester"
        }, "a folder deeper than the home root's own children was announced: \(events.entering)")

        // Every repo outside the gated folders is on the wire before the gated listing starts.
        let enteringIndex = try #require(events.all.firstIndex {
            if case .entering("/Users/tester/Documents") = $0 { return true } else { return false }
        })
        let alphaIndex = try #require(events.all.firstIndex {
            if case .repo(let repo) = $0 { return repo.path == "/Users/tester/alpha" } else { return false }
        })
        #expect(alphaIndex < enteringIndex)
    }
}

// MARK: - Packet F13 — codex round 3, MAJOR 2 and MAJOR 8

/// codex round 3, MAJOR 2: "A killed scan can silently present an incomplete repository list."
/// `.entering` was emitted for the three gated home folders only, so a helper killed inside an
/// ordinary directory or an added root produced a truncated result naming no folder at all — and
/// the presenter suppressed its warning on exactly that emptiness.
///
/// MAJOR 8's other half: an extra root is walked with no depth limit by design, which makes a root
/// on a huge volume an unbounded walk that the deadline kills every refresh forever.
@Suite("Every root the walk enters says so, and an added root has a budget")
struct ScanNarrationAndBudgetTests {

    /// A recorder that is safe to hand a `@Sendable` callback (the suite above keeps its own).
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ScanEvent] = []
        func append(_ event: ScanEvent) { lock.lock(); storage.append(event); lock.unlock() }
        var all: [ScanEvent] { lock.lock(); defer { lock.unlock() }; return storage }
        var unreadable: [String] { all.compactMap { if case .unreadable(let p) = $0 { return p } else { return nil } } }
        var entering: [String] { all.compactMap { if case .entering(let p) = $0 { return p } else { return nil } } }
    }

    @Test("enteringIsEmittedForExtraRoots")
    func enteringIsEmittedForExtraRoots() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Users/tester/alpha")
        fs.addRepository(at: "/Volumes/work/beta")
        fs.addDirectory("/Volumes/work/deep/nested/folder")

        let events = Events()
        let scanner = RepoScanner(fileSystem: fs, onProgress: { events.append($0) })
        _ = try await scanner.scan(policy: ScanPolicy(
            homeRoot: "/Users/tester", extraRoots: ["/Volumes/work"]))

        #expect(events.entering.contains("/Volumes/work"),
                "an added root that blocks leaves no record of where the walk was: \(events.entering)")
        // The home root and its own children are announced too, so a kill inside an ordinary
        // folder names a folder the user can act on.
        #expect(events.entering.contains("/Users/tester"))
        #expect(events.entering.contains("/Users/tester/alpha"))
        // And nothing deeper: "Not scanned: alpha" is actionable, "alpha/src/vendor" is not.
        #expect(!events.entering.contains("/Volumes/work/deep/nested/folder"))
    }

    /// The budget makes an unbounded root finite **and visible**: the root joins the not-scanned
    /// list and the result is truncated, so the incomplete-scan notice appears and the next
    /// refresh walks again rather than freezing a partial list into the cache for a week.
    @Test("extraRootCandidateBudgetIsEnforced")
    func extraRootCandidateBudgetIsEnforced() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        // One directory more than the budget, all directly under the root, so the walk lists the
        // root and then each child in turn.
        for index in 0...(RepoScanner.extraRootCandidateBudget) {
            fs.addDirectory("/Volumes/huge/folder-\(index)")
        }

        let events = Events()
        let scanner = RepoScanner(fileSystem: fs, onProgress: { events.append($0) })
        let result = try await scanner.scan(policy: ScanPolicy(
            homeRoot: "/Users/tester", extraRoots: ["/Volumes/huge"]))

        #expect(result.truncatedByDeadline, "an unbounded added root ran to the end of the volume")
        #expect(result.unreadableDirectories.contains("/Volumes/huge"),
                "the root the budget stopped is not named: \(result.unreadableDirectories)")
        #expect(result.candidatesExamined <= RepoScanner.extraRootCandidateBudget + 2,
                "the budget did not stop the walk: \(result.candidatesExamined)")
        #expect(events.unreadable.contains("/Volumes/huge"),
                "the stream never carried the folder the row is rebuilt from")
    }

    /// A root well inside the budget still walks to the bottom, which is the whole point of an
    /// added root having no depth limit (PLAN.md §3).
    @Test("anAddedRootUnderTheBudgetIsStillWalkedToTheBottom")
    func addedRootUnderTheBudgetIsWalkedFully() async throws {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        fs.addRepository(at: "/Volumes/work/one/two/three/four/five/six/seven/deep")

        let result = try await RepoScanner(fileSystem: fs).scan(policy: ScanPolicy(
            homeRoot: "/Users/tester", extraRoots: ["/Volumes/work"]))

        #expect(result.repos.map(\.path) == ["/Volumes/work/one/two/three/four/five/six/seven/deep"])
        #expect(!result.truncatedByDeadline)
    }
}
