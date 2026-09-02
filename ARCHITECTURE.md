# ARCHITECTURE — BranchBar

<!-- How it works, current truth. DECISION-LOG.md holds why it changed. Rule: after any edit
     pass that shifts line numbers, run `make doc-refs` and fix every stale file:line before
     committing. -->

## §1 System overview

```mermaid
graph TD
    subgraph UI["BranchBar (executable, SwiftUI shell, @MainActor): views only"]
        App[BranchBarApp: MenuBarExtra .window] --> AM[AppModel: published SnapshotVM + RefreshState]
        AM --> V[Views: RepoSection, BranchRow, GroupRows, Footer]
        V --> Act[Actions: open -a Cursor, open URL, Finder, clipboard, launch at login]
    end
    subgraph Core["BranchBarCore (library, no AppKit or SwiftUI, fully tested)"]
        AM --> SP[SnapshotPresenter: Snapshot to row view models via Strings.swift]
        AM --> RC[RefreshCoordinator actor: cap 4, 45 s deadline, isolation, progressive emit, stable order, lazy PR]
        RC --> TL[ToolLocator: git and gh outside the GUI PATH]
        RC --> SC[RepoScanner: BFS depth 6, hidden dir and literal skip list, dedupe]
        RC --> RL[RepoLoader: one repo]
        RL --> GC[GitClient] --> P1[ForEachRefParser]
        GC --> P2[WorktreeListParser]
        RL --> P3[ReflogFileReader: usable line predicate]
        RL --> GH[GHClient: per host auth, list plus per head fallback, PR cache TTL] --> P4[PRListDecoder and PRStatusMapper]
        RL --> AS[RepoAssembler: pure join, Merged and Closed and Open elsewhere groups]
        AS --> PD[PushInfoDeriver]
        RC --> CS[CacheStore: atomic replace]
        GC --> CR[CommandRunner protocol]
        GH --> CR
        SC --> FS[FileSystem protocol]
        P3 --> FS
    end
    subgraph Ext["Outside the process: trust boundary"]
        CR --> GIT[/git binary/]
        CR --> GHB[/gh binary to GitHub API with the user's own token/]
        FS --> HOME[/home folder: TCC gated/]
    end
```

The app holds no credentials. `gh` authenticates itself from its own keyring; BranchBar reads only its stdout. Three protocols (`CommandRunner`, `FileSystem`, `CacheStore`) are the only routes to the outside world, and tests replace all three.

## §2 Key flows

Five mechanisms someone has to understand before editing safely. A diagram changes in the same commit as the code it describes.

### §2.1 One refresh

Coalescing, the bounded scan, the concurrency cap, progressive emits, and the lazy `gh` fetch, all owned by `RefreshCoordinator`.

```mermaid
sequenceDiagram
    autonumber
    participant UI as AppModel
    participant RC as RefreshCoordinator
    participant SC as RepoScanner
    participant RL as RepoLoader
    participant EXT as git and gh
    participant CS as CacheStore

    UI->>RC: refresh(force, expandedRepoIDs, tools)
    alt A refresh is already in flight
        RC-->>UI: Await that task and return its snapshot, no second walk
    else Under the 30 s debounce and force is false
        RC-->>UI: Return the last snapshot, no command runs
    else Git is missing
        RC-->>UI: Return the cached snapshot, the tool notice carries the reason
    else Run one refresh
        RC->>CS: load()
        alt Scan absent, truncated, or older than 7 days
            RC->>SC: Walk under the 20 s scan deadline, gated folders last
            SC-->>RC: ScanResult, partial when the deadline wins
        end
        RC-->>UI: Emit the cached rows once at launch, every row marked stale
        loop Repos in the order computed once, at most 4 at a time
            RC->>RL: load(repo, wantsPullRequests)
            RL->>EXT: git rev-parse, config, both for-each-ref, worktree list
            RL->>EXT: One reflog file read per branch that has an upstream
            opt Repo is expanded or in the launch top 5, and the PR cache is past 10 min
                RL->>EXT: gh pr list recent 100, per-head fallback capped at 20, author @me
            end
            RL-->>RC: Repo plus the PRCacheEntry to keep
            RC-->>UI: Emit every row again, order unchanged
        end
        opt The 45 s overall deadline arrives first
            RC->>RL: Cancel the group, which terminates every child process
            RC->>RC: Mark unfinished repos stale with a deadlineExceeded error
        end
        RC->>CS: save(CacheFile) through a temp file and replaceItemAt
        RC-->>UI: Final snapshot
    end
```

A cancel and a deadline are deliberately different: the deadline persists what it has, `cancel()` persists nothing and leaves the last emitted snapshot on screen.

### §2.2 What a row may claim about a push

Every branch of this tree ends in wording, because the trap this mechanism exists to avoid is
presenting a commit date as an observed push.

