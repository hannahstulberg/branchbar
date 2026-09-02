# PLAN — BranchBar

Session: `cced85a0-5ced-4282-bc94-e23dcbe42d18` (local resume UUID). Workflow: `coding-project` skill (Opus orchestrator, delegated implementers, red/green TDD, Gate 1 plan review before any code). Today: 2026-09-01. Fixed date: NYT GitHub Fundamentals session **Thu 2026-09-24**.

## §1 Context & goal

NYT PMs and designers use Claude Code through AWS Bedrock inside Cursor/VS Code. They have no Claude desktop app, so they lack its branch/worktree picker and status view. Hannah teaches branches and worktrees on Sept 24 (workshop Blocks 3, 6, 7: branches, worktrees, "distinguish work that is active, ready for review, merged, or abandoned") and wants a small macOS menu bar app that shows the repos it found under the home folder or that the user added, each repo's branches and worktrees, each branch's PR state, when a push was last observed from this Mac, and which branches have a merged PR with no later local commits. It is a **handout**: attendees install it from a zip, the same way Andrew Lisy's JobRunner (Electron, electron-builder, ad-hoc signed, unnotarized, `LSUIElement`) was handed to the same audience. An NYT tester on a managed Mac opens the **spike build first (Gate 0b, Sept 4)**, before real code is sunk, and the release build later (Gate 5).

Prior art in this workspace: `WalkTimer/` (SwiftUI `MenuBarExtra` + Application Support JSON persistence) for the shell pattern only; it is XcodeGen-based and BranchBar must be pure SwiftPM.

Quality bar: a PM installs it from a zip in under two minutes using only the README, opens the menu, and sees an honest list. Core logic and every user-facing string are unit-tested; every packet is red before green; every frozen git/gh invocation is executed against `/usr/bin/git` 2.39.5 and `gh` before it is frozen.

## §2 Research verdicts

| Question | Verdict | Evidence |
|---|---|---|
| NYT git host | github.com most likely; GHE not ruled out | workshop materials; host derived from remote URL (§5) |
| `gh` available at NYT | yes, workshop prerequisite | `workshop-outline.md:29` |
| JobRunner build | Electron, ad-hoc signed, no notarization, `LSUIElement=1`. **Proves how it was built, not that it opened on an NYT-managed Mac** → NYT test gate (§8) | inspected zip |
| Do end users need Xcode or any toolchain | **no**; they download a zip | distribution design (§5b) |
| Toolchain on Hannah's machine | Swift 6.1.2 via Command Line Tools; no Xcode. Detection: `xcode-select -p` returns a CommandLineTools path (`/usr/bin/xcodebuild` exists as a shim) | verified |
| `swift build` (CLT only) links SwiftUI for arm64 | likely yes: `SwiftUI.tbd` targets are `x86_64-macos, arm64-macos, arm64e-macos` (link step is fine); only the `.swiftinterface` files are `arm64e` + `x86_64`, so module import relies on the arm64→arm64e interface fallback. `Testing.framework` lives outside the SDK at `CommandLineTools/Library/Developer/Frameworks/` | verified (`.tbd` targets line, swiftmodule listing); **packet 0.2 spike confirms; Xcode install is the fallback** |
| XCTest under CLT | absent; Swift Testing only | verified |
| `@main` in SPM executable | SwiftPM adds `-parse-as-library` when no `main.swift` exists | confirm in spike |
| Universal binary on CLT | two `--triple` builds + `lipo`; exact triple recorded by spike | SDK has x86_64 tbds |
| `SMAppService` with ad-hoc signature | unverified: spike | LaunchAgent fallback |
| CI runner | `macos-15` (Swift 6.1.2). Runner has full Xcode, so a second job runs `sudo xcode-select -s /Library/Developer/CommandLineTools` before `make test build` to keep the CLT path under continuous test | runner-images |
| Gatekeeper on macOS 15 | open once → System Settings → Privacy & Security → Open Anyway | rehearsable locally |
| TCC from an ad-hoc app | **unverified: spike** whether an `NSOpenPanel` pick after a denied prompt grants recursive read, and whether a rebuilt ad-hoc binary re-prompts | packet 0.2 items 8–9 |
| Agents-mode worktrees | `<repo>/.claude/worktrees/<name>`, branch `worktree-<name>` | code.claude.com/docs/en/worktrees |
| Web-session branches | `claude/<slug>-<id>` on GitHub only | this repo's remote refs |
| Local push timestamp | `<git-common-dir>/logs/refs/remotes/<remote>/<branch>` lines `old new author <email> unixtime tz\tupdate by push`. **Files can exist and be empty** (`origin/updates-3-29-26` here, 0 bytes); `push --delete` writes a line with an all-zero new OID; entries expire at **90 days (reachable) / 30 days (unreachable, i.e. rewritten or force-pushed history)** per `gc.reflogExpire` defaults, both unset here. The file records what **this clone** observed, never pushes from other machines or clones | verified |
| `git reflog show` and `--` | `reflog show --format=… -- <ref>` returns **zero rows, exit 0** on 2.39.5 and 2.52; without `--` it works. `for-each-ref -- refs/heads` does accept `--` | verified |
| `%(upstream:track,nobracket)` | empty for **both** "in sync" and "no upstream"; disambiguate via `upstream:short` | verified |
| `gh pr list --json headRepositoryOwner` | returns an object `{id, login, name}`; `reviewDecision` is `""` (not null) when undecided; `headRefOid` and `mergeCommit.oid` available | verified |
| `gh pr list --search` | search API, 30 req/min | `gh api rate_limit` |
| Core rate limit | 5000/h; 30 repos × 2 calls = 60 per cold refresh. **Not a binding limit**; the PR cache is for latency, not quota | `gh api rate_limit` |
| GUI app PATH | `/usr/bin:/bin:/usr/sbin:/sbin`; Homebrew `gh` invisible | verified |
| git versions | `/usr/bin/git` 2.39.5 (what NYT will have); Homebrew 2.52 on Hannah's PATH | verified |
| Home scan | depth 4 on Hannah's machine: 30 `.git` entries, 7 are tool internals under `.cache`, `.claude`, `.codex`; **4 real repos sit at depth 5–7** (`~/gt/deacon/dogs/alpha/…`) | verified |

## §3 Locked decisions

