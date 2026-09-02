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
        RC --> SR[ScanRunning seam: 20 s scan deadline]
        SR --> IPS[InProcessScanRunner: tests and the CLI]
        SR --> HPS[HelperProcessScanRunner: the app, killable]
        IPS --> SC[RepoScanner: BFS depth 6, hidden dir and literal skip list, dedupe]
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
        HPS --> HELPER[/branchbar-cli scan: BranchBar's own code, in Contents MacOS, NDJSON on stdout, killable/]
        HELPER --> SC
        FS --> HOME[/home folder: TCC gated/]
    end
```

The app holds no credentials. `gh` authenticates itself from its own keyring; BranchBar reads only its stdout. Three protocols (`CommandRunner`, `FileSystem`, `CacheStore`) are the only routes to the outside world, and tests replace all three.

Discovery crosses the process boundary a fourth way, and it is the one place BranchBar spawns its own code: `HelperProcessScanRunner` runs `branchbar-cli scan` from `Contents/MacOS`, because a directory listing already blocked inside the kernel cannot be cancelled by any task above it while a process can always be killed. The helper streams NDJSON as it walks, so a kill costs the folders it had not reached and not the repos it had already found. `ScanRunning` is the seam that keeps that out of every other caller: unit tests and the CLI's own `snapshot` path run the same walk in process.

## §2 Key flows

Five mechanisms someone has to understand before editing safely. A diagram changes in the same commit as the code it describes.

### §2.1 One refresh

Coalescing, the bounded scan, the concurrency cap, progressive emits, and the lazy `gh` fetch, all owned by `RefreshCoordinator`.

```mermaid
sequenceDiagram
    autonumber
    participant UI as AppModel
    participant RC as RefreshCoordinator
    participant SR as ScanRunning
    participant HP as branchbar-cli scan
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
            RC->>SR: scan(policy) under the 20 s scan deadline
            SR->>HP: Spawn with the policy as JSON and a soft deadline at 0.75 of it
            HP-->>SR: NDJSON as it walks: repo, unreadable, entering, skipped
            alt The walk finishes
                HP-->>SR: A final result line, which is the whole answer
            else The soft deadline arrives
                HP-->>SR: The repos found so far, then exit
            else The hard deadline arrives
                SR->>HP: SIGTERM then SIGKILL to the helper's process group
                SR->>SR: Assemble the lines that arrived, mark the result truncated, name the folder it was entering as not scanned
            end
            SR-->>RC: ScanResult, truncated whenever it is not the whole truth
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
    H -->|"No"| J["originMovedSince. Row adds (remoteName has moved since), naming the remote the comparison actually used"]
    F --> K{"Does the remote-tracking tip carry a commit date?"}
    K -->|"Yes: remoteTipCommitDate, which is what origin holds and not the local tip"| L["Row reads Last push unknown · newest commit dated 2 days ago"]
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
    Z["RefreshCoordinator asks ScanRunning for a scan"] --> Z1{"Which runner?"}
    Z1 -->|"The app: HelperProcessScanRunner"| Z2["Spawn branchbar-cli scan, which runs this same walk and prints one NDJSON line per event as it goes"]
    Z1 -->|"Tests and the CLI: InProcessScanRunner"| A
    Z2 -->|"Inside the helper: the same walk"| A
    Z2 -->|"On this side: read the stream, then"| Z3{"Did a final result line arrive?"}
    Z3 -->|"Yes"| Z4["That line is the whole answer: counts, skip lists, truncated false"]
    Z3 -->|"No, the helper was killed"| Z5["Assemble the repo and unreadable lines that did arrive, mark the result truncated, and add the folder named by the last entering line to unreadableDirectories"]
    Z3 -->|"No lines at all"| Z6["An empty truncated result, which the coordinator refuses so the next refresh walks again"]
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
    S --> I["Dedupe by git rev-parse --git-common-dir inside the walk, keeping the working tree whose .git is a real directory, and emit the repo line then"]
```

**A home folder that is itself a repo does not end the walk.** `git init` in `$HOME` with a `*`
gitignore is the dotfiles pattern, and the `.git` check runs before a directory's children are
enqueued, so `~/.git` made `~` the one and only candidate: every real repo under home invisible,
the empty state suppressed because one repo was listed, and nothing on screen saying why (REVIEW
WR-08). The home root is now listed as a repo **and** walked. An "Add folder…" root that is a repo
keeps the plain rule: the user pointed at that folder, so they get that repo, and a nested one is
another "Add folder…" away.

**Every read the walk makes is bounded, none of them stats a symlink, and none of them opens a
special file.** A `.git` file is repository-controlled, so it is classified from a bounded prefix
rather than read whole (codex MAJOR 15). `RealFileSystem` lists once with `.isDirectoryKey` and
`.isSymbolicLinkKey` resource values: no `attributesOfItem` per entry, which blocks behind a
folder-access dialog, and no `stat` of a symlink's target, which used to follow a link out of the
tree the walk was told to stay in. Every bounded read then goes through
`RealFileSystem.readBoundedRegularFile`, which opens with `O_RDONLY | O_NOFOLLOW | O_NONBLOCK |
O_CLOEXEC`, requires `S_IFREG`, and `pread`s (codex round 2, BLOCKER 2): a `.git` symlink pointing
at a FIFO, or a FIFO left where a reflog or the cache belongs, blocked `open()` for the life of
the process, and no timeout above a blocked `open()` can end it. A `.git` symlink is never opened
at all, and a directory entry whose type is neither file nor directory marks its parent unreadable
rather than being opened to find out what it is.

**Three bounds sit on top of the walk, and they answer different questions.** `Task.isCancelled` is
checked before each listing, which is the only place cancellation can land, and the gated folders
going last is what keeps an unanswered consent dialog from blocking everything else. Neither
reaches a listing already inside `open()`: that task never gets back to the check, and racing it
in a task group and returning would leak a permanently blocked thread rather than fix anything.
So the app runs the walk in the `branchbar-cli` helper, where the third bound is a signal rather
than a flag. `HelperProcessScanRunner` gives the helper a **soft** deadline at 0.75 of the scan
deadline, which is the helper's own copy of the cooperative race and the case where a partial
answer exists on its own; the **hard** bound is `Command.timeout`, which `ProcessCommandRunner`
turns into SIGTERM and then SIGKILL to the helper's process group.

**A kill is the expected ending, so the helper streams.** Packet F10 measured what a
one-document helper was worth on a real first launch: three launches, 21 seconds each, `repos: 0`,
while the same helper run from Terminal found 25 repos in 1.2 s. The walk had found them all — the
gated folders go last — and every one of them died with the process, because a thrown timeout
carries no bytes. Now each event is an NDJSON line flushed as it happens, the dedupe runs inside
the walk so a repo is published the moment it is claimed, and `runCollectingPartialOutput` keeps a
killed child's stdout. What arrived is assembled into a `ScanResult` marked `truncatedByDeadline`,
which `RefreshCoordinator` refuses as a finished scan so the next refresh walks again, while the
user still sees the repos that were found and a "Not scanned" row for the folder the helper was
inside when it died.

### §2.4 How a branch gets its PR pill

```mermaid
graph TD
    A{"Is the repo expanded, or in the launch top 5?"} -->|"No"| A1["prLoadState notLoaded. Pill reads PR status loads when expanded"]
    A -->|"Yes"| O["Resolve the owner of every remote a branch tracks: origin from the slug, every other name from one git config --get remote name url"]
    O --> N{"Is the host github.com, or a host gh auth status lists a login for?"}
    N -->|"No"| N1["Unavailable: notGitHubRemote. No gh process runs and this host is never offered as a sign-in target"]
    N -->|"Yes"| B{"Is the PR cache newer than 10 min?"}
    B -->|"Yes"| B1["Serve the cached PRs and the cached coverage, issue no gh call"]
    B -->|"No"| C["gh auth status --hostname, per host, memoized for the refresh"]
    C -->|"Non-zero exit"| C1["Unavailable: ghNotAuthenticated for every repo on that host"]
    C -->|"Cancelled or timed out"| C2["Not a verdict about the account: the memo is dropped so the next repo asks again"]
    C -->|"Exit 0"| D["gh pr list --state all --limit 100"]
    D -->|"401 or Bad credentials"| D0["Unavailable: ghNotAuthenticated. Signing in again is the fix"]
    D -->|"GitHub's own rate-limit wording, or 429"| D1["Unavailable: rateLimited. Waiting really does fix it"]
    D -->|"Any other 403"| D3["Unavailable: forbidden. The copy names the repo the request asked for"]
    D -->|"The runner's own timeout"| D4["Unavailable: timedOut"]
    D -->|"Anything else, 404 included"| D2["Unavailable: commandFailed, worded neutrally, showing one sanitized stderr line. The per-head and author calls are skipped"]
    D -->|"Rows"| E["Record each returned PR as an owner and head pair in PRQueryCoverage.ownedHeads"]
    E --> F{"Does a local branch still have no PR?"}
    F -->|"Yes"| G["gh pr list --head, most recently active first, capped at 20 per repo. That head goes in anyOwnerHeads: the query filters on the branch, not on who owns it"]
    F -->|"No"| H
    G --> H["Match by headRefName, so a fork PR opened from this branch is never filtered out"]
    H --> I{"Does this branch's own owner claim that head?"}
    I -->|"No, or the owner is unresolved"| K
    I -->|"Yes, and several qualify"| I1["Break the tie: an OPEN state first, then the latest updatedAt"]
    I -->|"Yes, exactly one"| J["Map the state: MERGED, CLOSED, draft, APPROVED, CHANGES_REQUESTED, else open"]
    I1 --> J
    B1 --> K{"Does the coverage hold this owner and head pair, or this head under any owner?"}
    J --> K
    K -->|"Yes, and no PR came back"| K1["Status none. Pill reads No PR"]
    K -->|"No: past the cap, collapsed, cut by the deadline, or no owner to have asked about"| K2["Status notChecked. Pill reads PR status not checked yet"]
    D --> L["gh pr list --state open --author @me. Any PR whose owner login and head branch match no local branch becomes Open PRs not on this Mac"]
```

`queriedHeads` is the field that keeps `none` and `notChecked` apart across a relaunch: a `Repo` alone cannot say which heads were asked about.

**A head is an (owner, branch) pair, and coverage is keyed that way** (codex round 2, MAJOR 4). `stranger:main` and `tester:main` are two different heads, and the recent-100 list answers for the pairs it names and for nothing else. Recording bare names meant a stranger's PR on `main` marked `main` queried, the per-head query for the user's own `main` was skipped, the stranger's PR was then correctly rejected as a match, and the row read "No PR" beside an open pull request. `PRQueryCoverage` therefore keeps two sets: `ownedHeads`, the pairs the recent-100 list named, and `anyOwnerHeads`, the heads a `--head` query asked about, which does answer for every owner because it filters on the branch. Owner logins are held lower-cased, since GitHub logins are case-insensitive and `gh` prints whatever casing the account was created with. A branch whose owner is unresolved is covered by nothing: with no owner there is no head to have asked about, and `none` would claim an answer nobody has.

**Which owner a branch has is looked up per remote** (codex round 2, MAJOR 4). Origin's owner comes from the slug `RepoLoader` already read; every other remote a branch tracks costs one `git config --get remote.<name>.url`, issued once per distinct name and carried on `Repo.remoteOwners`. Without it a branch tracking a fork fell back to the origin repository's owner, which is a different head that happens to share a name. `RepoLoader` needs the runner and the git path at **both** its construction sites for this to work at all, which is what packet F10 found: the app's own path built a loader without them, so every non-origin owner silently stayed unresolved.

**Owner is a constraint, not a tie-break** (codex MAJOR 9). Matching on `headRefName` alone was right for a fork PR opened from a branch that really is yours, and wrong for the commoner case where exactly one candidate came back: somebody else's fork carrying a branch of the same popular name (`main`, `fix-typo`) attached itself to your local branch, and the row reported a stranger's review state as yours. A branch may claim a PR head only from the owner it can prove: the upstream's owner login when it tracks a remote this app resolved a slug for, and otherwise the repo's own slug owner, which is the only owner an untracked branch could plausibly have. A single candidate from any other owner is no longer a match, and the branch renders `No PR` rather than someone else's pull request. State and `updatedAt` order only the candidates that already passed the owner test.

**The failure copy no longer asserts a cause the data cannot support** (REVIEW WR-02, codex round 2 MAJOR 11). `.rateLimited` requires GitHub's own rate-limit wording or a 429, because an enterprise returns HTTP 403 for SAML enforcement, a missing token scope, and IP allow-list denials, none of which waiting fixes. Those 403s are `.forbidden(repo:)`, whose copy repeats back the `host/owner/name` the request named. Only a 401, a "Bad credentials" body, or `gh`'s own "not logged in" is `.ghNotAuthenticated`, since signing in again is the fix for exactly those. The runner's own timeout is `.timedOut`, the one failure whose copy may say the CLI did not answer in time. Everything left, a repo `gh` cannot resolve included, is `.commandFailed` with neutral copy plus one sanitized stderr line, which is the single relaxation of the rule that a diagnostic is never rendered.

**A host BranchBar has no reason to believe is GitHub never reaches a `gh` process** (codex round 2, MAJOR 6). `github.com` is trusted outright; every other host has to appear in a `Logged in to <host>` line of one `gh auth status` run per refresh, judged by its output rather than its exit code because `gh` exits non-zero when any configured host is logged out while still listing the ones that are not. Anything else gets the answer a `file://` remote gets — "not on GitHub" — and is never offered as a sign-in target.

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
    P43 --> P52["5.2 Docs as deliverables"]
    P52 --> CX1{{"codex pre-ship challenge: DO NOT SHIP, 2 blockers"}}
    CX1 --> W1["Fix wave: F1 hosts and the sign-in script, F2 honest claims, F3 bounded reads and process groups, F4 docs re-derived, F5 empty-state action"]
    W1 --> CX2{{"codex round 2: DO NOT SHIP, 3 blockers"}}
    CX2 --> W2["Second wave: F6 killable scan helper and special-file guards, F7 owner-keyed PR coverage and honest failure reasons, F8 verified login item"]
    W2 --> W3["F10 loader owners wired and footer Cancel, F11 streaming NDJSON scan, F12 lenient decoders"]
    W3 --> F9["F9 Docs re-derived after the second wave"]
    F9 --> CX3{{"codex round 3: required to return no blocker"}}
    CX3 --> P51B["5.1b Packaging hardening, v0.9.1 then v1.0.0"]
    G5 --> P51B
    P51B --> G5B{{"Gate 5b: a second user installs from the README alone"}}
```

The two fix waves are not a detour around the gates; they are what the gates are for. `v0.9.0` was cut from 5.1a, held as a superseded pre-release, and never sent to the NYT tester, because the pre-merge codex challenge found a remote URL that reached a shell. Every packet from F1 on names the finding it closes in PLAN.md §8.

## §3 Anatomy

One row per concern, each pointing at the line that declares it. `make doc-refs` reads this table and fails on any row whose line no longer holds its symbol, so an edit pass that shifts line numbers cannot land silently.

| Concern | Symbol | Declared at | Notes |
|---|---|---|---|
| **Core: the refresh** | | | |
| One refresh end to end: coalescing, cap 4, 45 s deadline, progressive emit, atomic persist | `RefreshCoordinator` | `Sources/BranchBarCore/RefreshCoordinator.swift:16` | An actor, so a second popover open coalesces instead of starting a parallel walk |
| Discovery run inside a bound so a pending folder-access dialog cannot hang a refresh | `scanWithinDeadline` | `Sources/BranchBarCore/RefreshCoordinator.swift:394` | Takes the scanner's partial result when the 20 s bound wins, and rescans next time |
| Repo order computed once per refresh and never recomputed mid-flight | `stableOrder` | `Sources/BranchBarCore/RefreshCoordinator.swift:481` | Previous snapshot's activity first, then new repos alphabetically |
| How the last refresh ended, so a cancel is not reported as a completed update | `RefreshOutcome` | `Sources/BranchBarCore/RefreshCoordinator.swift:5` | A cancelled refresh keeps the previous `refreshedAt` and suppresses follow-ups |
| One repo end to end: seven stages, each failure isolated into a `RepoError` | `RepoLoader` | `Sources/BranchBarCore/RepoLoader.swift:8` | Never throws, so one broken repo leaves the others populated |
| Pure join of git and GitHub facts into a `Repo`, and the three groups | `RepoAssembler` | `Sources/BranchBarCore/RepoAssembler.swift:9` | Grouping is decided here and only rendered by the presenter |
| **Core: git** | | | |
| Every frozen git invocation, with the frozen environment and per-command timeouts | `GitClient` | `Sources/BranchBarCore/GitClient.swift:6` | `LC_ALL=C` and `GIT_OPTIONAL_LOCKS=0` live in `frozenEnvironment` |
| Branch and remote-ref rows split on U+001F | `ForEachRefParser` | `Sources/BranchBarCore/ForEachRefParser.swift:65` | "No upstream" is decided from `upstream:short`, never from the track field |
| Worktree records, including the ones with no branch | `WorktreeListParser` | `Sources/BranchBarCore/WorktreeListParser.swift:11` | Primary, linked, detached, locked, prunable, bare |
| The reflog file read, the deletion boundary, and the usable-line predicate | `ReflogFileReader` | `Sources/BranchBarCore/ReflogFileReader.swift:8` | Walks newest first and stops at the first all-zero new OID |
| One reflog line, with fields counted from the end of the header | `Entry` | `Sources/BranchBarCore/ReflogFileReader.swift:96` | Author names carry spaces, so field 5 cannot be counted from the front |
| The `git reflog show` fallback parser: implemented, unused in production | `ReflogParser` | `Sources/BranchBarCore/ReflogParser.swift:25` | Kept for the `--` footgun: a live-repo test and `make record-fixtures` both pin the invocation |
| Push facts, and the rule that a commit date is never presented as a push | `PushInfoDeriver` | `Sources/BranchBarCore/PushInfoDeriver.swift:8` | No upstream yields a nil ahead count, never zero |
| The git version gate behind the "works best with 2.39" notice | `GitVersion` | `Sources/BranchBarCore/GitVersion.swift:11` | Parsed from `git --version`, Apple's build suffix included |
| **Core: GitHub** | | | |
| Every `gh` invocation, per-host auth memoized, per-head cap, list caches | `GHClient` | `Sources/BranchBarCore/GHClient.swift:8` | An actor: the auth answer and the list caches are shared across repos on a host |
| The `--json` field list shared by all three `gh pr list` invocations | `jsonFields` | `Sources/BranchBarCore/GHClient.swift:72` | Changing it means re-recording the fixtures |
| PR JSON decode, including `headRepositoryOwner` as an object | `PRListDecoder` | `Sources/BranchBarCore/PRListDecoder.swift:8` | Sorted by `updatedAt` descending whatever order `gh` returned |
| PR to pill, branch to PR, and the "not on this Mac" key | `PRStatusMapper` | `Sources/BranchBarCore/PRStatusMapper.swift:14` | Head first, owner required not preferred, keyed by owner and branch |
| Which heads a refresh actually asked GitHub about, as (owner, head) pairs | `PRQueryCoverage` | `Sources/BranchBarCore/Models/PRStatus.swift:128` | An unresolved owner is covered by nothing, so the row reads `notChecked` |
| The `.command` file the sign-in action hands Terminal, as fixed text | `SignInScript` | `Sources/BranchBarCore/SignInScript.swift:25` | In Core so a test can render it and run it under a real zsh |
| The one variable part of that script, single-quoted: the resolved `gh` path | `render` | `Sources/BranchBarCore/SignInScript.swift:43` | The hostname is data in a sibling file, never script text |
| **Core: discovery** | | | |
| The seam that decides *where* the walk runs, so a deadline has something it can end | `ScanRunning` | `Sources/BranchBarCore/ScanRunner.swift:20` | A blocked listing cannot be cancelled; a process can be killed |
| The same walk in this process: every unit test and the CLI's own path | `InProcessScanRunner` | `Sources/BranchBarCore/ScanRunner.swift:28` | The default wherever no killable helper is available |
| The walk in the bundled helper, assembled from whatever the stream delivered | `HelperProcessScanRunner` | `Sources/BranchBarCore/ScanRunner.swift:145` | Soft deadline at 0.75, then SIGTERM and SIGKILL to the helper's group |
| One line of the helper's NDJSON stream | `ScanStreamLine` | `Sources/BranchBarCore/ScanRunner.swift:85` | A line that will not decode is skipped and costs that line only |
| One walk event, published the moment it happens rather than at the end | `ScanEvent` | `Sources/BranchBarCore/RepoScanner.swift:40` | `repo` fires when the dedupe claims it, `entering` before each gated listing |
| The home walk to depth 6 and the unlimited walk of added roots | `RepoScanner` | `Sources/BranchBarCore/RepoScanner.swift:80` | Breadth-first, no symlinks, never descends into a repo it found |
| The three folders macOS gates, enumerated after everything else | `tccGatedFolderNames` | `Sources/BranchBarCore/RepoScanner.swift:176` | Desktop, Documents, and Downloads as children of the home root only |
| `.git` file classification into worktree checkout, submodule, or candidate | `classifyGitFile` | `Sources/BranchBarCore/RepoScanner.swift:182` | A checkout's common directory is everything before `/worktrees/` |
| Tool discovery for a GUI process whose PATH has no Homebrew | `ToolLocator` | `Sources/BranchBarCore/ToolLocator.swift:54` | Env override, then four install locations, then PATH, then Apple git |
| **Core: presentation** | | | |
| `Snapshot` to view models, the only place a user-facing sentence is built | `SnapshotPresenter` | `Sources/BranchBarCore/SnapshotPresenter.swift:50` | Six frozen arguments; `EditorAvailability` is an initializer property |
| Every user-facing literal, one static member per string | `Strings` | `Sources/BranchBarCore/Strings.swift:27` | `make doc-strings` regenerates the UI-CONTRACT table from its doc comments |
| **Core: seams** | | | |
| The process seam every git and gh call passes through | `CommandRunner` | `Sources/BranchBarCore/Seams/CommandRunner.swift:90` | Argument arrays only, never a shell string |
| The real process implementation: concurrent draining, timeout, cancellation | `ProcessCommandRunner` | `Sources/BranchBarCore/ProcessCommandRunner.swift:5` | Both pipes drain on dedicated threads, then SIGTERM and SIGKILL |
| Termination that reaches the child's helpers, not just the child | `signalGroup` | `Sources/BranchBarCore/ProcessCommandRunner.swift:404` | pgid captured at spawn and signalled whichever process leads it |
| A killed child's output kept beside the reason it stopped | `PartialOutputCommandRunning` | `Sources/BranchBarCore/ScanRunner.swift:75` | Only for a stream of independent lines; a truncated document is a lie |
| The filesystem seam for the scan, the reflog files, and the cache | `FileSystem` | `Sources/BranchBarCore/Seams/FileSystem.swift:53` | Synchronous by contract; the scan's bound lives one level up |
| The real filesystem, listing once with resource values | `RealFileSystem` | `Sources/BranchBarCore/RealFileSystem.swift:16` | No per-entry `attributesOfItem`: that call blocks behind folder-access dialogs |
| The only way anything repository-owned is read | `readBoundedRegularFile` | `Sources/BranchBarCore/RealFileSystem.swift:275` | `O_NOFOLLOW`, `O_NONBLOCK`, an `S_IFREG` check, then `pread`: a FIFO cannot block it |
| Control scalars escaped before anything reaches CLI output or the log | `SafeText` | `Sources/BranchBarCore/BranchBarCore.swift:21` | A branch or folder name cannot forge a log entry or retitle a terminal |
| The cache seam | `CacheStore` | `Sources/BranchBarCore/Seams/CacheStore.swift:6` | Two methods, both replaced in tests |
| The cache file on disk, written through a temp file | `FileCacheStore` | `Sources/BranchBarCore/FileCacheStore.swift:7` | `replaceItemAt`, so an interrupted save leaves the previous file intact |
| **Core: data model** | | | |
| One repo, its branches, worktrees, PR availability, and errors | `Repo` | `Sources/BranchBarCore/Models/Repo.swift:151` | Identified by `RepoID`, the git common directory |
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
| The menu bar entry point | `BranchBarApp` | `Sources/BranchBar/BranchBarApp.swift:585` | `MenuBarExtra` in `.window` style, which re-runs `onAppear` per open |
| Accessory activation, logging, and the state-fixture harness | `AppDelegate` | `Sources/BranchBar/BranchBarApp.swift:11` | `LSUIElement`, so there is no Dock icon and no menu bar menu |
| Published view models, the refresh trigger, collapse, hide, roots | `AppModel` | `Sources/BranchBar/AppModel.swift:29` | The only shell type that talks to Core |
| Row actions: editor chain, PR, Finder, clipboard | `Actions` | `Sources/BranchBar/Actions.swift:12` | Cursor, then VS Code, then Terminal; `https` PR links only |
| Launch at login | `LaunchAtLogin` | `Sources/BranchBar/LaunchAtLogin.swift:19` | `SMAppService` verified after bootstrap with `launchctl print`; refuses a translocated bundle |
| The guard that stops the toggle registering a copy the login item does not name | `isRunningFromApplications` | `Sources/BranchBar/LaunchAtLogin.swift:187` | Both mechanisms refuse outside `/Applications` and `~/Applications`, so they cannot name two bundles (REVIEW WR-05, codex round 2 MAJOR 10) |
| The popover body and keyboard traversal | `RootView` | `Sources/BranchBar/Views/RootView.swift:22` | Arrow keys traverse, Return runs the primary action, Escape dismisses |
| One repo section with its four groups | `RepoSectionView` | `Sources/BranchBar/Views/RepoSectionView.swift:7` | Collapse state is persisted per repo |
| One branch row | `BranchRowView` | `Sources/BranchBar/Views/BranchRowView.swift:7` | Worktree marker, name, pill, push line, ahead count |
| The PR pill and its ten colors | `PRPillView` | `Sources/BranchBar/Views/PRPillView.swift:9` | Color plus text, never an emoji |
| The footer: last updated, version, tool notice | `FooterView` | `Sources/BranchBar/Views/FooterView.swift:6` | Also the scan roots and the hidden-repo count |
| Width, row height, and type scale | `Metrics` | `Sources/BranchBar/Views/Tokens.swift:9` | Width 340, max height 70 percent of the screen |
| **CLI** | | | |
| The two subcommands: the harness and the app's discovery helper | `Subcommand` | `Sources/branchbar-cli/main.swift:29` | `scan` is what `Contents/MacOS/branchbar-cli` is spawned for |
| `branchbar-cli snapshot` argument parsing | `Options` | `Sources/branchbar-cli/main.swift:34` | The Gate 3 harness and the Gate 0b fallback |
| The runner the CLI hands its cache-only bootstrap | `NoCommandsRunner` | `Sources/branchbar-cli/main.swift:350` | Keeps the harness from writing over the app's own cached snapshot |

## §4 Data model

Frozen in PLAN.md §5, and every type is `Hashable, Codable, Sendable`. State is mutated only through `RefreshCoordinator`.

The cache lives at `~/Library/Application Support/BranchBar/cache.json` and holds `CacheFile`: the last scan, manually added roots, hidden and collapsed repo ids, the per-repo `PRCacheEntry`, and the last `Snapshot`. Two rules govern it.

- **Atomic replace.** `FileCacheStore` writes a temp file and calls `replaceItemAt`, so a save interrupted halfway leaves the previous cache intact.
- **Unknown schema loads nil.** `CacheFile.currentSchemaVersion` is 1; a file carrying anything else is discarded rather than decoded field by field, so a downgrade shows an empty list and rescans instead of half a state.
- **Every field added after the 1.1 freeze is read with `decodeIfPresent`, by hand.** A synthesized `init(from:)` calls `decode(_:forKey:)` for every non-optional stored property and never consults that property's default, so a field added later was a *required* key: `PRCacheEntry.queriedHeads` missing threw `keyNotFound`, the enclosing `CacheFile` failed with it, and `load` returned that as "no cache" — a cold rescan and an empty popover on the first launch after the upgrade that added it. Eight types therefore carry an explicit decoder (`PRCacheEntry`, `ScanResult`, `Repo`, `PushInfo`, `RefreshPolicy`, `RepoSectionVM`, `BranchRowVM`, `EmptyStateVM`): keys frozen in 1.1 stay required, so a file of the wrong shape is still not a cache, and only the added keys are optional. `encode` stays synthesized. `CacheCompatibilityTests` loads a 1.1-era `cache.json` fixture, which is the regression this cost.

Three derived fields exist because a `Repo` alone cannot answer the question honestly. `PRCacheEntry.queriedHeads` records which branch heads a fetch actually asked about, which is what keeps `PRStatus.none` and `PRStatus.notChecked` apart across a relaunch. `ScanResult.truncatedByDeadline` records that a walk was cut short, which is what stops a partial repo list from being cached as if it were complete. `Repo.remoteOwners` records which owner each upstream remote resolved to, so the shell can say which fork a row was counted against rather than reconstructing it from whichever PRs happened to match.

## §5 Testing

```bash
make test        # swift test --disable-xctest --enable-swift-testing
```

**378 tests, all green.** Swift Testing only: XCTest is absent under Command Line Tools, and `noXCTestImportAnywhere` keeps it out on a machine that has full Xcode. `noAppKitOrSwiftUIImportInCore` keeps the shell's frameworks out of the library.

Fixtures live in `Tests/BranchBarCoreTests/Fixtures/` in four families. `recorded-*` (26 files) are byte-exact output from `/usr/bin/git` 2.39.5 and `gh` 2.89.0, written by `make record-fixtures`: no model ever transcribes git output. `synthetic-*` (25 files) are hand-written extensions for cases these repos cannot produce, each with a sibling `.md` note explaining what it models. `states/*.json` (45 files) are one per user-facing state in `docs/UI-CONTRACT.md`, each carrying the exact arguments of `SnapshotPresenter.present` plus the strings that state must show. `cache-1.1-era.json` is a `cache.json` in the shape the 1.1 freeze wrote, kept so every field added since has to keep loading it.

Two test suites run a real process. `SignInScriptTests` renders the `gh` sign-in `.command` file and executes it under `zsh` with a hostile `gh-sign-in.host` beside it, because the only proof that a script refuses a hostname is the shell refusing it. `ScanRunnerTests` spawns a real helper stub through `ProcessCommandRunner` and lets the deadline kill it, because the claim under test is that a killed child's stdout survives, and only a real kill can show that.

Two tests touch a real repo, and both skip themselves with a recorded reason rather than failing: `everyFrozenGitInvocationReturnsOutputOnThisRepo` skips when `git` is absent, and `reflogShowFallbackReturnsRowsForARefThatHasPushes` skips when this checkout's own `origin/main` reflog holds no push line, which is exactly what CI has, since a CI clone fetches and never pushes. Everything else replaces all three seams and touches no network, no real repo, and no home folder.

`docs/TEST-PLAN.md` maps every named invariant from PLAN.md §7 to the file that holds it.

## §6 Operations

- **Launch path:** `/Applications/BranchBar.app`, or `~/Applications/BranchBar.app` on an account that cannot write the main one; menu bar only (`LSUIElement`), no Dock icon and no menu bar menu of its own.
- **What is in the bundle:** two signed executables in `Contents/MacOS`. `BranchBar` is the app; `branchbar-cli` is the discovery helper it spawns, signed first as `com.hannahstulberg.branchbar.cli` because the app's own signature seals the bundle around it. `make verify` fails when the helper is missing, since an app without it silently falls back to the in-process scan that no deadline can kill.
- **Logs:** `~/Library/Logs/BranchBar/BranchBar.log` (`make logs` tails it) and `log stream --predicate 'subsystem == "com.hannahstulberg.branchbar"'`. An empty log after a first open means the user is still at the Gatekeeper dialog: the process is held before `applicationDidFinishLaunching` runs.
- **Headless snapshot:** `make snapshot ROOTS="~/one ~/two"` runs `branchbar-cli snapshot`, which prints every repo, branch, worktree, PR, and push as a table, or as JSON with `--json`. It is the Gate 3 harness, the way to reproduce a user's list without the UI, and the fallback if the menu bar app is ever blocked on a managed Mac. `BRANCHBAR_GIT` pins the git binary.
- **State screenshots:** `scripts/screenshot-states.sh` renders every `states/*.json` fixture through the real app.
- **Runbooks:** `docs/runbooks/gate-0b-nyt-spike-test.md` is the tester-facing install checklist the README's install steps mirror; `docs/runbooks/quarantine-rehearsal.md` holds the Gatekeeper and app-translocation findings with the exact commands.

## §7 Security contract

- **No secrets stored, read, or logged.** `gh` authenticates itself from its own keyring and BranchBar reads only its stdout. A `GH_TOKEN` exported in a shell rc is invisible to a GUI app, so it is not a supported setup. A remote URL that carries credentials in its userinfo (`https://user:token@host/o/r`) has them stripped before the URL is stored, cached, or logged.
- **Only the fixed command list in PLAN.md §5 is ever spawned**, always as argument arrays through `Process`, never through a shell. A branch name beginning with `-` is passed as an operand, which a test pins. Beside `git` and `gh`, the shell layer runs `/usr/bin/open`, `/bin/launchctl` for the login-item fallback, `/usr/bin/xcode-select` to decide whether Apple's git shim will resolve, and `/bin/zsh` only through the sign-in script below. One entry on that list is BranchBar's own code: `Contents/MacOS/branchbar-cli`, the discovery helper, resolved from the **running executable's** directory rather than `Bundle.main.bundlePath`, which is an App Translocation mirror for a quarantined copy. README's trust paragraph names that same list, the helper included.
- **A hostname is a hostname before it is anything else.** `GitHubSlug.isValidHostname` applies an RFC-1123 label grammar at parse time, so a remote such as `ssh://git@$(touch pwned)/o/r` never produces a slug, a notice, an action payload, or a PR query (codex BLOCKER 1). Enterprise hosts pass; shell syntax does not.
- **The sign-in script is fixed text.** `SignInScript.render` writes a `.command` file whose only variable part is the resolved `gh` path, single-quoted. The hostname travels as *data* in the sibling file `gh-sign-in.host` (mode 0600), is read with a command substitution that never re-evaluates what it read, and is re-checked in zsh against the same grammar before `gh` is executed with it as one quoted argv element. Nothing a repository owns is ever interpolated into shell source.
- **A host is GitHub only if BranchBar can show why.** `github.com`, or a host `gh auth status` lists a login for. Everything else is "not on GitHub": no `gh` process runs against it, and it is never offered as a sign-in target (codex round 2, MAJOR 6).
- **PR links are https only, and only to a host BranchBar resolved.** `Actions.openPR` requires the scheme to be exactly `https` and the URL's host to equal the host of the repo section the link came from, so a `file:`, an `http:`, or a link to somewhere else is refused and logged rather than opened.
- **A cancelled or timed-out command takes its descendants with it.** Each child is spawned as its own process group leader, and termination signals the group, so `git`'s credential and lazy-fetch helpers cannot outlive the refresh that started them and keep its pipes open. `GIT_NO_LAZY_FETCH=1` is in the frozen git environment so a read never becomes a fetch.
- **Every read from outside the process is bounded, and none of them can block.** Child stdout and stderr are drained in chunks against a byte cap; past it the partial output is dropped (a truncated `for-each-ref` would read as a short branch list, which is a lie), the child is terminated, and the caller gets `outputTooLarge`. A pipe that could not be read through is `readFailed`, which is distinct from a command that failed and says nothing about the account it was asking about. Reflog files are read as a bounded tail and a `.git` file from a bounded prefix, both through `RealFileSystem.readBoundedRegularFile`: `O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC`, an `S_IFREG` check, then `pread`. A `.git` symlink is never opened at all. Without this a `.git` symlink to a FIFO, or a FIFO where a reflog or the cache belongs, blocked `open()` for the life of the process, and nothing above a blocked `open()` can end it (codex round 2, BLOCKER 2).
- **Discovery runs where a deadline can reach it.** The same reasoning one level up: a directory listing already inside `open()`/`readdir()` cannot be cancelled by any task above it, so the app walks in the `branchbar-cli` helper and the scan deadline becomes SIGTERM then SIGKILL to that helper's process group. The helper's stream is parsed as data, not trusted as a report: a line that does not decode is skipped and costs that line only, so no folder on this Mac can empty the repo list by being named oddly. Every control scalar in CLI output and in a log line is escaped, and the log is capped at 5 MB by keeping its newest bytes, so a branch or folder name cannot forge a log entry or retitle a terminal.
- **The cache is treated as untrusted input.** A cache file past a size cap loads as nil, dates in the future are dropped rather than believed, and the scan policy inside a loaded cache is never adopted as the policy to scan by: roots and depth come from the app, not from the file on disk.
- **No writes to any repo and no network calls of the app's own.** It never fetches, and every GitHub read goes through `gh` under the user's own token.
- **Launch at login registers only the copy the toggle names, and then checks.** Both mechanisms refuse unless the running bundle is `/Applications/BranchBar.app` or `~/Applications/BranchBar.app`, so `SMAppService` cannot register a copy in Downloads while the LaunchAgent plist names Applications; the home-folder path is accepted because a standard non-admin account on a managed Mac normally cannot write `/Applications`, which made the feature unreachable for exactly the testers it ships to. A translocated bundle is refused outright. Registration is verified after the fact with `launchctl print`, the fallback validates the whole plist rather than one key, bootout goes by label, and an unregister that fails is propagated rather than reported as success.
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

**`gh auth status` writes its report to stdout on gh 2.89, and its exit code answers a different question than its output.**
Older releases sent the report to stderr; the script merges both streams into the fixture, so the recording is right either way, but code or a test that reads one stream by name will read the wrong one. With `--hostname`, judge the exit code, which is what `GHClient.authStatus` does. Without it, judge the output: `gh` exits non-zero when *any* configured host is logged out while still listing the hosts that are logged in, and that list is what decides which hosts BranchBar treats as GitHub.

**`Command.environment` merges over the inherited environment rather than replacing it.**
`ProcessCommandRunner` copies `ProcessInfo.processInfo.environment` and overlays the command's entries, which is what the frozen git and gh environments assume: they set the keys that matter and let PATH and HOME through. The doc comment on that field said "replaces" until packet F5 and now says what the runner does, with `environmentMergesCommandEnvOverInherited` pinning it.

**A synthesized `Codable` decoder ignores a stored property's default.**
`init(from:)` calls `decode(_:forKey:)` for every non-optional property, so a field added to a cached type after the freeze is a *required* key and every `cache.json` an earlier build wrote fails to decode. `FileCacheStore.load` reports that as "no cache", which looks like a cold first launch rather than a bug. Add a field to a cached type and add it to that type's explicit decoder with `decodeIfPresent` in the same edit; `cache-1.1-era.json` is the fixture that catches it.

**A blocked `open()` outlives every deadline above it.**
Task cancellation lands between listings, not inside one, so a folder-access dialog nobody answered, a stalled automount, or a dead network volume holds the walking task forever. Racing it in a task group and returning leaks a permanently blocked thread. Only a process can be killed, which is why discovery runs in `branchbar-cli` and the scan deadline is a signal to a process group.

**A named pipe where a regular file belongs blocks `open()` too.**
A `.git` symlink pointing at a FIFO, or a FIFO left where a reflog or the cache goes, is the same trap one level down and inside the app's own process. Every repository-owned read goes through `RealFileSystem.readBoundedRegularFile` with `O_NOFOLLOW | O_NONBLOCK` and an `S_IFREG` check; `.git` symlinks are never opened. A `FileManager` convenience added later would reintroduce it silently.

**`git rev-parse` prints multiple paths newline-separated, and a directory name may contain a newline.**
Asking for `--git-common-dir --show-toplevel` in one invocation gives an answer that cannot be split back into the two paths that produced it, which shifted repo identity for a repo at `~/project\narchive`. Ask once per path. The same reasoning moved `worktree list --porcelain` to `-z`.

**A thrown timeout carries no bytes, so a killed child reads as a silent one.**
`CommandRunner.run` is right for a command whose output is one document: a truncated `for-each-ref` that happens to end on a record boundary is a shorter branch list, which is a lie. It was wrong for the scan helper, whose output is a stream of independently true lines, and the cost was three 21-second launches reporting zero repos while the helper had found 25. `runCollectingPartialOutput` is the exception, and it is the only one.

**A quarantined bundle is app-translocated, even out of `/Applications`.**
The process runs from `/private/var/folders/…/AppTranslocation/…`, so nothing may be derived from `Bundle.main.bundlePath` — the helper is resolved from the running executable's own directory instead — and `SMAppService` must refuse to register from a translocated copy. Removing `com.apple.quarantine` from the bundle root restores the real path. `SMAppService` itself works with the ad-hoc signature from `/Applications`, going `notFound` to `enabled` to `notRegistered` and never `requiresApproval`.

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