```mermaid
graph TD
    A{"Which remote-tracking ref does this branch have?"} -->|"A configured upstream"| B
    A -->|"None configured, but origin/name exists"| B
    A -->|"Neither"| A1["Source: none, ahead count nil. Row reads No tracked remote branch · push history not checked"]
    B{"Does the reflog file for that remote branch exist?"}
    B -->|"No"| F["Source: tipCommitDate"]
    B -->|"Yes"| C["Walk the lines newest first"]
    C --> D{"Is the new OID on this line all zeros?"}
    D -->|"Yes: a push deletion, the boundary"| F
    D -->|"No, and an all-zero old OID is a creation, not a boundary"| E{"Does the message start with update by push?"}
    E -->|"No: fetch, pull, or reset"| C
    E -->|"Yes"| G["Source: reflogObserved. Timestamp and new OID come off this line"]
    G --> H{"Does the observed OID equal the remote-tracking tip?"}
    H -->|"Yes"| I["Row reads Pushed from this Mac 2 days ago"]
    H -->|"No"| J["originMovedSince. Row adds (origin has moved since)"]
    F --> K{"Does the remote-tracking tip carry a commit date?"}
    K -->|"Yes"| L["Row reads Last push unknown · newest commit dated 2 days ago"]
    K -->|"No"| A1
    A1 --> M["Ahead count: nil with no configured upstream, nil when the upstream is gone and the row adds Upstream missing from last-known origin, otherwise the count from upstream:track"]
    J --> M
    I --> M
    L --> M
    M --> N{"Is there a FETCH_HEAD in this repo?"}
    N -->|"Yes"| N1["Tooltip: Counted against last-known origin, last seen 3 hours ago"]
    N -->|"No"| N2["Tooltip: Counted against last-known origin, origin not fetched by this clone yet"]
```

Three facts the wording keeps apart: this clone observed a push, this clone knows only a commit
date, and nothing about the branch is known at all. Lines expire after 90 days, and a push from
another machine is invisible to this file by design.

**A branch with no upstream is not a branch that never went out.** `git push origin feature`
without `-u` creates `refs/remotes/origin/feature` and writes `update by push` into its reflog
file while configuring no tracking at all, so the old "Never pushed" was the opposite of what the
file on disk recorded (REVIEW WR-01, codex MAJOR 6). `RepoLoader` therefore reads the reflog for
`origin/<name>` whenever that ref exists, with or without tracking configuration, and
`PushInfoDeriver` keeps the observation while holding the ahead count at nil: there is a push to
report and nothing to be ahead of. Only a branch with neither a configured upstream nor a
same-named remote ref gets the no-history wording, and that wording says what BranchBar did
("push history not checked"), not what the branch did.

**The two remote dates are different facts and never share a field** (codex MAJOR 7). The remote
tip's committer date is when someone wrote that commit; `FETCH_HEAD`'s modification date is when
this clone last heard from origin. The "last seen" tooltip reads only the second, because fetching
a two-year-old commit today is news from today, not from two years ago. A clone that has only ever
been pushed from has no `FETCH_HEAD`, which is why the tooltip has a branch that says so rather
than omitting the clause.

`GitClient.reflogShow` carries PLAN.md §5's secondary `git reflog show` fallback and is pinned by a
live-repo test; `RepoLoader` does not call it, so the shipping path is the file read and then the
tip commit date.

### §2.3 How a folder becomes a repo row

```mermaid
graph TD
    A["Queue the scan root at depth 0"] --> B{"Is the walk cancelled?"}
    B -->|"Yes"| B1["Mark the result truncated, name every folder still queued as not scanned, keep the repos already found"]
    B -->|"No"| C{"Can the directory be listed?"}
    C -->|"No: TCC denial or permissions"| C1["Record the path in unreadableDirectories, which the row Not scanned reads"]
    C -->|"Yes"| D{"Does it hold a .git entry?"}
    D -->|".git is a directory"| D1["Candidate. Common directory hint is path plus /.git"]
    D -->|".git is a file"| E{"What does the first 4 KB of gitdir line point at?"}
    D -->|"No .git entry"| G["Enqueue every child directory"]
    E -->|"Inside .git/worktrees/"| E1["Worktree checkout: counted in skippedWorktreeCheckouts, never its own row"]
    E -->|"Inside .git/modules/"| E2["Submodule: counted in skippedSubmodules"]
    E -->|"Anywhere else"| D1
    E -->|"No gitdir line"| G
    D1 --> R{"Is this the home root itself?"}
    R -->|"Yes"| G
    R -->|"No, or it is an Add folder root"| S["Stop here: the walk does not descend into a repo it found"]
    G --> H{"Skip this child?"}
    H -->|"Symlink"| H1["Skipped: following one turns the home scan unbounded, and it is never stat'd"]
    H -->|"Hidden name"| H2["Counted in skippedHiddenDirectories"]
    H -->|"On the literal skip list, such as Library or node_modules"| H3["Skipped by name, or by path suffix for go/pkg"]
    H -->|"Past depth 6, home root only"| H4["Counted in depthCutDirectories. Add folder roots have no depth limit"]
    H -->|"Desktop, Documents, or Downloads directly under the home root"| H5["Held back and enqueued after every other folder, so a pending access dialog blocks nothing else"]
    H -->|"None of these"| B
    S --> I["Dedupe by git rev-parse --git-common-dir, keeping the working tree whose .git is a real directory, sorted by path"]
```

**A home folder that is itself a repo does not end the walk.** `git init` in `$HOME` with a `*`
gitignore is the dotfiles pattern, and the `.git` check runs before a directory's children are
enqueued, so `~/.git` made `~` the one and only candidate: every real repo under home invisible,
the empty state suppressed because one repo was listed, and nothing on screen saying why (REVIEW
WR-08). The home root is now listed as a repo **and** walked. An "Add folder…" root that is a repo
keeps the plain rule: the user pointed at that folder, so they get that repo, and a nested one is
another "Add folder…" away.