- **Name** BranchBar. **Repo** `github.com/hannahstulberg/branchbar`, public, clone at `~/branchbar`. Bundle id `com.hannahstulberg.branchbar`. End users never need repo access, Xcode, or any toolchain; they download the zip from Releases.
- **Handout, NYT-tested twice.** **Gate 0b (Sept 4, the real stop gate):** the NYT tester, on a managed Mac with a non-admin account, downloads the quarantined spike zip (packet 0.3: the 20-line app plus a "Check GitHub CLI" button that runs `gh auth status` through `ToolLocator` and shows the result, and an "Add folder…" button that triggers a TCC prompt), installs it in under two minutes, relaunches after reboot, opens a rebuilt zip, and reports what they clicked. If MDM blocks it and NYT IT offers no allow-list or signing path, the menu bar app stops there and the workshop falls back to a terminal script (see NOT in scope). **Gate 5 (by Sept 12):** the same tester opens the `v0.9.0` release zip and runs the full checklist (repos appear, PR pills load, Add folder… recovers a TCC-denied folder, one row action works, a merged branch shows in Merged). The first arm64 release zip therefore lands **by Sept 10**. Workshop Block 7 stands on `git branch` / `git worktree list` regardless of outcome.
- **Stack** Swift + SwiftPM only, SwiftUI `MenuBarExtra(.window)`, macOS 13+. Why: Claude Code extends either stack equally; with readability off the table, 2 MB zip, native menu, and no Node build dependency win.
- **Toolchain** Command Line Tools on Hannah's machine; the packet 0.2 spike confirms the exact package shape (Core in Swift 6 mode, executable in Swift 5 mode, Swift Testing, manual `.app`, ad-hoc signing, GUI-launched `gh`). If spike item 1 fails, Hannah installs Xcode that day (free, ~1 h) and the plan continues unchanged. CI runs both a full-Xcode job and a CLT-selected job.
- **Distribution** one zipped `.app`, **arm64 only in v1** (a `lipo`'d x86_64 slice is not an Intel test; ship universal only after the slice runs on an Intel machine or runner), ad-hoc signed, no Developer ID, no sandbox. The README is a product surface (§8 packet 5.2). Supported `gh` auth is the keyring path (`gh auth login`); `GH_TOKEN`-only setups get a one-click "Open Terminal with the exact `gh auth login --hostname <host>` command" action and are named as unsupported in the README.
- **Repo discovery** (Hannah's decision: "check the repos cloned on their computer"; the product promise is **"repos BranchBar found under your home folder, or folders you added"**, never "every repo"): first launch auto-scans `~` to **depth 6**, skipping every hidden directory (name starts with `.`) except the `.git` marker itself, plus the literal skip list in §5; no descent into a found repo; symlinks not followed; cached; Rescan button. **"Add folder…"** (`NSOpenPanel`, persisted as a scan root) scans the chosen folder **recursively with no depth limit** (same skip list), so a deep repo, a `~/Library/CloudStorage` folder, a nested repo inside a monorepo, or a symlink target is reachable by adding it; scan roots are listed and removable in the footer. The scan summary states what was deliberately skipped ("hidden folders, Library, depth > 6, folders inside repos") beside the "Not scanned: Documents, Desktop" row for TCC-denied folders, with a button that re-triggers access. Worktrees via `git worktree list --porcelain`; worktree checkouts and submodules never listed as repos; dedupe by `git rev-parse --git-common-dir`. `descendIntoRepos` is a constant `false` for the home scan. Bare repos are out of scope.
- **PR status** via `gh` only. Host from `remote.origin.url`; `gh auth status --hostname <host>` once per distinct host per refresh; failure → every branch `.unavailable` with per-reason copy and one action. No `--search`. **PR matching is by `headRefName` first**; `headRepositoryOwner.login` only disambiguates collisions, never excludes (fork workflows must match). Branches with no match in the 100-most-recent list get a per-branch `--head <name>` query, capped at 20 per repo per refresh; **a branch that was never queried (cap reached, deadline hit, or repo collapsed) renders `notChecked` ("PR status not checked yet"), never `none`**. Worst case per eager repo is 22 `gh` calls (list + 20 heads + author list); Gate 3 measures wall time and API cost on a busy repo with > 100 PRs and > 20 unmatched branches and fails if a cold expanded repo cannot return honest results inside the deadline.
- **Lazy PR fetching.** A refresh always runs git for every repo (local, fast). `gh` runs only for expanded repos plus the 5 most recently active; collapsed repos show "PR status loads when expanded". PR results cached per repo in `CacheFile`, TTL 10 min; "Refresh PRs now" bypasses it. Rate-limit responses map to `rateLimited` with copy that says waiting fixes it.
- **"Open PRs not on this Mac" group** per repo from `gh pr list --author @me --state open`, keyed by **(head owner login, head branch)**; a PR is "not on this Mac" when no local branch has that name **and** the same upstream owner (a local `feature-x` tracking `origin` does not hide the user's fork PR named `feature-x`). PR state + link only. No `git fetch`, ever.
- **"Merged" and "Closed without merging" groups** per repo (never one "clean up" bucket): Merged = PR merged **and** local `tipSHA == headRefOid` (no commits after the merge) and no worktree, copy "PR merged into `<baseRefName>`. No later local commits found." (never "safe to delete"). Closed without merging = PR closed unmerged, copy "PR closed without merging. This branch may hold work that was never merged." The app deletes nothing.
- **Last push observed** from the reflog file, and the label says exactly that: "**Pushed from this Mac 2 days ago**" (never "You pushed"). Rule: scan the file newest-first; stop at the first deletion line (all-zero new OID) so a push before a delete/recreate is never attributed to the new incarnation; the first `update by push` line above that boundary is the observation; if its new OID is not the current remote-tracking tip, append "(origin has moved since)". Fallback when there is **no usable line** (file absent, empty, fetch-only, deletion-only, expired): "**Last push unknown · newest commit dated 2 days ago**", a separate fact with its own tooltip, never presented as a push. `git reflog show` is a secondary fallback invoked **without** `--`. Acceptance fixtures: another-machine push (fetch-only file), fresh clone, rebase, force-push, deleted-then-recreated branch, 30/90-day expiry, push from a linked worktree (shares the common dir, so it is observed).
- **Ahead/behind** `behind` never displayed. Ahead renders as "2 ahead of last-known origin", tooltip carries `FETCH_HEAD` mtime. "In sync" vs "no upstream" decided by `upstream:short`, never by the track field.
- **Refresh** on popover open (debounced 30 s) plus manual Refresh that bypasses the debounce. Overall deadline 45 s; unfinished repos marked stale, child processes terminated. Footer shows "Updated 12 s ago" and the version. No background timer. Menu bar icon is a monochrome template SF Symbol that never conveys state.
- **Row actions** primary **Open in Cursor** (`open -a Cursor <path>`; Cursor → VS Code → Terminal; the Cursor-absent case has its own string in §5a). Secondary: open PR, reveal in Finder, copy path.
- **Launch at login** in v1, opt-in toggle; `SMAppService` if the spike passes, LaunchAgent fallback. Last in packet 4.2 and first cut.
- **Vocabulary** workshop words only (repo, branch, worktree, PR, push). "Detached" → "Worktree at commit abc1234 (no branch)"; upstream gone → "Upstream missing from last-known origin" (the app never fetches, so it cannot assert the branch is deleted on GitHub). Every remote-derived git fact uses "last-known origin" wording.
- **Strings are code.** Packet 4.0 emits `Sources/BranchBarCore/Strings.swift` (one `enum Strings` with every user-facing string as a static); `SnapshotPresenter` and the views consume it. Drift between the string table and the presenter is a compile error.
- **Fixtures are recorded, not transcribed.** `make record-fixtures` runs the frozen invocations against real repos with `/usr/bin/git` and `gh` and writes the fixture files; hand-extended cases are separate files marked `synthetic-`. No model transcribes git output.
- **Model rule** Opus for all implementation packets (Hannah's explicit ask). Orchestrator writes no production code. For the four high-risk semantics (push observation 2.1, PR matching 2.3, discovery 2.4, deadlines/cancellation 3.2) the **acceptance tests are written by a separate agent from the frozen contract before the implementer starts**, so test author and implementer cannot share a mistaken reading; the orchestrator verifies red at the test author's SHA and green at the implementer's.

**NOT in scope for v1**: any `git fetch`; displaying `behind`; in-app update check; idle-days filter; deleting branches or worktrees; non-GitHub hosts; `GH_TOKEN`-only auth (named unsupported; setup action opens Terminal with `gh auth login`); universal binary until an Intel test exists; bare repos; following symlinks in the home scan; nested repos inside a found repo during the home scan (reachable via Add folder…); "every repo" as a promise.

**Fallback if Gate 0b fails**: a read-only terminal script (`branchbar-cli snapshot`, the Gate 3 harness) distributed as source, which inherits the terminal's PATH and `GH_TOKEN` and needs no Gatekeeper, TCC, or bundling. The Core library is the same; only the shell differs.

Rejected reviewer proposals: "folder-picker first, scan only granted folders" (Hannah chose auto-discovery; mitigated by Add folder… as recursive scan roots, Not-scanned row, skipped-categories summary); "cut launch-at-login" (kept on the cut line); "install Xcode now" (spike confirms; Xcode is the dated fallback); "demo not handout" and codex's "kill, build a script instead" (Hannah decided handout; the codex concern is answered by moving the managed-Mac test to Gate 0b with the spike build and keeping the CLI harness as the documented fallback); "use cheaper models for parsers" (Hannah asked for Opus; the independence concern is met by separate test-author and implementer agents).

## §4 Architecture

```mermaid
graph TD
    subgraph UI["BranchBar (executable, SwiftUI shell, @MainActor) — Views only"]
        App[BranchBarApp<br/>MenuBarExtra .window] --> AM[AppModel<br/>@Published SnapshotVM + RefreshState]
        AM --> V[Views: RepoSection / BranchRow / GroupRows / Footer]
        V --> Act[Actions: open -a Cursor, open URL, Finder, clipboard, launch-at-login]
    end
    subgraph Core["BranchBarCore (library, no AppKit/SwiftUI, fully tested)"]
        AM --> SP[SnapshotPresenter<br/>Snapshot → row view-models via Strings.swift]
        AM --> RC[RefreshCoordinator actor<br/>cap 4, 45 s deadline, isolation, progressive emit, stable order, lazy PR]
        RC --> TL[ToolLocator<br/>git/gh outside GUI PATH, git --version]
        RC --> SC[RepoScanner<br/>BFS depth 6, hidden-dir + literal skip list, dedupe, unreadable dirs reported]
        RC --> RL[RepoLoader per repo]
        RL --> GC[GitClient] --> P1[ForEachRefParser]
        GC --> P2[WorktreeListParser]
        RL --> P3[ReflogFileReader<br/>usable-line predicate, zero-OID = deletion]
        RL --> GH[GHClient<br/>per-host auth, list + per-head fallback, PR cache TTL] --> P4[PRListDecoder + PRStatusMapper]
        RL --> AS[RepoAssembler<br/>pure join + Merged / Closed / Open-elsewhere groups]
        AS --> PD[PushInfoDeriver]
        RC --> CS[CacheStore<br/>atomic replace]
        GC --> CR[CommandRunner protocol]
        GH --> CR
        SC --> FS[FileSystem protocol]
        P3 --> FS
    end
    subgraph Ext["Outside the process (trust boundary)"]
        CR --> GIT[/git binary/]
        CR --> GHB[/gh binary → GitHub API, user's own token/]
        FS --> HOME[/~ (TCC-gated folders)/]
    end
```

Trust boundary: the app holds no credentials. `gh` uses the user's keyring token; the app reads only its stdout. Test doubles (`RecordedCommandRunner`, `InMemoryFileSystem`, `InMemoryCacheStore`) replace the three external seams so `swift test` never touches the network or the real home folder. Every string a user reads is produced in Core from `Strings.swift` by `SnapshotPresenter`.

Refresh lifecycle: launch → load cache (rows stale) → show → refresh. Refresh: coalesce → preflight tools → repo list from cache (scan if none or > 7 days) → task group cap 4 under 45 s → per repo: `rev-parse`, `remote.origin.url`, `for-each-ref refs/heads`, `worktree list --porcelain`, `for-each-ref refs/remotes`, reflog file reads; then, only for expanded + top-5 repos with a PR cache older than 10 min: `gh pr list` (recent 100), per-head fallback for unmatched local branches, `--author @me` list → assemble → emit in stable order → persist atomically.

## §5 Data model / contracts (frozen in packet 1.1, every invocation executed first)

Package (single source, §5b): swift-tools-version **6.0**, `platforms: [.macOS(.v13)]`; `BranchBarCore` (Swift 6 mode), `BranchBar` executable (Swift 5 mode), `BranchBarCoreTests` (depends only on Core).

Types (all `Hashable, Codable, Sendable`):

- `RepoID { commonDir }`. `GitHubSlug { host, owner, name; init?(remoteURL:) }` any host.
- `Repo { id, name, path, remoteURL?, githubSlug?, worktrees, branches, openPRsNotOnThisMac: [PRInfo], prAvailability, prFetchedAt?, prLoadState: notLoaded | loaded | stale, lastRefreshed?, errors: [RepoError], isStale, lastActivity }`
- `Worktree { path, headSHA, branch?, isPrimary, isBare, isLocked, lockReason?, isPrunable }`
- `Branch { name, tipSHA, committerDate, upstream: Upstream?, worktreePath?, isCheckedOutInPrimary, pr: PRInfo?, prStatus: PRStatus, push: PushInfo, group: active | merged | closedUnmerged }`
- `Upstream { ref, remote, ahead, behind, isGone }` (`behind` never presented)
- `PRStatus: none | draft | open | changesRequested | approved | merged | closed | unavailable | notLoaded | notChecked` (`none` only after the branch's head was actually queried and returned nothing; `notChecked` when the cap, deadline, or collapse prevented the query)
- `PRInfo { number, url, state, isDraft, reviewDecision (empty string ⇒ undecided), mergedAt?, updatedAt, baseRefName, headRefName, headRefOid, headRepositoryOwnerLogin, mergeCommitOid? }`
- `PRAvailability: available | unavailable(PRUnavailableReason, detail?)`; reasons `ghNotInstalled | ghNotAuthenticated(host) | noRemote | notGitHubRemote | rateLimited | commandFailed`
- `PushInfo { observedPushAt?, observedPushOID?, originMovedSince: Bool, source: reflogObserved | tipCommitDate | none, hasUpstream, upstreamGone, aheadOfLastKnownRemote: Int?, remoteRefObservedAt: Date? }`
- `ScanPolicy { homeRoot, extraRoots: [String] (Add folder…, recursive, no depth limit), maxDepth = 6 (home root only), skipHiddenDirectories = true, skipDirectoryNames = ["Library","Applications","Pictures","Movies","Music","Public","node_modules","vendor","Pods","DerivedData","build","dist","target","venv","site-packages","__pycache__","go/pkg"], descendIntoRepos = false }`, `DiscoveredRepo { path, id }`, `ScanResult { policy, scannedAt, repos, candidatesExamined, unreadableDirectories, depthCutDirectories: Int, skippedHiddenDirectories: Int, skippedWorktreeCheckouts, skippedSubmodules }`
- `Snapshot { repos (stable order), refreshedAt?, tools: ToolStatus { gitPath?, gitVersion?, ghPath?, ghAuthByHost } }`
- `RefreshPolicy { debounce 30 s, overallDeadline 45 s, maxConcurrentRepos 4, prCacheTTL 600 s, eagerPRRepoCount 5, perHeadFallbackCap 20 }`
- `UserFacingFailure { title, message, action?, diagnostic }`; `RefreshState: idle(lastRefreshedAt) | running(completed,total) | failed(UserFacingFailure)`
- `RepoError { stage: branches | worktrees | remotes | reflog | github | deadlineExceeded, message }`
- `CacheFile { schemaVersion 1, scan?, manuallyAddedRepos, hiddenRepoIDs, collapsedRepoIDs, prCache: [RepoID: PRCacheEntry { fetchedAt, prs, authorPRs }], lastSnapshot? }`; `CacheStore` writes temp file then `replaceItemAt` (atomic).
- `Command { executable, arguments, workingDirectory?, environment?, timeout }`, `CommandOutput`, `CommandError`, `protocol CommandRunner`; cancellation terminates the child.
- `protocol FileSystem { contentsOfDirectory, fileExists, isExecutableFile, readFile, modificationDate, homeDirectory, pathEnvironment }`
- `enum Strings` (generated by packet 4.0): every user-facing string as a static or static func.
- View-models: `SnapshotVM { sections: [RepoSectionVM], footer: FooterVM, emptyState: EmptyStateVM? }`, `RepoSectionVM { title, isCollapsed, active: [BranchRowVM], openElsewhere: [PRRowVM], merged: [BranchRowVM], closedUnmerged: [BranchRowVM], prNotice?, notScannedNotice? }`, `BranchRowVM { title, worktreeMarker, prPill: (text, status), pushLabel, pushTooltip, aheadLabel?, primaryAction, accessibilityLabel }`, `FooterVM { updatedLabel, version, toolNotice? }`.

Exact invocations (git env `LC_ALL=C`, `GIT_OPTIONAL_LOCKS=0`, `-C <repo>`; gh env `GH_PROMPT_DISABLED=1`, `GH_NO_UPDATE_NOTIFIER=1`, `GH_PAGER=cat`, `NO_COLOR=1`, `CLICOLOR=0`; U+001F separator). `--` is used **only** where verified to work (`for-each-ref`); never with `reflog show`.

```
git for-each-ref --format='%(refname)%1f%(objectname)%1f%(committerdate:unix)%1f%(upstream:short)%1f%(upstream:remotename)%1f%(upstream:track,nobracket)%1f%(HEAD)' -- refs/heads
git worktree list --porcelain
git for-each-ref --format='%(refname)%1f%(objectname)%1f%(committerdate:unix)' -- refs/remotes/
git rev-parse --path-format=absolute --git-common-dir --show-toplevel
git config --get remote.origin.url
git reflog show --date=unix --format='%gd%x1f%gs%x1f%H' refs/remotes/<upstream>      # secondary fallback only; NO --
gh auth status --hostname <host>
gh pr list --repo <host>/<owner>/<name> --state all --limit 100 --json number,url,state,isDraft,reviewDecision,mergedAt,updatedAt,baseRefName,headRefName,headRefOid,headRepositoryOwner,mergeCommit
gh pr list --repo <host>/<owner>/<name> --state all --head <branch> --limit 5 --json <same>     # per unmatched local branch, cap 20/repo
gh pr list --repo <host>/<owner>/<name> --state open --author @me --limit 100 --json <same>
```

Last push observed (`ReflogFileReader`): read `<git-common-dir>/logs/refs/remotes/<remote>/<branch>`, walk lines newest-first; **stop at the first line whose new OID is all zeros** (a deletion boundary); the first line above the boundary whose message (after the tab) starts with `update by push` is the observation: unix timestamp (field 5) and new OID (field 2). `originMovedSince = (observedPushOID != current remote-tracking tip OID)`. No usable line (file absent, empty, fetch/pull-only, deletion-only) → try `git reflog show` (above) with the same boundary rule → else `source = .tipCommitDate` from the remote-tracking tip, presented as a separate fact. `%gd` under `--date=unix` yields `origin/main@{<unixtime>}`; timestamp is extracted from inside the braces.

Join rules: exact branch name; worktrees without a branch never join; PR match by `headRefName`, `headRepositoryOwnerLogin` disambiguates only when several PRs share a head (prefer same owner, then OPEN, then latest `updatedAt`, sorted client-side); "Open PRs not on this Mac" = author-@me PRs whose (head owner login, head branch) matches no local branch's (upstream owner, name); `merged` group = `prStatus == merged && tipSHA == headRefOid && worktreePath == nil` (copy names `baseRefName`; no deletion-safety claim); `closedUnmerged` = `prStatus == closed`. Grouping is decided in `RepoAssembler` (packet 3.1) and only rendered by `SnapshotPresenter` (packet 2.2); `Branch.group` is the boundary. Timeouts: git 10 s, `gh auth status` 10 s, `gh pr list` 25 s, overall 45 s.

`ToolLocator` order: `BRANCHBAR_GIT`/`BRANCHBAR_GH` env → `/opt/homebrew/bin` → `/usr/local/bin` → `~/.local/bin` → `/opt/local/bin` → PATH → (git only) `/usr/bin/git` iff `xcode-select -p` resolves. Records `git --version`; below 2.39 → tool notice.

### §5a UI contract (frozen in packet 4.0)

`docs/UI-CONTRACT.md` plus the generated `Strings.swift`, before any SwiftUI:

1. **State table** with the literal string for: first run while scanning; zero repos (primary action Add folder…, names Drive/Dropbox and deep folders); Not-scanned folders row and the skipped-categories summary; gh not installed; gh not signed in (per host, with the Open-Terminal setup action); rate limited; no GitHub remote; one branch, no PR, never pushed (the modal NYT case); PR status not loaded (collapsed repo); PR status not checked (cap or deadline); `gh pr list` timeout; one repo failed; deadline exceeded; stale rows at launch; git older than 2.39; Cursor not installed; last push unknown (fallback wording); origin moved since the observed push.
2. **String table** for every row type and group heading, workshop vocabulary only.
3. **Row hierarchy**: worktree marker leading; branch name primary; PR pill secondary (text + color); push line and ahead count tertiary. Groups per repo: Branches and worktrees → Open PRs not on this Mac → Merged → Closed without merging. Repo order most-recently-active first, computed once; rows fill in but never reorder mid-refresh.
4. **Token table**: width 340, max height 70% of screen with internal scroll, row height, type scale, 10 `PRStatus` colors in light and dark, per-repo collapse persisted (default expanded when one repo, otherwise only the most recent).

Accessibility: arrow keys traverse, Return runs primary action, Escape dismisses; VoiceOver label per row type; no emoji as status.

### §5b Build, packaging, and distribution contract

- `Package.swift`: tools-version 6.0, per-target `swiftLanguageMode` (Core `.v6`, executable `.v5`). No `resources:`; fixtures resolve from `#filePath`.
- Entry file `Sources/BranchBar/BranchBarApp.swift` (never `main.swift`); `NSApp.setActivationPolicy(.accessory)` in the delegate.
- Tests: Swift Testing only; `make test` = `swift test --disable-xctest --enable-swift-testing`. `import XCTest` banned (grep test).
- Layout: `Sources/`, `Tests/` (+ `Fixtures/recorded-*`, `Fixtures/synthetic-*`), `Resources/` (`Info.plist.template`, `icon-1024.png`), `scripts/` (`bundle.sh`, `make-icns.sh`, `render-icon.swift`, `windowid.swift`, `screenshot.sh`, `record-fixtures.sh`), `Makefile`, `VERSION`, `docs/`, `.github/workflows/ci.yml`.
- `scripts/bundle.sh` minimal in packet 0.2 (host-arch build, Info.plist, PkgInfo, ad-hoc sign, verify); hardened in 5.1 (optional x86_64 slice + `lipo`, icns, minos check, `ditto` zip + `.sha256`). Sign last. No entitlements.
- Makefile: `test build release bundle zip run stop logs screenshot install verify record-fixtures clean`. Log `~/Library/Logs/BranchBar/BranchBar.log` + `os.Logger`.
- CI: `runs-on: macos-15` pinned; job A full Xcode, job B `sudo xcode-select -s /Library/Developer/CommandLineTools` then `make test build`; both print `swift --version`; `make zip` → `make verify` → artifact; on `v*` tag, guard `v$(cat VERSION) == tag`, Release with zip + sha256.
- Screenshots for verification via `screencapture` + `osascript` + `scripts/windowid.swift` (one-time Accessibility + Screen Recording grants).

## §6 Security & trust boundaries

- No secrets stored or read. `gh` authenticates itself. `GH_TOKEN` only in a shell rc is invisible to a GUI app (documented).
- Blast radius if compromised: runs `git` and `gh` as the user. Mitigation: fixed command list, `Process` argument arrays, `--` where git supports it, paths from the filesystem or the user's picker.
- Not sandboxed. TCC prompts on first scan; denial visible, never silent. Ad-hoc signature may make TCC re-prompt after updates (spike decides; README states it if so).
- Not defended against: a hostile repo on disk (branch names are argv operands and displayed text, never executed).

## §7 TDD & engineering rules

- Red/green per packet; orchestrator re-runs the suite at the red SHA in a throwaway worktree before accepting; rejects packets whose tests never went red.
- **Every §5 invocation is executed verbatim against `/usr/bin/git` 2.39.5 and `gh` 2.89 by `make record-fixtures` before packet 1.1 closes.** A frozen command that returns nothing on a live repo is a packet 1.1 failure.
- Fixtures: recorded via script, synthetic extensions in separate files; no live git or network in unit tests except the two live-repo sanity tests named below.
- Named invariant tests: `reflogShowFallbackReturnsRowsForARefThatHasPushes` (live repo), `everyFrozenGitInvocationReturnsExpectedShapeOnThisRepo` (live repo; empty lists allowed where documented), `reflogFieldsSplitOnUnitSeparatorNotLiteralPercent1f`, `reflogFileLastUsablePushLineParsesUnixTimestampFromField5`, `emptyReflogFileFallsBackToTipCommitDate`, `pushDeletionLineIsNotTreatedAsAPush`, `pushBeforeADeletionBoundaryIsNotAttributedToTheRecreatedBranch`, `observedPushWhoseOIDIsNotTheRemoteTipSetsOriginMovedSince`, `pushFromAnotherMachineYieldsNoObservationNotAFakeDate`, `reflogFileWithOnlyFetchLinesFallsBack`, `fallbackLabelDoesNotClaimGitHubObservedTheBranch`, `observedPushLabelSaysFromThisMacNeverYouPushed`, `unqueriedBranchIsNotCheckedNeverNone`, `openElsewhereKeyedByOwnerAndBranchNotBranchAlone`, `mergedCopyNamesBaseRefAndMakesNoDeletionClaim`, `upstreamGoneCopySaysLastKnownOriginNotDeletedOnGitHub`, `extraRootScansRecursivelyWithoutDepthLimit`, `scanSummaryReportsDepthCutAndHiddenSkips`, `inSyncAndNoUpstreamAreDistinguishedByUpstreamShortNotTrack`, `noBranchWorktreeAppearsUnderRepoAndNoBranchClaimsIt`, `ghMissingMakesEveryBranchUnavailableWithoutThrowing`, `authStatusFailureShortCircuitsPRListForAllReposOnThatHost`, `enterpriseHostRemoteResolvesSlugAndAuthPreflightPerHost`, `forkOriginatedPRStillMatchesItsLocalBranch`, `emptyReviewDecisionStringIsNotAReviewDecision`, `branchWithAnOlderPRStillResolvesItsPRStatusViaHeadQuery`, `perHeadFallbackRespectsPerRepoCap`, `firstRefreshDoesNotIssueGhCallsForCollapsedRepos`, `prCacheWithinTTLIssuesNoGhCalls`, `refreshStillUpdatesGitStateWhenPRCacheIsWarm`, `rateLimitResponseMapsToRateLimitedNotCommandFailed`, `prListDecoderSortsByUpdatedAtDescendingRegardlessOfInputOrder`, `reflogPushBeatsTipCommitDate`, `noUpstreamRendersNeverPushedNotZeroCommits`, `aheadCountLabelledRelativeToLastKnownRemoteNotAbsolute`, `branchWithCommitsAfterItsMergeIsNotInMergedGroup`, `closedUnmergedBranchIsNotLabelledMerged`, `openPRsNotOnThisMacExcludesHeadsThatExistLocally`, `hiddenDirectoriesUnderHomeAreSkipped`, `repoAtDepthSixIsFoundAndDepthSevenIsNot`, `gitFilePointingIntoWorktreesIsExcludedAndReported`, `doesNotDescendIntoDiscoveredRepo`, `unreadableDirectoryIsReportedNotSilentlySkipped`, `oneRepoFailingLeavesOthersPopulated`, `peakConcurrencyNeverExceedsCap`, `secondRefreshWhileRunningCoalesces`, `refreshHonorsOverallDeadlineAndMarksUnfinishedReposStale`, `cancelledRepoTasksTerminateTheirChildProcesses`, `rowOrderIsStableAcrossProgressiveEmits`, `commandRunnerReturnsFullOutputWhenStdoutExceedsPipeBuffer` (≥ 1 MB), `commandRunnerDrainsStderrConcurrentlyWithStdout`, `branchNameBeginningWithDashIsPassedAsOperandNotFlag`, `interruptedSaveLeavesPreviousCacheIntact`, `unknownSchemaVersionLoadsNil`, `emptyScanRendersActionableEmptyState`, `unavailableReasonCopyNamesOneActionPerReason`, `everyStringsEntryIsReachableFromSomeState`, `noAppKitOrSwiftUIImportInCore`, `noXCTestImportAnywhere`.
- Swift 6 mode in Core; every Core type `Sendable`. Stubs carry `// OWNER: packet N.N`.

## §8 Roadmap

Critical path (human gates in bold): 0.1 → 0.2 (**Gate 0**) → 0.3 → **Gate 0b (NYT managed Mac, 09-04, stop gate)** → 1.1 → 4.0 (**Gate 4.0**) → {2.1, 2.2, 2.3, 2.4, 2.5} → 3.1 → 3.2 (**Gate 3**) → 4.1 → 5.1a (**first zip 09-10**) → **Gate 5 (by 09-12)** → 4.2 → 5.1b → 5.2. Cut order if 09-10 slips: launch at login → per-row Hide → Open PRs not on this Mac. Every production type has exactly one owning packet: `GitClient` → 2.1; `branchbar-cli` executable target → 3.2.

| Phase | Packet | Scope | Model | Depends on | Target | Gate |
|---|---|---|---|---|---|---|
| 0 | 0.0 | Tooling: upgrade codex CLI (0.142.3 rejects `gpt-5.6-sol`), re-run codex Challenge for a cross-vendor pass. **Hannah**: message Andrew Lisy asking whether JobRunner opened on NYT-managed Macs and what they clicked; line up the NYT tester and their macOS version | orchestrator / Hannah | — | 09-02 | |
| 0 | 0.1 | Repo bootstrap: `gh repo create hannahstulberg/branchbar --public`, clone to `~/branchbar`, docs skeleton, `.gitignore`, `Makefile`, CI stub (both jobs, `macos-15` pinned) | orchestrator | — | 09-02 | |
| 0 | 0.2 | **Spike** (every verdict → DECISION-LOG with verbatim commands/output): (1) 20-line `MenuBarExtra` app builds with `swift build` on CLT for arm64; (2) x86_64 `--triple` cross-build + `lipo`, triple string + `otool` minos recorded; (3) one `@Test` under `swift test --disable-xctest --enable-swift-testing`; (4) minimal `bundle.sh` + `make install` + `open`: menu bar item, no Dock icon, log written; (5) `SMAppService.register()` status from `/Applications`; (6) quarantine rehearsal matches README text; (7) `.window` MenuBarExtra re-runs `onAppear` per open; (8) deny a TCC prompt on Documents, then pick that folder via `NSOpenPanel`, record whether the scan reads it; (9) rebuild + re-sign ad-hoc, record whether TCC re-prompts; (10) push from Cursor's Source Control UI, confirm an `update by push` line lands in the reflog file | opus | 0.1 | 09-03 | **Gate 0 (stop gate)**: 1, 3, 4, 6, 7, 10 pass. If 1 fails → Hannah installs Xcode that day, rerun. 2, 5, 8, 9 recorded with the fallback chosen |
| 0 | 0.3 | **Spike zip for NYT**: the 0.2 app plus a "Check GitHub CLI" button (runs `gh auth status` via `ToolLocator` with the frozen gh env, shows stdout/stderr and the path searched), an "Add folder…" button (`NSOpenPanel`, then lists `.git` dirs found under it, to exercise TCC), a version label; `make zip`; quarantine it; upload as a pre-release `v0.0.1-spike`; one-paragraph install note for the tester | opus | 0.2 | 09-03 | **Gate 0b (stop gate, 09-04)**: NYT tester on a managed Mac, non-admin account: downloads via the intended channel, installs and launches in < 2 min, relaunches after reboot, opens a rebuilt zip, Add folder… on Documents shows repos, Check GitHub CLI reports authenticated (or the exact failure). Fail with no IT path → menu bar app stops; CLI fallback |
| 1 | 1.1 | Freeze contracts: all §5 types, protocols, `Package.swift`, test doubles, `Fixture` loader, `scripts/record-fixtures.sh` + `make record-fixtures`, **run every §5 invocation live and commit the recorded fixtures**, the two live-repo sanity tests, stubs with OWNER comments, import-ban tests | opus | 0.2 | 09-04 | **Gate 1.1**: every frozen invocation ran on this repo with `/usr/bin/git` and returned the documented shape (rows where rows are expected; `[]` allowed for PR lists and empty reflogs); synthetic fixtures for multi-worktree, no-branch worktree, bare, locked, prunable, ahead/gone, mixed PR states, fork PR, duplicate heads, GHE remote, 401/rate-limit stderr, empty/deletion/fetch-only/delete-then-recreate reflog files |
| 4 | 4.0 | UI contract: `docs/UI-CONTRACT.md`, generated `Strings.swift`, `UserFacingFailure` copy per reason, fixture snapshots per state | opus | 1.1 | 09-05 | **Gate 4.0**: every §5a state has a literal string; Hannah reads the string table (async, by 09-06) |
| 2 | 2.1 | `GitClient` + git parsers: `ForEachRefParser`, `WorktreeListParser`, `ReflogFileReader` (deletion boundary, lineage check) + `ReflogParser` fallback. Acceptance tests authored by a separate agent first | opus (test author) + opus (implementer) | 1.1 | 09-08 | |
| 2 | 2.2 | `PushInfoDeriver`, `PRStatusMapper`, `PRListDecoder`, `SnapshotPresenter` over `Strings.swift` | opus | 1.1, 4.0 | 09-08 | |
| 2 | 2.3 | `GHClient`: per-host auth, recent-100 list, per-head fallback with cap and `notChecked` for the remainder, author list keyed by owner+branch, PR cache TTL, rate-limit mapping. Separate test author | opus + opus | 1.1 | 09-08 | |
| 2 | 2.4 | `RepoScanner`: home BFS depth 6 with hidden-dir + literal skip list, extra roots recursive with no limit, `.git` file classification, dedupe, unreadable/depth-cut/hidden reporting. Separate test author | opus + opus | 1.1 | 09-08 | |
| 2 | 2.5 | `ToolLocator` (+ version), `ProcessCommandRunner` (concurrent draining, timeout, cancellation kills child), `FileCacheStore` (atomic) | opus | 1.1 | 09-08 | **Gate 2**: `swift test` green; every 2.x packet has a red SHA that fails; both pipe-buffer tests blocking |
| 3 | 3.1 | `RepoAssembler` + `RepoLoader`: join rules, three groups, per-stage isolation | opus | 2.1, 2.2, 2.3 | 09-09 | |
| 3 | 3.2 | `RefreshCoordinator`: coalescing, cap 4, deadline, cancellation kills children, stable order, lazy PR (expanded + top 5), progressive emit, cache persist; **`branchbar-cli` executableTarget** (`snapshot` prints the Snapshot as a table and JSON; the Gate 3 harness and the Gate 0b fallback). Separate test author for deadline/cancellation | opus + opus | 3.1, 2.4, 2.5 | 09-09 | **Gate 3**: `branchbar-cli snapshot` matches a hand-checked table for 3 repos, identically with `BRANCHBAR_GIT=/usr/bin/git`; on a busy repo (> 100 PRs, > 20 unmatched local branches) a cold expanded refresh returns honest results inside 45 s with measured call count and wall time recorded |
| 4 | 4.1 | SwiftUI shell over `SnapshotVM`: sections with collapse, four groups, Not-scanned row + skipped summary, PR-not-loaded and not-checked notices, footer with scan roots, **Add folder…** (moved here so the Gate 5 zip carries the TCC rescue); keyboard + VoiceOver; light + dark; on-open trigger | opus | 3.2, 4.0, 0.2 | 09-10 | |
| 5 | 5.1a | **First release zip**: arm64 `bundle.sh`, `make zip`, tag `v0.9.0`, Release with zip + sha256 + the install note refined from the Gate 0b report | opus | 4.1 | **09-10** | Zip URL sent to the NYT tester |
| 5 | — | **Gate 5 (by 09-12)**: NYT tester opens `v0.9.0` on the managed Mac with the install note only and runs the checklist: repos appear; PR pills load for an expanded repo; `Check GitHub CLI` equivalent (footer tool status) reports authenticated; Add folder… recovers a TCC-denied folder; a merged branch appears under Merged with the base-ref copy; refresh finishes inside the deadline on VPN. Each item pass/fail recorded in DECISION-LOG | Hannah / NYT | 5.1a | **by 09-12** | continue / cut decision |
| 4 | 4.2 | Actions: Open in Cursor → VS Code → Terminal, open PR, Finder, copy path, per-row Hide, Open-Terminal `gh auth login` setup action, launch-at-login | opus | 4.1 | 09-13 | **Gate 4**: one screenshot per §5a state from fixtures, reviewed by Hannah; every action works on a real Agents-mode worktree |
| 5 | 5.1b | Packaging hardening: icns, CI green on both jobs, tag `v1.0.0` (arm64 only) | opus | 4.2, Gate 5 | 09-16 | |
| 5 | 5.2 | README as product surface: trust paragraph first, install steps with screenshots of the real macOS 15 dialogs (from the NYT tester's report), gh prerequisite, `shasum -c`, `xattr` footnote, TCC re-prompt note if spike 9 said so; ARCHITECTURE.md with file:line refs, DECISION-LOG, CLAUDE.md front door | opus | 5.1b | 09-17 | **Gate 5b**: NYT tester or a second non-Hannah user installs `v1.0.0` from the Release URL with the README only |

Dispatch DAG: after 1.1 lands, four lanes run concurrently: 4.0; A `2.1 → 3.1`; B `2.3`; C `2.4 + 2.5`; 2.2 joins lane A once 4.0 lands. 3.1 and 3.2 sequential (shared files). Gate 2's only criterion is red-SHA verification, not a test count.

## §9 Risks and failure modes

| Risk / codepath | Likelihood | Test covers | User sees | Mitigation |
|---|---|---|---|---|
| arm64 SwiftUI does not link on CLT | low (`.tbd` has arm64; interface fallback untested) | spike 1 | n/a | Xcode install same day; CLT job in CI thereafter |
| MDM blocks Open Anyway on NYT Macs (Apple documents that MDM can disable the override) | unknown | **Gate 0b, 09-04, with the spike zip** | dialog | Andrew question 09-02; stop decision on 09-04 before real code; CLI fallback |
| GUI-launched `gh` cannot authenticate (keyring vs `GH_TOKEN`, SSO, GHE host) | medium | Gate 0b Check GitHub CLI | per-reason copy + Open Terminal action | keyring auth named as the supported path in the README |
| Unqueried branch shown as "no PR" | was certain | yes | "PR status not checked yet" | `notChecked` state |
| Push before delete/recreate attributed to the new branch | was possible | yes | correct observation | deletion boundary + lineage check |
| Reflog file present but empty / deletion-only / expired | certain for some rows | yes | honest fallback wording | usable-line predicate, `reflog show` without `--` |
| Fallback push date misread as observation | was certain | yes | "Last push unknown · newest commit dated…" | wording test |
| `gh` not found from GUI PATH | certain without mitigation | yes | per-reason copy | `ToolLocator` |
| Pipe deadlock on > 64 KB stdout | certain on big repos | yes (blocking) | would be a 25 s timeout | concurrent draining |
| Older PR outside the recent-100 window | high on busy repos | yes | correct pill | per-head fallback, cap 20 |
| Fork PR filtered out | was certain | yes | correct pill | match by head first |
| Cold first refresh exceeds 45 s on VPN | medium | yes | "PR status loads when expanded" | lazy PR fetch |
| TCC re-prompt after every ad-hoc rebuild | medium | spike 9 | Not-scanned row reappears | README note; Add repository… |
| Home scan misses repos | low after depth 6 + hidden skip | yes | Not-scanned row, empty-state copy | Add repository… |
| Schedule vs 09-24 | medium | — | — | first zip 09-10, Gate 5 by 09-12, ordered cut list |

## §10 Plan persistence

In `~/branchbar`: `PLAN.md`, `docs/UI-CONTRACT.md`, `ARCHITECTURE.md`, `DECISION-LOG.md`, `SESSIONS.md`, `SESSION-HANDOFF.md`, `CLAUDE.md`, `session-logs/`. Scratch copies in `~/.claude/plans/` are not durable.

## §11 Documentation framework

Docs are deliverables with typed roles, from the `coding-project` templates. One doc per subject; when code and a doc disagree it is a bug in one of them, resolved explicitly and logged.

| File | Role | Written | Updated when |
|---|---|---|---|
| `CLAUDE.md` | Front door for any future session or NYT engineer: what it is, how to build/test/run/ship, doc map, the three seams, the frozen-invocation rule | 0.1 skeleton; final in 5.2 | any new command, target, or doc |
| `README.md` | 2-line stub pointing at CLAUDE.md plus the install section (the only user-facing doc) | 5.2 | releases |
| `PLAN.md` | The contract (this file, § numbering stable). Roadmap rows get a Status column once execution starts | 0.1 | packet accepted, gate passed, scope cut |
| `ARCHITECTURE.md` | How it works, current truth. §1 system diagram, §2 key flows, §3 anatomy table with `file:line`, §4 data model, §5 testing, §6 operations (launch path, log path), §7 security contract, §8 known footguns (prose, only traps that actually bit) | 1.1 skeleton with §1/§4 from the contracts; §3 fills as packets land | **every edit pass that shifts line numbers re-derives every `file:line` before commit** (a script `make doc-refs` greps each anatomy row's symbol and fails on a stale line) |
| `DECISION-LOG.md` | Why it changed, newest first: What / Why / Limits / Cost accepted / Deliberately not changed / Session. Every spike verdict, every review finding fixed-deferred-rejected, every cut | 0.2 first entries | any decision |
| `docs/UI-CONTRACT.md` | State table, string table, hierarchy, tokens; mirrors `Strings.swift` | 4.0 | any string or state change (compile error if `Strings.swift` drifts; the doc is regenerated from it by `make doc-strings`) |
| `docs/TEST-PLAN.md` | The named invariants from §7 mapped to test files, fixture inventory (recorded vs synthetic), how to re-record | 1.1 | new invariant or fixture |
| `docs/runbooks/` | Multi-step recovery procedures (re-record fixtures after a git upgrade, TCC reset, quarantine rehearsal) that §6 Operations points at | as they are needed | when a procedure changes |
| `SESSIONS.md` | Ledger: one row per session, local UUID, what happened, distilled log path | 0.1 | every commit |
| `SESSION-HANDOFF.md` | Restart state under one screen: packet in flight, suite count, agents, blocked-on, next steps, re-read order | 0.1 | packet accepted, gate passed, agent dispatched, before every commit |
| `session-logs/` | Distilled per-session log beside the auto-archived transcript (global hook) | every commit | append |

**Mermaid diagrams** live in ARCHITECTURE.md as source (never exported images), one per mechanism someone must understand to edit safely:

1. §1 system graph (the §4 diagram above, with trust boundary): components and the three seams.
2. §2 refresh sequence: `AppModel → RefreshCoordinator → RepoLoader → git/gh → assemble → emit`, showing coalescing, the 45 s deadline, and lazy PR fetch.
3. §2 push-time decision tree: reflog file → usable line? → `reflog show` → tip commit date → wording.
4. §2 scan classification flowchart: `.git` dir / `.git` file → worktree checkout / submodule / candidate → dedupe.
5. §2 PR matching flowchart: recent-100 → head match → owner disambiguation → per-head fallback → cache.
6. PLAN.md §8 packet DAG as a `graph LR` so dispatch order is visual.

Diagram rules: colons over em dashes in labels; capitalize the first word of every node; a diagram changes in the same commit as the code it describes; the gstack `diagram` skill renders an SVG only when a doc is being handed to someone outside the repo.

**How a future edit flows** (the contract CLAUDE.md states): read `SESSION-HANDOFF.md` → find the mechanism in ARCHITECTURE.md §3 → red test → green → update the diagram if the mechanism changed → `make doc-refs` → DECISION-LOG entry → handoff refresh → `/commit-push`. A change that adds a user-facing string edits `Strings.swift` and regenerates UI-CONTRACT; a change that adds a git invocation adds it to `record-fixtures.sh` and re-records.

**ARCHITECTURE.md §8 footguns seeded from this plan**: `%1f` is not a reflog separator; `reflog show` silently ignores `--`; the GUI PATH has no Homebrew; `%(upstream:track)` is empty for two different reasons; reflog files can exist and be empty; `headRepositoryOwner` is an object; a SwiftPM `resources:` declaration breaks the `.app` layout; `main.swift` breaks `@main`.

---
## Review log

| Date | Reviewer | Outcome |
|---|---|---|
| 2026-09-01 | gstack plan-design-review (headless, 1.58.5) | 4 blockers, 10 major, 5 minor; all adopted except idle filter (dropped). UI contract packet, Add repository…, Open in Cursor, Merged group, a11y, README as product surface. |
| 2026-09-01 | gstack plan-eng-review (headless, 1.58.5) | 6 blockers verified and fixed (`%x1f`, tools-version 6.0, `macos-15`, minimal bundler in 0.2, `SnapshotPresenter`, PR cache); 10 major + 8 minor adopted; rejected folder-picker-first and cutting launch-at-login. |
| 2026-09-01 | codex Challenge (cross-vendor, codex-cli 0.152.1, gpt-5.6-sol, high) | Verdict **KILL** (steelman: teach shell commands / ship a script). 5 blockers, 5 major, 2 minor. Verified and adopted: managed-Mac distribution + GUI `gh` auth + TCC moved to **Gate 0b with the spike zip (packet 0.3, 09-04)** as the real stop gate; `notChecked` PR state (never map unqueried to `none`); open-elsewhere keyed by owner+branch; API cost/wall-time measurement in Gate 3; "Pushed from this Mac" wording, deletion-boundary rule, lineage check, 90/30-day expiry, acceptance cases for other-machine/fresh-clone/force-push/recreate; product promise changed from "every repo" to "found or added", Add folder… as recursive scan roots, skipped-categories summary, bare repos out of scope; `GitClient` owner (2.1), `branchbar-cli` target (3.2), Add folder… into 4.1 so the Gate 5 zip carries it, Gate 1.1 wording, Gate 5 checklist, presenter/grouping boundary, critical path includes 2.4/2.5; arm64-only until an Intel test exists; "Merged into `<base>`; no later local commits" replaces "safe to delete"; "Upstream missing from last-known origin"; separate test-author and implementer agents for the four high-risk semantics; `GH_PROMPT_DISABLED`/`GH_NO_UPDATE_NOTIFIER`/`GH_PAGER`/`NO_COLOR` frozen; research ledger corrected (`SwiftUI.tbd` has arm64; reflog 90/30). **Rejected**: KILL itself (Hannah decided handout; the distribution risk codex names is now tested on 09-04 before real code, and the CLI harness is the documented fallback); "cheaper models for parsers" (Hannah asked for Opus). |
| 2026-09-01 | Adversarial review, **fresh-context Opus fallback (same-family, not cross-vendor)** | 5 blockers, 7 major, 5 minor. All five blockers verified on this machine and fixed: `reflog show` without `--` + live-repo test; usable-line predicate with empty/deletion/expiry cases; fallback wording no longer claims observation; CLT decision made explicit with a stop rule and CLT CI job; Gate 5 rewritten as an NYT-managed-Mac test by 09-12 with the first zip on 09-10 and a demo fallback. Majors adopted: per-head PR fallback, head-first matching with `.login`, Merged vs Closed-unmerged with `headRefOid` check, depth 6 + hidden-dir skip + literal skip list, TCC spike items, 4.0 on the critical path, `Strings.swift` generated, test count dropped from Gate 2, recorded fixtures via script, lazy PR fetch. Steelman ("teach the shell commands instead") answered by Hannah: handout, NYT tests first. |
| | Hannah | pending |
