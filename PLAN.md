# PLAN — BranchBar

Session: `cced85a0-5ced-4282-bc94-e23dcbe42d18` (local resume UUID). Workflow: `coding-project` skill (Opus orchestrator, delegated implementers, red/green TDD, Gate 1 plan review before any code). Today: 2026-09-01. Fixed date: NYT GitHub Fundamentals session **Thu 2026-09-24**.

## §1 Context & goal

NYT PMs and designers use Claude Code through AWS Bedrock inside Cursor/VS Code. They have no Claude desktop app, so they lack its branch/worktree picker and status view. Hannah teaches branches and worktrees on Sept 24 (workshop Blocks 3, 6, 7: branches, worktrees, "distinguish work that is active, ready for review, merged, or abandoned") and wants a small macOS menu bar app that shows every cloned repo, its branches and worktrees, each branch's PR state, when it was last pushed, and which branches are merged and safe to clean up. It is a **handout**: attendees install it from a zip, the same way Andrew Lisy's JobRunner (Electron, electron-builder, ad-hoc signed, unnotarized, `LSUIElement`) was handed to the same audience. NYT tests the zip on a managed Mac before the workshop.

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
| `swift build` (CLT only) links SwiftUI for arm64 | **the one unproven link**: CLT SDK ships SwiftUI/AppKit interfaces for `arm64e` and `x86_64` only; arm64 relies on the compiler's arm64→arm64e fallback. `Testing.framework` has plain arm64 and lives outside the SDK at `CommandLineTools/Library/Developer/Frameworks/` | verified; **packet 0.2 spike decides; Xcode install is the fallback** |
| XCTest under CLT | absent; Swift Testing only | verified |
| `@main` in SPM executable | SwiftPM adds `-parse-as-library` when no `main.swift` exists | confirm in spike |
| Universal binary on CLT | two `--triple` builds + `lipo`; exact triple recorded by spike | SDK has x86_64 tbds |
| `SMAppService` with ad-hoc signature | unverified: spike | LaunchAgent fallback |
| CI runner | `macos-15` (Swift 6.1.2). Runner has full Xcode, so a second job runs `sudo xcode-select -s /Library/Developer/CommandLineTools` before `make test build` to keep the CLT path under continuous test | runner-images |
| Gatekeeper on macOS 15 | open once → System Settings → Privacy & Security → Open Anyway | rehearsable locally |
| TCC from an ad-hoc app | **unverified: spike** whether an `NSOpenPanel` pick after a denied prompt grants recursive read, and whether a rebuilt ad-hoc binary re-prompts | packet 0.2 items 8–9 |
| Agents-mode worktrees | `<repo>/.claude/worktrees/<name>`, branch `worktree-<name>` | code.claude.com/docs/en/worktrees |
| Web-session branches | `claude/<slug>-<id>` on GitHub only | this repo's remote refs |
| Local push timestamp | `<git-common-dir>/logs/refs/remotes/<remote>/<branch>` lines `old new author <email> unixtime tz\tupdate by push`. **Files can exist and be empty** (`origin/updates-3-29-26` here, 0 bytes); `push --delete` writes a line with an all-zero new OID; lines expire at 90 days | verified |
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
- **Handout, NYT-tested.** Hannah has an NYT person open the zip on a managed Mac before the workshop. The first arm64 zip therefore lands **by Sept 10** so that test can happen by Sept 12. If it fails, the app becomes a demo and packet 5.2's install section is cut; workshop Block 7 stands on `git branch` / `git worktree list` regardless.
- **Stack** Swift + SwiftPM only, SwiftUI `MenuBarExtra(.window)`, macOS 13+. Why: Claude Code extends either stack equally; with readability off the table, 2 MB zip, native menu, and no Node build dependency win.
- **Toolchain** Command Line Tools on Hannah's machine; the packet 0.2 spike decides whether arm64 SwiftUI links. **Stop rule**: if spike item 1 fails, Hannah installs Xcode that day (free, ~1 h) and the plan continues unchanged; no AppKit rewrite. CI runs both a full-Xcode job and a CLT-selected job.
- **Distribution** one zipped `.app` (arm64 first; universal only if the cross-build spike passes cheaply), ad-hoc signed, no Developer ID, no sandbox. The README is a product surface (§8 packet 5.2).
- **Repo discovery** (Hannah's decision: "check the repos cloned on their computer"): first launch auto-scans `~` to **depth 6**, skipping every hidden directory (name starts with `.`) except the `.git` marker itself, plus the literal skip list in §5; no descent into a found repo; cached; Rescan button. Plus **"Add repository…"** (`NSOpenPanel`, persisted) as the primary action of the zero-repos state and the rescue for deeper repos, `~/Library/CloudStorage`, or a declined TCC prompt. Unreadable folders appear as a visible "Not scanned: Documents, Desktop" row with a button that re-triggers access. Worktrees via `git worktree list --porcelain`; worktree checkouts and submodules never listed as repos; dedupe by `git rev-parse --git-common-dir`. `descendIntoRepos` is a constant `false`.
- **PR status** via `gh` only. Host from `remote.origin.url`; `gh auth status --hostname <host>` once per distinct host per refresh; failure → every branch `.unavailable` with per-reason copy and one action. No `--search`. **PR matching is by `headRefName` first**; `headRepositoryOwner.login` only disambiguates collisions, never excludes (fork workflows must match). Branches with no match in the 100-most-recent list get a per-branch `--head <name>` query, capped at 20 per repo per refresh.
- **Lazy PR fetching.** A refresh always runs git for every repo (local, fast). `gh` runs only for expanded repos plus the 5 most recently active; collapsed repos show "PR status loads when expanded". PR results cached per repo in `CacheFile`, TTL 10 min; "Refresh PRs now" bypasses it. Rate-limit responses map to `rateLimited` with copy that says waiting fixes it.
- **"Open PRs not on this Mac" group** per repo from `gh pr list --author @me --state open` for heads with no local branch; PR state + link only. No `git fetch`, ever.
- **"Merged" and "Closed without merging" groups** per repo (never one "clean up" bucket): Merged = PR merged **and** local `tipSHA == headRefOid` (no commits after the merge) and no worktree, copy "Merged into main. Safe to delete this branch." Closed without merging = PR closed unmerged, copy "PR closed without merging. This branch may hold work that was never merged." The app deletes nothing.
- **Last pushed** from the reflog file: the newest `update by push` line whose new OID is non-zero. Fallback when there is **no usable line** (file absent, empty, fetch-only, deletion-only, expired): remote-tip committer date, labelled honestly as a commit date, not an observation: "You pushed 2 days ago" (reflog) vs "**Last push unknown · newest commit dated 2 days ago**" (fallback). Mechanism in the tooltip. `git reflog show` is a secondary fallback and is invoked **without** `--`.
- **Ahead/behind** `behind` never displayed. Ahead renders as "2 ahead of last-known origin", tooltip carries `FETCH_HEAD` mtime. "In sync" vs "no upstream" decided by `upstream:short`, never by the track field.
- **Refresh** on popover open (debounced 30 s) plus manual Refresh that bypasses the debounce. Overall deadline 45 s; unfinished repos marked stale, child processes terminated. Footer shows "Updated 12 s ago" and the version. No background timer. Menu bar icon is a monochrome template SF Symbol that never conveys state.
- **Row actions** primary **Open in Cursor** (`open -a Cursor <path>`; Cursor → VS Code → Terminal; the Cursor-absent case has its own string in §5a). Secondary: open PR, reveal in Finder, copy path.
- **Launch at login** in v1, opt-in toggle; `SMAppService` if the spike passes, LaunchAgent fallback. Last in packet 4.2 and first cut.
- **Vocabulary** workshop words only (repo, branch, worktree, PR, push). "Detached" → "Worktree at commit abc1234 (no branch)"; upstream gone → "Branch deleted on GitHub".
- **Strings are code.** Packet 4.0 emits `Sources/BranchBarCore/Strings.swift` (one `enum Strings` with every user-facing string as a static); `SnapshotPresenter` and the views consume it. Drift between the string table and the presenter is a compile error.
- **Fixtures are recorded, not transcribed.** `make record-fixtures` runs the frozen invocations against real repos with `/usr/bin/git` and `gh` and writes the fixture files; hand-extended cases are separate files marked `synthetic-`. No model transcribes git output.
- **Model rule** Opus for all implementation packets (Hannah's explicit ask). Orchestrator writes no production code.

**NOT in scope for v1**: any `git fetch`; displaying `behind`; in-app update check; idle-days filter; deleting branches or worktrees; non-GitHub hosts; `GH_TOKEN`-only auth via login shell (v1.1); Intel-only testing.

Rejected reviewer proposals: "folder-picker first, scan only granted folders" (Hannah chose auto-discovery; mitigated by Add repository…, Not-scanned row, hidden-dir skip); "cut launch-at-login" (kept on the cut line); "install Xcode now" (spike decides; Xcode is the dated fallback); "demo not handout" (Hannah: NYT tests first).

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
- `PRStatus: none | draft | open | changesRequested | approved | merged | closed | unavailable | notLoaded`
- `PRInfo { number, url, state, isDraft, reviewDecision (empty string ⇒ undecided), mergedAt?, updatedAt, baseRefName, headRefName, headRefOid, headRepositoryOwnerLogin, mergeCommitOid? }`
- `PRAvailability: available | unavailable(PRUnavailableReason, detail?)`; reasons `ghNotInstalled | ghNotAuthenticated(host) | noRemote | notGitHubRemote | rateLimited | commandFailed`
- `PushInfo { lastPushedAt?, source: reflogPush | tipCommitDate | none, hasUpstream, upstreamGone, aheadOfLastKnownRemote: Int?, remoteRefObservedAt: Date? }`
- `ScanPolicy { rootPath, maxDepth = 6, skipHiddenDirectories = true, skipDirectoryNames = ["Library","Applications","Pictures","Movies","Music","Public","node_modules","vendor","Pods","DerivedData","build","dist","target","venv","site-packages","__pycache__","go/pkg"], descendIntoRepos = false }`, `DiscoveredRepo { path, id }`, `ScanResult { policy, scannedAt, repos, candidatesExamined, unreadableDirectories, skippedWorktreeCheckouts, skippedSubmodules }`
- `Snapshot { repos (stable order), refreshedAt?, tools: ToolStatus { gitPath?, gitVersion?, ghPath?, ghAuthByHost } }`
- `RefreshPolicy { debounce 30 s, overallDeadline 45 s, maxConcurrentRepos 4, prCacheTTL 600 s, eagerPRRepoCount 5, perHeadFallbackCap 20 }`
- `UserFacingFailure { title, message, action?, diagnostic }`; `RefreshState: idle(lastRefreshedAt) | running(completed,total) | failed(UserFacingFailure)`
- `RepoError { stage: branches | worktrees | remotes | reflog | github | deadlineExceeded, message }`
- `CacheFile { schemaVersion 1, scan?, manuallyAddedRepos, hiddenRepoIDs, collapsedRepoIDs, prCache: [RepoID: PRCacheEntry { fetchedAt, prs, authorPRs }], lastSnapshot? }`; `CacheStore` writes temp file then `replaceItemAt` (atomic).
- `Command { executable, arguments, workingDirectory?, environment?, timeout }`, `CommandOutput`, `CommandError`, `protocol CommandRunner`; cancellation terminates the child.
- `protocol FileSystem { contentsOfDirectory, fileExists, isExecutableFile, readFile, modificationDate, homeDirectory, pathEnvironment }`
- `enum Strings` (generated by packet 4.0): every user-facing string as a static or static func.
- View-models: `SnapshotVM { sections: [RepoSectionVM], footer: FooterVM, emptyState: EmptyStateVM? }`, `RepoSectionVM { title, isCollapsed, active: [BranchRowVM], openElsewhere: [PRRowVM], merged: [BranchRowVM], closedUnmerged: [BranchRowVM], prNotice?, notScannedNotice? }`, `BranchRowVM { title, worktreeMarker, prPill: (text, status), pushLabel, pushTooltip, aheadLabel?, primaryAction, accessibilityLabel }`, `FooterVM { updatedLabel, version, toolNotice? }`.

Exact invocations (env `LC_ALL=C`, `GIT_OPTIONAL_LOCKS=0`, `-C <repo>`; U+001F separator). `--` is used **only** where verified to work (`for-each-ref`); never with `reflog show`.

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

Last push (`ReflogFileReader`): read `<git-common-dir>/logs/refs/remotes/<remote>/<branch>`; a **usable line** is one whose message (after the tab) starts with `update by push` and whose new-OID field is not all zeros; take the newest usable line's unix timestamp (field 5). No usable line (file absent, empty, fetch/pull-only, deletion-only) → try `git reflog show` (above) → else `source = .tipCommitDate` from the remote-tracking tip. `%gd` under `--date=unix` yields `origin/main@{<unixtime>}`; timestamp is extracted from inside the braces.

Join rules: exact branch name; worktrees without a branch never join; PR match by `headRefName`, `headRepositoryOwnerLogin` disambiguates only when several PRs share a head (prefer same owner, then OPEN, then latest `updatedAt`, sorted client-side); "Open PRs not on this Mac" = author-@me PRs whose head has no local branch; `merged` group = `prStatus == merged && tipSHA == headRefOid && worktreePath == nil`; `closedUnmerged` = `prStatus == closed`. Timeouts: git 10 s, `gh auth status` 10 s, `gh pr list` 25 s, overall 45 s.

`ToolLocator` order: `BRANCHBAR_GIT`/`BRANCHBAR_GH` env → `/opt/homebrew/bin` → `/usr/local/bin` → `~/.local/bin` → `/opt/local/bin` → PATH → (git only) `/usr/bin/git` iff `xcode-select -p` resolves. Records `git --version`; below 2.39 → tool notice.

### §5a UI contract (frozen in packet 4.0)

`docs/UI-CONTRACT.md` plus the generated `Strings.swift`, before any SwiftUI:

1. **State table** with the literal string for: first run while scanning; zero repos (primary action Add repository…, names Drive/Dropbox and deep folders); Not-scanned folders row; gh not installed; gh not signed in (per host); rate limited; no GitHub remote; one branch, no PR, never pushed (the modal NYT case); PR status not loaded (collapsed repo); `gh pr list` timeout; one repo failed; deadline exceeded; stale rows at launch; git older than 2.39; Cursor not installed; last push unknown (fallback wording).
2. **String table** for every row type and group heading, workshop vocabulary only.
3. **Row hierarchy**: worktree marker leading; branch name primary; PR pill secondary (text + color); push line and ahead count tertiary. Groups per repo: Branches and worktrees → Open PRs not on this Mac → Merged → Closed without merging. Repo order most-recently-active first, computed once; rows fill in but never reorder mid-refresh.
4. **Token table**: width 340, max height 70% of screen with internal scroll, row height, type scale, 9 `PRStatus` colors in light and dark, per-repo collapse persisted (default expanded when one repo, otherwise only the most recent).

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
- Named invariant tests: `reflogShowFallbackReturnsRowsForARefThatHasPushes` (live repo), `everyFrozenGitInvocationReturnsOutputOnThisRepo` (live repo), `reflogFieldsSplitOnUnitSeparatorNotLiteralPercent1f`, `reflogFileLastUsablePushLineParsesUnixTimestampFromField5`, `emptyReflogFileFallsBackToTipCommitDate`, `pushDeletionLineIsNotTreatedAsAPush`, `reflogFileWithOnlyFetchLinesFallsBack`, `fallbackLabelDoesNotClaimGitHubObservedTheBranch`, `inSyncAndNoUpstreamAreDistinguishedByUpstreamShortNotTrack`, `noBranchWorktreeAppearsUnderRepoAndNoBranchClaimsIt`, `ghMissingMakesEveryBranchUnavailableWithoutThrowing`, `authStatusFailureShortCircuitsPRListForAllReposOnThatHost`, `enterpriseHostRemoteResolvesSlugAndAuthPreflightPerHost`, `forkOriginatedPRStillMatchesItsLocalBranch`, `emptyReviewDecisionStringIsNotAReviewDecision`, `branchWithAnOlderPRStillResolvesItsPRStatusViaHeadQuery`, `perHeadFallbackRespectsPerRepoCap`, `firstRefreshDoesNotIssueGhCallsForCollapsedRepos`, `prCacheWithinTTLIssuesNoGhCalls`, `refreshStillUpdatesGitStateWhenPRCacheIsWarm`, `rateLimitResponseMapsToRateLimitedNotCommandFailed`, `prListDecoderSortsByUpdatedAtDescendingRegardlessOfInputOrder`, `reflogPushBeatsTipCommitDate`, `noUpstreamRendersNeverPushedNotZeroCommits`, `aheadCountLabelledRelativeToLastKnownRemoteNotAbsolute`, `branchWithCommitsAfterItsMergeIsNotInMergedGroup`, `closedUnmergedBranchIsNotLabelledMerged`, `openPRsNotOnThisMacExcludesHeadsThatExistLocally`, `hiddenDirectoriesUnderHomeAreSkipped`, `repoAtDepthSixIsFoundAndDepthSevenIsNot`, `gitFilePointingIntoWorktreesIsExcludedAndReported`, `doesNotDescendIntoDiscoveredRepo`, `unreadableDirectoryIsReportedNotSilentlySkipped`, `oneRepoFailingLeavesOthersPopulated`, `peakConcurrencyNeverExceedsCap`, `secondRefreshWhileRunningCoalesces`, `refreshHonorsOverallDeadlineAndMarksUnfinishedReposStale`, `cancelledRepoTasksTerminateTheirChildProcesses`, `rowOrderIsStableAcrossProgressiveEmits`, `commandRunnerReturnsFullOutputWhenStdoutExceedsPipeBuffer` (≥ 1 MB), `commandRunnerDrainsStderrConcurrentlyWithStdout`, `branchNameBeginningWithDashIsPassedAsOperandNotFlag`, `interruptedSaveLeavesPreviousCacheIntact`, `unknownSchemaVersionLoadsNil`, `emptyScanRendersActionableEmptyState`, `unavailableReasonCopyNamesOneActionPerReason`, `everyStringsEntryIsReachableFromSomeState`, `noAppKitOrSwiftUIImportInCore`, `noXCTestImportAnywhere`.
- Swift 6 mode in Core; every Core type `Sendable`. Stubs carry `// OWNER: packet N.N`.

## §8 Roadmap

Critical path (human gates in bold): 0.1 → 0.2 (**Gate 0**) → 1.1 → 4.0 (**Gate 4.0**) → {2.1, 2.2, 2.3} → 3.1 → 3.2 → 4.1 → 4.2 → 5.1 (**first zip 09-10**) → NYT managed-Mac test (**Gate 5, by 09-12**) → 5.2. Cut order if 09-10 slips: launch at login → per-row Hide → Open PRs not on this Mac → universal (arm64 only).

| Phase | Packet | Scope | Model | Depends on | Target | Gate |
|---|---|---|---|---|---|---|
| 0 | 0.0 | Tooling: upgrade codex CLI (0.142.3 rejects `gpt-5.6-sol`), re-run codex Challenge for a cross-vendor pass. **Hannah**: message Andrew Lisy asking whether JobRunner opened on NYT-managed Macs and what they clicked; line up the NYT tester and their macOS version | orchestrator / Hannah | — | 09-02 | |
| 0 | 0.1 | Repo bootstrap: `gh repo create hannahstulberg/branchbar --public`, clone to `~/branchbar`, docs skeleton, `.gitignore`, `Makefile`, CI stub (both jobs, `macos-15` pinned) | orchestrator | — | 09-02 | |
| 0 | 0.2 | **Spike** (every verdict → DECISION-LOG with verbatim commands/output): (1) 20-line `MenuBarExtra` app builds with `swift build` on CLT for arm64; (2) x86_64 `--triple` cross-build + `lipo`, triple string + `otool` minos recorded; (3) one `@Test` under `swift test --disable-xctest --enable-swift-testing`; (4) minimal `bundle.sh` + `make install` + `open`: menu bar item, no Dock icon, log written; (5) `SMAppService.register()` status from `/Applications`; (6) quarantine rehearsal matches README text; (7) `.window` MenuBarExtra re-runs `onAppear` per open; (8) deny a TCC prompt on Documents, then pick that folder via `NSOpenPanel`, record whether the scan reads it; (9) rebuild + re-sign ad-hoc, record whether TCC re-prompts; (10) push from Cursor's Source Control UI, confirm an `update by push` line lands in the reflog file | opus | 0.1 | 09-03 | **Gate 0 (stop gate)**: 1, 3, 4, 6, 7, 10 pass. If 1 fails → Hannah installs Xcode that day, rerun. 2, 5, 8, 9 recorded with the fallback chosen |
| 1 | 1.1 | Freeze contracts: all §5 types, protocols, `Package.swift`, test doubles, `Fixture` loader, `scripts/record-fixtures.sh` + `make record-fixtures`, **run every §5 invocation live and commit the recorded fixtures**, the two live-repo sanity tests, stubs with OWNER comments, import-ban tests | opus | 0.2 | 09-04 | **Gate 1.1**: every frozen invocation returned rows on this repo with `/usr/bin/git`; synthetic fixtures for multi-worktree, no-branch worktree, bare, locked, prunable, ahead/gone, mixed PR states, fork PR, duplicate heads, GHE remote, 401/rate-limit stderr, empty/deletion/fetch-only reflog files |
| 4 | 4.0 | UI contract: `docs/UI-CONTRACT.md`, generated `Strings.swift`, `UserFacingFailure` copy per reason, fixture snapshots per state | opus | 1.1 | 09-05 | **Gate 4.0**: every §5a state has a literal string; Hannah reads the string table (async, by 09-06) |
| 2 | 2.1 | Git parsers: `ForEachRefParser`, `WorktreeListParser`, `ReflogFileReader` (usable-line predicate) + `ReflogParser` fallback, `GitHubSlug` | opus | 1.1 | 09-08 | |
| 2 | 2.2 | `PushInfoDeriver`, `PRStatusMapper`, `PRListDecoder`, `SnapshotPresenter` over `Strings.swift` | opus | 1.1, 4.0 | 09-08 | |
| 2 | 2.3 | `GHClient`: per-host auth, recent-100 list, per-head fallback with cap, author list, PR cache TTL, rate-limit mapping | opus | 1.1 | 09-08 | |
| 2 | 2.4 | `RepoScanner`: BFS depth 6, hidden-dir + literal skip list, `.git` file classification, dedupe, unreadable-dir reporting, manually added repos | opus | 1.1 | 09-08 | |
| 2 | 2.5 | `ToolLocator` (+ version), `ProcessCommandRunner` (concurrent draining, timeout, cancellation kills child), `FileCacheStore` (atomic) | opus | 1.1 | 09-08 | **Gate 2**: `swift test` green; every 2.x packet has a red SHA that fails; both pipe-buffer tests blocking |
| 3 | 3.1 | `RepoAssembler` + `RepoLoader`: join rules, three groups, per-stage isolation | opus | 2.1, 2.2, 2.3 | 09-09 | |
| 3 | 3.2 | `RefreshCoordinator`: coalescing, cap 4, deadline, stable order, lazy PR (expanded + top 5), progressive emit, cache persist | opus | 3.1, 2.4, 2.5 | 09-09 | **Gate 3**: `branchbar-cli snapshot` matches a hand-checked table for 3 repos, identically with `BRANCHBAR_GIT=/usr/bin/git` |
| 4 | 4.1 | SwiftUI shell over `SnapshotVM`: sections with collapse, four groups, Not-scanned row, PR-not-loaded notice, footer; keyboard + VoiceOver; light + dark; on-open trigger | opus | 3.2, 4.0, 0.2 | 09-10 | |
| 5 | 5.1a | **First zip**: arm64 `bundle.sh`, `make zip`, tag `v0.9.0`, Release with zip + sha256 + a one-paragraph install note | opus | 4.1 | **09-10** | Zip URL sent to the NYT tester |
| 4 | 4.2 | Actions: Open in Cursor → VS Code → Terminal, open PR, Finder, copy path, Add repository…, per-row Hide, launch-at-login | opus | 4.1 | 09-12 | **Gate 4**: one screenshot per §5a state from fixtures, reviewed by Hannah; every action works on a real Agents-mode worktree |
| 5 | — | **Gate 5: NYT tester opens `v0.9.0` on a managed Mac using only the install note, reports what they clicked and whether repos appeared.** Pass → handout continues. Fail (MDM blocks) → app becomes a demo; 5.2 install section cut; Block 7 stands on git commands | Hannah / NYT | 5.1a | **by 09-12** | stop/continue decision recorded in DECISION-LOG |
| 5 | 5.1b | Packaging hardening: universal if spike 2 passed, icns, CI green on both jobs, tag `v1.0.0` | opus | 4.2, Gate 5 | 09-16 | |
| 5 | 5.2 | README as product surface: trust paragraph first, install steps with screenshots of the real macOS 15 dialogs (from the NYT tester's report), gh prerequisite, `shasum -c`, `xattr` footnote, TCC re-prompt note if spike 9 said so; ARCHITECTURE.md with file:line refs, DECISION-LOG, CLAUDE.md front door | opus | 5.1b | 09-17 | **Gate 5b**: NYT tester or a second non-Hannah user installs `v1.0.0` from the Release URL with the README only |

Dispatch DAG: after 1.1 lands, four lanes run concurrently: 4.0; A `2.1 → 3.1`; B `2.3`; C `2.4 + 2.5`; 2.2 joins lane A once 4.0 lands. 3.1 and 3.2 sequential (shared files). Gate 2's only criterion is red-SHA verification, not a test count.

## §9 Risks and failure modes

| Risk / codepath | Likelihood | Test covers | User sees | Mitigation |
|---|---|---|---|---|
| arm64 SwiftUI does not link on CLT | medium (the one unproven link) | spike 1 | n/a | Stop gate; Xcode install same day; CLT job in CI thereafter |
| MDM blocks Open Anyway on NYT Macs | unknown | Gate 5 by 09-12 | dialog | Andrew question 09-02; demo fallback decided at Gate 5, not on the day |
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
| 2026-09-01 | codex Challenge | **did not run**: codex CLI 0.142.3 rejects its configured model. Rerun scheduled in packet 0.0. |
| 2026-09-01 | Adversarial review, **fresh-context Opus fallback (same-family, not cross-vendor)** | 5 blockers, 7 major, 5 minor. All five blockers verified on this machine and fixed: `reflog show` without `--` + live-repo test; usable-line predicate with empty/deletion/expiry cases; fallback wording no longer claims observation; CLT decision made explicit with a stop rule and CLT CI job; Gate 5 rewritten as an NYT-managed-Mac test by 09-12 with the first zip on 09-10 and a demo fallback. Majors adopted: per-head PR fallback, head-first matching with `.login`, Merged vs Closed-unmerged with `headRefOid` check, depth 6 + hidden-dir skip + literal skip list, TCC spike items, 4.0 on the critical path, `Strings.swift` generated, test count dropped from Gate 2, recorded fixtures via script, lazy PR fetch. Steelman ("teach the shell commands instead") answered by Hannah: handout, NYT tests first. |
| | Hannah | pending |