**Every read the walk makes is bounded, and none of them stats a symlink.** A `.git` file is
repository-controlled, so it is classified from a bounded prefix rather than read whole (codex
MAJOR 15). `RealFileSystem` lists once with `.isDirectoryKey` and `.isSymbolicLinkKey` resource
values: no `attributesOfItem` per entry, which blocks behind a folder-access dialog, and no `stat`
of a symlink's target, which used to follow a link out of the tree the walk was told to stay in.

**Two bounds sit on top of the walk, and they answer different questions.** `Task.isCancelled` is
checked before each listing, which is the only place cancellation can land: a listing already
inside `open()` behind an unanswered consent dialog cannot be interrupted by anything. The gated
folders going last is what keeps that unanswerable case from blocking everything else. Above both,
`RefreshCoordinator.scanWithinDeadline` races the whole walk against the 20 s scan deadline and
takes the partial result, marking it `truncatedByDeadline` so the next refresh rescans.

### §2.4 How a branch gets its PR pill

```mermaid
graph TD
    A{"Is the repo expanded, or in the launch top 5?"} -->|"No"| A1["prLoadState notLoaded. Pill reads PR status loads when expanded"]
    A -->|"Yes"| B{"Is the PR cache newer than 10 min?"}
    B -->|"Yes"| B1["Serve the cached PRs and the cached queriedHeads, issue no gh call"]
    B -->|"No"| C["gh auth status per host, memoized for the refresh"]
    C -->|"Non-zero exit"| C1["Unavailable: ghNotAuthenticated for every repo on that host"]
    C -->|"Exit 0"| D["gh pr list --state all --limit 100"]
    D -->|"GitHub's own rate-limit wording"| D1["Unavailable: rateLimited. Waiting really does fix it"]
    D -->|"Any other failure, 403 included"| D2["Unavailable: commandFailed, worded neutrally. The per-head and author calls are skipped"]
    D -->|"Rows"| E["Record every returned headRefName in queriedHeads"]
    E --> F{"Does a local branch still have no PR?"}
    F -->|"Yes"| G["gh pr list --head, most recently active first, capped at 20 per repo"]
    F -->|"No"| H
    G --> H["Match by headRefName, so a fork PR opened from this branch is never filtered out"]
    H --> I{"Does this branch's own owner claim that head?"}
    I -->|"No"| K
    I -->|"Yes, and several qualify"| I1["Break the tie: an OPEN state first, then the latest updatedAt"]
    I -->|"Yes, exactly one"| J["Map the state: MERGED, CLOSED, draft, APPROVED, CHANGES_REQUESTED, else open"]
    I1 --> J
    B1 --> K{"Was this head queried?"}
    J --> K
    K -->|"Yes, and no PR came back"| K1["Status none. Pill reads No PR"]
    K -->|"No: past the cap, collapsed, or cut by the deadline"| K2["Status notChecked. Pill reads PR status not checked yet"]
    D --> L["gh pr list --state open --author @me. Any PR whose owner login and head branch match no local branch becomes Open PRs not on this Mac"]
```

`queriedHeads` is the field that keeps `none` and `notChecked` apart across a relaunch: a `Repo` alone cannot say which heads were asked about.

**Owner is a constraint, not a tie-break** (codex MAJOR 9). Matching on `headRefName` alone was right for a fork PR opened from a branch that really is yours, and wrong for the commoner case where exactly one candidate came back: somebody else's fork carrying a branch of the same popular name (`main`, `fix-typo`) attached itself to your local branch, and the row reported a stranger's review state as yours. A branch may claim a PR head only from the owner it can prove: the upstream's owner login when it tracks a remote this app resolved a slug for, and otherwise the repo's own slug owner, which is the only owner an untracked branch could plausibly have. A single candidate from any other owner is no longer a match, and the branch renders `No PR` rather than someone else's pull request. State and `updatedAt` order only the candidates that already passed the owner test.

**The failure copy no longer asserts a cause the data cannot support** (REVIEW WR-02). `.rateLimited` now requires GitHub's own rate-limit wording, because an enterprise returns HTTP 403 for SAML enforcement, a missing token scope, and IP allow-list denials, none of which waiting fixes. A repo `gh` cannot resolve is `.commandFailed` with neutral copy rather than a promise that refreshing brings it back.

### §2.5 Packet DAG

PLAN.md §8's dispatch order, plus the two packets execution added.

```mermaid
graph LR
    P01["0.1 Bootstrap"] --> P02["0.2 Spike"]
    P02 --> G0{{"Gate 0: builds on Command Line Tools"}}
    G0 --> P03["0.3 Spike zip"]
    P03 --> G0B{{"Gate 0b: NYT managed Mac"}}
    G0B --> P11["1.1 Contracts frozen"]
    P11 --> P40["4.0 UI contract and Strings"]
    P40 --> G40{{"Gate 4.0: Hannah reads the string table"}}
    P11 --> P21["2.1 GitClient and git parsers"]
    P11 --> P23["2.3 GHClient"]
    P11 --> P24["2.4 RepoScanner"]
    P11 --> P25["2.5 Runner, locator, cache store"]
    P40 --> P22["2.2 Presenter and pure mappers"]
    P21 --> P22
    P21 --> P31["3.1 Assembler and loader"]
    P22 --> P31
    P23 --> P31
    P24 --> P32["3.2 RefreshCoordinator and branchbar-cli"]
    P25 --> P32
    P31 --> P32
    P32 --> G3{{"Gate 3: CLI matches a hand-checked table"}}
    G3 --> P41["4.1 SwiftUI shell"]
    P41 --> P51A["5.1a First release zip"]
    P51A --> G5{{"Gate 5: NYT tester installs v0.9.0"}}
    P41 --> P42["4.2 Actions and launch at login"]
    P42 --> P33["3.3 Bounded, prompt-safe scan"]
    P33 --> P43["4.3 Shell strings into Core"]
    P42 --> G4{{"Gate 4: one screenshot per state"}}
    P43 --> P51B["5.1b Packaging hardening, v1.0.0"]
    G5 --> P51B
    P51B --> P52["5.2 Docs as deliverables"]
    P52 --> G5B{{"Gate 5b: a second user installs from the README alone"}}
```

## §3 Anatomy

One row per concern, each pointing at the line that declares it. `make doc-refs` reads this table and fails on any row whose line no longer holds its symbol, so an edit pass that shifts line numbers cannot land silently.

| Concern | Symbol | Declared at | Notes |
|---|---|---|---|
| **Core: the refresh** | | | |
| One refresh end to end: coalescing, cap 4, 45 s deadline, progressive emit, atomic persist | `RefreshCoordinator` | `Sources/BranchBarCore/RefreshCoordinator.swift:8` | An actor, so a second popover open coalesces instead of starting a parallel walk |
| Discovery run inside a bound so a pending folder-access dialog cannot hang a refresh | `scanWithinDeadline` | `Sources/BranchBarCore/RefreshCoordinator.swift:351` | Takes the scanner's partial result when the 20 s bound wins, and rescans next time |
| Repo order computed once per refresh and never recomputed mid-flight | `stableOrder` | `Sources/BranchBarCore/RefreshCoordinator.swift:438` | Previous snapshot's activity first, then new repos alphabetically |
| One repo end to end: seven stages, each failure isolated into a `RepoError` | `RepoLoader` | `Sources/BranchBarCore/RepoLoader.swift:8` | Never throws, so one broken repo leaves the others populated |
| Pure join of git and GitHub facts into a `Repo`, and the three groups | `RepoAssembler` | `Sources/BranchBarCore/RepoAssembler.swift:9` | Grouping is decided here and only rendered by the presenter |
| **Core: git** | | | |
| Every frozen git invocation, with the frozen environment and per-command timeouts | `GitClient` | `Sources/BranchBarCore/GitClient.swift:6` | `LC_ALL=C` and `GIT_OPTIONAL_LOCKS=0` live in `frozenEnvironment` |
| Branch and remote-ref rows split on U+001F | `ForEachRefParser` | `Sources/BranchBarCore/ForEachRefParser.swift:65` | "No upstream" is decided from `upstream:short`, never from the track field |
| Worktree records, including the ones with no branch | `WorktreeListParser` | `Sources/BranchBarCore/WorktreeListParser.swift:11` | Primary, linked, detached, locked, prunable, bare |
| The reflog file read, the deletion boundary, and the usable-line predicate | `ReflogFileReader` | `Sources/BranchBarCore/ReflogFileReader.swift:8` | Walks newest first and stops at the first all-zero new OID |
| One reflog line, with fields counted from the end of the header | `Entry` | `Sources/BranchBarCore/ReflogFileReader.swift:73` | Author names carry spaces, so field 5 cannot be counted from the front |
| The `git reflog show` fallback parser, kept for the secondary path | `ReflogParser` | `Sources/BranchBarCore/ReflogParser.swift:25` | `RepoLoader` does not call it today; a live-repo test pins the invocation |
| Push facts, and the rule that a commit date is never presented as a push | `PushInfoDeriver` | `Sources/BranchBarCore/PushInfoDeriver.swift:8` | No upstream yields a nil ahead count, never zero |
| The git version gate behind the "works best with 2.39" notice | `GitVersion` | `Sources/BranchBarCore/GitVersion.swift:11` | Parsed from `git --version`, Apple's build suffix included |
| **Core: GitHub** | | | |
| Every `gh` invocation, per-host auth memoized, per-head cap, list caches | `GHClient` | `Sources/BranchBarCore/GHClient.swift:8` | An actor: the auth answer and the list caches are shared across repos on a host |
| The `--json` field list shared by all three `gh pr list` invocations | `jsonFields` | `Sources/BranchBarCore/GHClient.swift:54` | Changing it means re-recording the fixtures |
| PR JSON decode, including `headRepositoryOwner` as an object | `PRListDecoder` | `Sources/BranchBarCore/PRListDecoder.swift:8` | Sorted by `updatedAt` descending whatever order `gh` returned |
| PR to pill, branch to PR, and the "not on this Mac" key | `PRStatusMapper` | `Sources/BranchBarCore/PRStatusMapper.swift:14` | Head first, owner required not preferred, keyed by owner and branch |
| The `.command` file the sign-in action hands Terminal, as fixed text | `SignInScript` | `Sources/BranchBarCore/SignInScript.swift:25` | In Core so a test can render it and run it under a real zsh |
| The one variable part of that script, single-quoted: the resolved `gh` path | `render` | `Sources/BranchBarCore/SignInScript.swift:43` | The hostname is data in a sibling file, never script text |
| **Core: discovery** | | | |
| The home walk to depth 6 and the unlimited walk of added roots | `RepoScanner` | `Sources/BranchBarCore/RepoScanner.swift:22` | Breadth-first, no symlinks, never descends into a repo it found |
| The three folders macOS gates, enumerated after everything else | `tccGatedFolderNames` | `Sources/BranchBarCore/RepoScanner.swift:92` | Desktop, Documents, and Downloads as children of the home root only |
| `.git` file classification into worktree checkout, submodule, or candidate | `classifyGitFile` | `Sources/BranchBarCore/RepoScanner.swift:98` | A checkout's common directory is everything before `/worktrees/` |
| Tool discovery for a GUI process whose PATH has no Homebrew | `ToolLocator` | `Sources/BranchBarCore/ToolLocator.swift:54` | Env override, then four install locations, then PATH, then Apple git |
| **Core: presentation** | | | |
| `Snapshot` to view models, the only place a user-facing sentence is built | `SnapshotPresenter` | `Sources/BranchBarCore/SnapshotPresenter.swift:49` | Six frozen arguments; `EditorAvailability` is an initializer property |
| Every user-facing literal, one static member per string | `Strings` | `Sources/BranchBarCore/Strings.swift:27` | `make doc-strings` regenerates the UI-CONTRACT table from its doc comments |
| **Core: seams** | | | |
| The process seam every git and gh call passes through | `CommandRunner` | `Sources/BranchBarCore/Seams/CommandRunner.swift:82` | Argument arrays only, never a shell string |
| The real process implementation: concurrent draining, timeout, cancellation | `ProcessCommandRunner` | `Sources/BranchBarCore/ProcessCommandRunner.swift:5` | Both pipes drain on dedicated threads, then SIGTERM and SIGKILL |
| The filesystem seam for the scan, the reflog files, and the cache | `FileSystem` | `Sources/BranchBarCore/Seams/FileSystem.swift:25` | Synchronous by contract; the scan's bound lives one level up |
| The real filesystem, listing once with resource values | `RealFileSystem` | `Sources/BranchBarCore/RealFileSystem.swift:8` | No per-entry `attributesOfItem`: that call blocks behind folder-access dialogs |
| The cache seam | `CacheStore` | `Sources/BranchBarCore/Seams/CacheStore.swift:6` | Two methods, both replaced in tests |
| The cache file on disk, written through a temp file | `FileCacheStore` | `Sources/BranchBarCore/FileCacheStore.swift:7` | `replaceItemAt`, so an interrupted save leaves the previous file intact |
| **Core: data model** | | | |
| One repo, its branches, worktrees, PR availability, and errors | `Repo` | `Sources/BranchBarCore/Models/Repo.swift:138` | Identified by `RepoID`, the git common directory |
| The remote address parsed into host, owner, and name for any GitHub host | `GitHubSlug` | `Sources/BranchBarCore/Models/Repo.swift:23` | Enterprise hosts resolve and preflight per host |
| The hostname grammar every remote must pass before it becomes a slug | `isValidHostname` | `Sources/BranchBarCore/Models/Repo.swift:47` | RFC 1123 labels; the same pattern is re-applied in zsh by `SignInScript` (codex BLOCKER 1) |
| One branch and the group it renders in | `Branch` | `Sources/BranchBarCore/Models/Branch.swift:4` | `group` is the assembler-to-presenter boundary |
| The ten PR pill states, `notChecked` among them | `PRStatus` | `Sources/BranchBarCore/Models/PRStatus.swift:7` | `none` only after that head was actually queried |
| What a row may say about a push | `PushInfo` | `Sources/BranchBarCore/Models/PushInfo.swift:9` | `source` decides the wording, not the presenter |
| One worktree record | `Worktree` | `Sources/BranchBarCore/Models/Worktree.swift:8` | A worktree with no branch is shown and claimed by no branch |
| The scan policy: roots, depth, skip list | `ScanPolicy` | `Sources/BranchBarCore/Models/Scan.swift:8` | Added roots are recursive with no depth limit |
| What one walk reports, cut folders included | `ScanResult` | `Sources/BranchBarCore/Models/Scan.swift:61` | `truncatedByDeadline` forces the next refresh to rescan |
| Every timing constant in one place | `RefreshPolicy` | `Sources/BranchBarCore/Models/RefreshPolicy.swift:6` | Debounce 30 s, scan 20 s, overall 45 s, PR TTL 600 s, cap 4, per-head cap 20 |
| The cache file and its schema version | `CacheFile` | `Sources/BranchBarCore/Models/Cache.swift:9` | An unknown `schemaVersion` loads as nil rather than half a state |
| What one PR fetch is worth keeping, heads asked about included | `PRCacheEntry` | `Sources/BranchBarCore/Models/Cache.swift:42` | Without `queriedHeads` a warm cache would downgrade every `none` to `notChecked` |
| What the whole app renders from | `Snapshot` | `Sources/BranchBarCore/Models/Snapshot.swift:6` | Repos in stable order plus the tool status |
| The failure a user reads, with one action | `UserFacingFailure` | `Sources/BranchBarCore/Models/Failure.swift:6` | `diagnostic` is logged and never rendered |
| The row view models the SwiftUI layer is allowed to see | `SnapshotVM` | `Sources/BranchBarCore/Models/ViewModels.swift:7` | Views hold no copy and compute no sentence |
| **Shell** | | | |
| The menu bar entry point | `BranchBarApp` | `Sources/BranchBar/BranchBarApp.swift:203` | `MenuBarExtra` in `.window` style, which re-runs `onAppear` per open |
| Accessory activation, logging, and the state-fixture harness | `AppDelegate` | `Sources/BranchBar/BranchBarApp.swift:11` | `LSUIElement`, so there is no Dock icon and no menu bar menu |
| Published view models, the refresh trigger, collapse, hide, roots | `AppModel` | `Sources/BranchBar/AppModel.swift:29` | The only shell type that talks to Core |
| Row actions: editor chain, PR, Finder, clipboard | `Actions` | `Sources/BranchBar/Actions.swift:12` | Cursor, then VS Code, then Terminal; `https` PR links only |
| Launch at login | `LaunchAtLogin` | `Sources/BranchBar/LaunchAtLogin.swift:19` | `SMAppService`, which must refuse when the bundle is translocated |
| The guard that stops the toggle registering a copy the login item does not name | `isRunningFromApplications` | `Sources/BranchBar/LaunchAtLogin.swift:68` | Both mechanisms refuse outside `/Applications`, so they cannot name two bundles (REVIEW WR-05) |
| The popover body and keyboard traversal | `RootView` | `Sources/BranchBar/Views/RootView.swift:22` | Arrow keys traverse, Return runs the primary action, Escape dismisses |
| One repo section with its four groups | `RepoSectionView` | `Sources/BranchBar/Views/RepoSectionView.swift:7` | Collapse state is persisted per repo |
| One branch row | `BranchRowView` | `Sources/BranchBar/Views/BranchRowView.swift:7` | Worktree marker, name, pill, push line, ahead count |
| The PR pill and its ten colors | `PRPillView` | `Sources/BranchBar/Views/PRPillView.swift:9` | Color plus text, never an emoji |
| The footer: last updated, version, tool notice | `FooterView` | `Sources/BranchBar/Views/FooterView.swift:6` | Also the scan roots and the hidden-repo count |
| Width, row height, and type scale | `Metrics` | `Sources/BranchBar/Views/Tokens.swift:9` | Width 340, max height 70 percent of the screen |
| **CLI** | | | |
| `branchbar-cli snapshot` argument parsing | `Options` | `Sources/branchbar-cli/main.swift:19` | The Gate 3 harness and the Gate 0b fallback |
| The runner the CLI hands its cache-only bootstrap | `NoCommandsRunner` | `Sources/branchbar-cli/main.swift:178` | Keeps the harness from writing over the app's own cached snapshot |

## §4 Data model

Frozen in PLAN.md §5, and every type is `Hashable, Codable, Sendable`. State is mutated only through `RefreshCoordinator`.

The cache lives at `~/Library/Application Support/BranchBar/cache.json` and holds `CacheFile`: the last scan, manually added roots, hidden and collapsed repo ids, the per-repo `PRCacheEntry`, and the last `Snapshot`. Two rules govern it.

- **Atomic replace.** `FileCacheStore` writes a temp file and calls `replaceItemAt`, so a save interrupted halfway leaves the previous cache intact.
- **Unknown schema loads nil.** `CacheFile.currentSchemaVersion` is 1; a file carrying anything else is discarded rather than decoded field by field, so a downgrade shows an empty list and rescans instead of half a state.

Two derived fields exist because a `Repo` alone cannot answer the question honestly. `PRCacheEntry.queriedHeads` records which branch heads a fetch actually asked about, which is what keeps `PRStatus.none` and `PRStatus.notChecked` apart across a relaunch. `ScanResult.truncatedByDeadline` records that a walk was cut short, which is what stops a partial repo list from being cached as if it were complete.

## §5 Testing

```bash
make test        # swift test --disable-xctest --enable-swift-testing
```

**312 tests, all green.** Swift Testing only: XCTest is absent under Command Line Tools, and `noXCTestImportAnywhere` keeps it out on a machine that has full Xcode. `noAppKitOrSwiftUIImportInCore` keeps the shell's frameworks out of the library.

Fixtures live in `Tests/BranchBarCoreTests/Fixtures/` in three families. `recorded-*` (19 files) are byte-exact output from `/usr/bin/git` 2.39.5 and `gh` 2.89.0, written by `make record-fixtures`: no model ever transcribes git output. `synthetic-*` (23 files) are hand-written extensions for cases these repos cannot produce, each with a sibling `.md` note explaining what it models. `states/*.json` (38 files) are one per user-facing state in `docs/UI-CONTRACT.md`, each carrying the exact arguments of `SnapshotPresenter.present` plus the strings that state must show.

One test suite runs a real shell: `SignInScriptTests` renders the `gh` sign-in `.command` file and executes it under `zsh` with a hostile `gh-sign-in.host` beside it, because the only proof that a script refuses a hostname is the shell refusing it.

Two tests touch a real repo, and both skip themselves with a recorded reason rather than failing: `everyFrozenGitInvocationReturnsOutputOnThisRepo` skips when `git` is absent, and `reflogShowFallbackReturnsRowsForARefThatHasPushes` skips when this checkout's own `origin/main` reflog holds no push line, which is exactly what CI has, since a CI clone fetches and never pushes. Everything else replaces all three seams and touches no network, no real repo, and no home folder.

`docs/TEST-PLAN.md` maps every named invariant from PLAN.md §7 to the file that holds it.

## §6 Operations

- **Launch path:** `/Applications/BranchBar.app`, menu bar only (`LSUIElement`), no Dock icon and no menu bar menu of its own.
- **Logs:** `~/Library/Logs/BranchBar/BranchBar.log` (`make logs` tails it) and `log stream --predicate 'subsystem == "com.hannahstulberg.branchbar"'`. An empty log after a first open means the user is still at the Gatekeeper dialog: the process is held before `applicationDidFinishLaunching` runs.
- **Headless snapshot:** `make snapshot ROOTS="~/one ~/two"` runs `branchbar-cli snapshot`, which prints every repo, branch, worktree, PR, and push as a table, or as JSON with `--json`. It is the Gate 3 harness, the way to reproduce a user's list without the UI, and the fallback if the menu bar app is ever blocked on a managed Mac. `BRANCHBAR_GIT` pins the git binary.
- **State screenshots:** `scripts/screenshot-states.sh` renders every `states/*.json` fixture through the real app.
- **Runbooks:** `docs/runbooks/gate-0b-nyt-spike-test.md` is the tester-facing install checklist the README's install steps mirror; `docs/runbooks/quarantine-rehearsal.md` holds the Gatekeeper and app-translocation findings with the exact commands.

## §7 Security contract

- **No secrets stored, read, or logged.** `gh` authenticates itself from its own keyring and BranchBar reads only its stdout. A `GH_TOKEN` exported in a shell rc is invisible to a GUI app, so it is not a supported setup. A remote URL that carries credentials in its userinfo (`https://user:token@host/o/r`) has them stripped before the URL is stored, cached, or logged.
- **Only the fixed command list in PLAN.md §5 is ever spawned**, always as argument arrays through `Process`, never through a shell. A branch name beginning with `-` is passed as an operand, which a test pins. Beside `git` and `gh`, the shell layer runs `/usr/bin/open`, `/bin/launchctl` for the login-item fallback, `/usr/bin/xcode-select` to decide whether Apple's git shim will resolve, and `/bin/zsh` only through the sign-in script below. README's trust paragraph names that same list.
- **A hostname is a hostname before it is anything else.** `GitHubSlug.isValidHostname` applies an RFC-1123 label grammar at parse time, so a remote such as `ssh://git@$(touch pwned)/o/r` never produces a slug, a notice, an action payload, or a PR query (codex BLOCKER 1). Enterprise hosts pass; shell syntax does not.
- **The sign-in script is fixed text.** `SignInScript.render` writes a `.command` file whose only variable part is the resolved `gh` path, single-quoted. The hostname travels as *data* in the sibling file `gh-sign-in.host` (mode 0600), is read with a command substitution that never re-evaluates what it read, and is re-checked in zsh against the same grammar before `gh` is executed with it as one quoted argv element. Nothing a repository owns is ever interpolated into shell source.
- **PR links are https only, and only to a host BranchBar resolved.** `Actions.openPR` requires the scheme to be exactly `https` and the URL's host to equal the host of the repo section the link came from, so a `file:`, an `http:`, or a link to somewhere else is refused and logged rather than opened.
- **A cancelled or timed-out command takes its descendants with it.** Each child is spawned as its own process group leader, and termination signals the group, so `git`'s credential and lazy-fetch helpers cannot outlive the refresh that started them and keep its pipes open. `GIT_NO_LAZY_FETCH=1` is in the frozen git environment so a read never becomes a fetch.
- **Every read from outside the process is bounded.** Child stdout and stderr are drained in chunks against a byte cap; past it the partial output is dropped (a truncated `for-each-ref` would read as a short branch list, which is a lie), the child is terminated, and the caller gets `outputTooLarge`. Reflog files are read as a bounded tail, and a `.git` file is classified from a bounded prefix.
- **The cache is treated as untrusted input.** A cache file past a size cap loads as nil, dates in the future are dropped rather than believed, and the scan policy inside a loaded cache is never adopted as the policy to scan by: roots and depth come from the app, not from the file on disk.
- **No writes to any repo and no network calls of the app's own.** It never fetches, and every GitHub read goes through `gh` under the user's own token.
- **Launch at login registers only the copy the toggle names.** Both mechanisms refuse unless the running bundle is `/Applications/BranchBar.app`, so `SMAppService` cannot register a copy in Downloads while the LaunchAgent plist names Applications. A translocated bundle is refused outright.
- **Not sandboxed and ad-hoc signed.** macOS asks for folder access on the first scan, a denial is visible in the "Not scanned" row rather than silent, and a rebuilt copy asks again because the signature changes with every build.
- **Not defended against:** a hostile repo on disk beyond the above. Branch names are argument operands and displayed text, never executed.

## §8 Known footguns

**`%1f` is a `for-each-ref` format atom, not a general git format atom.**
In `git reflog show` and `git log` formats it emits the literal text `%1f`, so a parser splitting on U+001F sees one field. Use `%x1f` there. Found during plan review by executing the command; a fixture recorded from the wrong command would have made the wrong parser pass.

**`git reflog show --format=… -- <ref>` returns zero rows and exit 0.**
`reflog show` does not treat `--` as an end-of-options marker; the ref becomes a pathspec and matches nothing. Omit `--` for this command only. `for-each-ref -- refs/heads` does accept it.

**The GUI app PATH has no Homebrew.**
A launched `.app` sees `/usr/bin:/bin:/usr/sbin:/sbin`, so `gh` at `/opt/homebrew/bin` is invisible. `ToolLocator` searches known install locations explicitly and records where it looked.

**`open` forwards the calling shell's environment, so a terminal cannot test the GUI PATH.**
Launching the app from an interactive shell hands it that shell's PATH, Homebrew included, and the missing-tool path never reproduces. Test it as launchd does: `env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin open /Applications/BranchBar.app`.

**`%(upstream:track,nobracket)` is empty for two different reasons.**
An in-sync branch and a branch with no upstream both yield an empty field. Decide "no upstream" from `%(upstream:short)`, never from the track field.

**Reflog files can exist and be empty, and a push deletion looks like a push.**
`.git/logs/refs/remotes/origin/<branch>` may be zero bytes; `git push --delete` appends an `update by push` line whose new OID is all zeros; lines expire after 90 days. A usable push line is one with a non-zero new OID; anything else falls back to the tip commit date with wording that does not claim a push was observed.

**Reflog author names contain spaces, so the timestamp cannot be counted from the front.**
The header is `old OID, new OID, author name, email, unix time, timezone`, and the name is one or more words. Count the unix time and the timezone from the **end** of the header, which is what `ReflogFileReader.Entry` does.

**`gh pr list --json headRepositoryOwner` returns an object.**
Compare `.login`, not the value. `reviewDecision` is an empty string, not null, when no decision exists.

**`gh auth status` writes its report to stdout on gh 2.89.**
Older releases sent it to stderr, and the comment in `scripts/record-fixtures.sh` still says so. The script merges both streams into the fixture, so the recording is right either way, but code or a test that reads one stream by name will read the wrong one. Check the exit code, which is what `GHClient.authStatus` does.

**`Command.environment` merges over the inherited environment; the seam's doc comment says it replaces it.**
`ProcessCommandRunner` copies `ProcessInfo.processInfo.environment` and overlays the command's entries, which is what the frozen git and gh environments assume. The comment on `Command.environment` in `Sources/BranchBarCore/Seams/CommandRunner.swift` is the stale half of that pair, and the next packet that touches Core corrects it.

**A quarantined bundle is app-translocated, even out of `/Applications`.**
The process runs from `/private/var/folders/…/AppTranslocation/…`, so nothing may be derived from `Bundle.main.bundlePath` and `SMAppService` must refuse to register from a translocated copy. Removing `com.apple.quarantine` from the bundle root restores the real path. `SMAppService` itself works with the ad-hoc signature from `/Applications`, going `notFound` to `enabled` to `notRegistered` and never `requiresApproval`.

**Every `make install` re-signs with a new cdhash, so macOS asks for folder access again.**
TCC keys its grants to the code-signing identity, and an ad-hoc signature changes on every build. A rebuilt copy therefore re-prompts, and the "Not scanned" row reappears until the user answers. The README says so, and it is the argument for a stable signing identity if this ever ships more widely.

**A folder listing already blocked inside `open()` cannot be cancelled.**
`Task.isCancelled` is checked before each listing for exactly this reason: once the call is in the kernel behind a consent dialog, no deadline can end it. That is why the walk opens Desktop, Documents, and Downloads last and why `RealFileSystem` lists with resource values instead of calling `attributesOfItem` per entry.

**The Gatekeeper dialog's default button is Move to Trash.**
The first open of a downloaded copy shows "BranchBar" Not Opened with **Done** and **Move to Trash**, and Move to Trash is highlighted, so pressing Return deletes the app. Any instruction written for a tester has to say "click Done with the mouse".

**`screencapture` cannot see a menu bar status item.**
Layer-25 windows are absent from the capture, the clock and Control Center included, so a blank strip proves nothing. Prove the icon exists with `CGWindowListCopyWindowInfo` instead. `CGWindowListCreateImage` is obsoleted in the macOS 15 SDK, so the app captures its own popover with `cacheDisplay`.

**Two SwiftPM builds in one checkout block each other.**
Parallel agents sharing `.build` serialize on the build lock and can appear hung. Give each one `--scratch-path`.

**A `fatalError` stub traps the whole Swift Testing process.**
An `OWNER:` stub that traps takes down every test in the run, not just the one that called it, so a red packet reads as a crash rather than a failure list. Expect that shape while a packet is red.

**A string that becomes shell source is a different kind of string.**
The `gh` sign-in helper writes a `.command` file, and it used to build it by interpolating
`gh auth login --hostname \(host)` with `host` straight off `remote.origin.url`. A remote of
`ssh://git@$(touch pwned)/o/r` was therefore code execution on one click (codex BLOCKER 1). The
script is now fixed text; the hostname arrives as data in a sibling file, validated in Swift by
`GitHubSlug.isValidHostname` and again in zsh against the same grammar. Anything new that writes a
script follows the same shape, and lives in Core so a test can run it under a real shell.

**`launchctl bootstrap` reports "already loaded" as errno 5 or 37, not 17.**
`launchctl error 5|17|37` on macOS 24 prints "Input/output error", "File exists", and "Operation
already in progress"; the code that treated only 17 as benign deleted the plist it had just
written on every other code, while launchd kept the job loaded for the session. Check
`launchctl print gui/<uid>/<label>` for exit 0 first, and on a `bootstrap` failure `bootout` and
retry once rather than removing the file.

**`attributesOfItem` blocks behind a folder-access dialog, and so does anything that stats a
symlink's target.**
The first hung the whole first launch. `RealFileSystem` lists once with `.isDirectoryKey` and
`.isSymbolicLinkKey` resource values and stats nothing per entry, which also stops the walk
following a link out of the tree it was told to stay in.

**A `~/.git` at the home root used to end the scan there.**
The `.git` check runs before a directory's children are enqueued, so the dotfiles-in-home pattern
made `~` the one candidate and hid every real repo beneath it, with no message saying why. The home
root is now listed as a repo and still walked; an "Add folder…" root that is a repo keeps the plain
"do not descend" rule.

**Never add `resources:` to `Package.swift`, and never add a `main.swift`.**
A resource declaration makes SwiftPM emit a side bundle next to the executable that breaks the `.app` layout and signing; a `main.swift` disables `-parse-as-library` and breaks `@main`. Fixtures load via `#filePath`; the entry file is `BranchBarApp.swift`.
