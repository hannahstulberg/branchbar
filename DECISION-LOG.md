# DECISION LOG — BranchBar

<!-- Newest first. What / Why / Limits / Cost accepted / Deliberately not changed / Session. -->

## 2026-09-02 — Phase 2 lanes: 2.4, 2.5, 2.3 green; one test-author error corrected by the orchestrator

- **What:** Accepted green(2.4) 9835132 (scanner; `scan` became async and gained defaulted `commandRunner`/`gitExecutable` init params so tests stayed untouched), green(2.5) 770140c (runner drains both pipes on dedicated threads, timeout and cancellation SIGTERM then SIGKILL, cache store writes via `replaceItemAt`), green(2.3) (GHClient with the batch `pullRequests(slug:unmatchedHeads:)` entry point: heads past the cap are absent from the result, which is what renders `notChecked`). In `PRStatusMapperTests.openPRsNotOnThisMacExcludesHeadsThatExistLocally` the test author expected PR 104 (`needs-changes`, no local head) to be excluded; PLAN.md §5 keeps it. The orchestrator changed the expected set to `[102, 103, 104, 109]`; the implementer did not touch the test.
- **Why:** Separate test authors catch implementer bias; this round the error was on the test side, caught because the implementer refused to edit the test and reported the conflict instead.
- **Limits:** The frozen `GHClient` surface has no "Refresh PRs now" bypass yet; packet 3.1/3.2 adds a `force` path. `Command.environment` is merged over the inherited environment (implementer's reading; the seam doc comment says "replaces" and will be corrected in the 3.x docs sync). Packet 2.5's red SHA fails by missing symbols (`RealFileSystem`, `GitVersion`), not an OWNER trap.
- **Cost accepted:** A non-compiling test target on local main for ~1 hour between red(2.3) and green(2.3); nothing was pushed in that window.
- **Deliberately not changed:** `CacheFile.prCache` stays keyed by `RepoID` (encodes as an alternating array; round-trip tested).
- **Session:** `cced85a0-5ced-4282-bc94-e23dcbe42d18`

## 2026-09-01 — Packet 1.1: contracts frozen, 19 recorded fixtures, 43 tests green

- **What:** Every PLAN.md §5 type under `Sources/BranchBarCore/Models/`, the three seams under `Seams/`, 16 stub components with 68 `OWNER:` fatalError sites, test doubles, `Fixture` loader, `scripts/record-fixtures.sh` (19 byte-exact recordings from `/usr/bin/git` 2.39.5 and `gh` 2.89.0; fails non-zero on empty output where rows are expected, including `[]`), 15 synthetic fixtures each with a sibling `.md` header, two live-repo sanity tests (skip on CI with a reason), three structural guards, `docs/TEST-PLAN.md` mapping all 59 §7 invariants.
- **Why:** Later packets code against types, not each other; fixtures are ground truth from real tools, not model transcription.
- **Limits:** Stubs live flat under `Sources/BranchBarCore/` (not `Git/`, `GitHub/` subfolders as §4 sketches); packet specs address the flat files. `CacheFile.prCache` keyed by `RepoID` encodes as an alternating array under `JSONEncoder`; round-trip tested, packet 2.5 may switch to a string key.
- **Cost accepted:** `TimeInterval` not `Duration` (Codable); `PRAvailability: Error` so `GHClient` returns `Result`; `FileSystem` synchronous.
- **Deliberately not changed:** `ToolLocator.swift` and `SpikeChecks.swift` (packet 0.3's). `Package.swift` final. The live reflog test also pins that `reflog show -- <ref>` still returns zero rows, so the CLAUDE.md footgun cannot go stale silently.
- **Session:** `cced85a0-5ced-4282-bc94-e23dcbe42d18`

## 2026-09-01 — Packet 0.3: spike zip published as v0.0.1-spike; Gatekeeper dialog observed; keyring gh works from a GUI process

- **What:** `dist/BranchBar-spike-mac.zip` (415 KB, arm64, ad-hoc signed) attached to pre-release `v0.0.1-spike`. The app carries Check GitHub CLI, Add folder…, and Copy report buttons plus a `BRANCHBAR_SPIKE_AUTORUN=1` hook. `docs/runbooks/gate-0b-nyt-spike-test.md` is the tester's 14-step checklist. `ToolLocator` is real (4 tests) and found `/opt/homebrew/bin/gh` from a process launched with the stock launchd PATH (`env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin open …`); `gh auth status` returned exit 0 with the keyring token.
- **Why:** Gate 0b needs an artifact that answers distribution, GUI auth, and TCC on an NYT-managed Mac before real code is written.
- **Limits:** Launching a freshly signed bundle reproduced the macOS 15.5 dialog: `"BranchBar" Not Opened … Apple could not verify …` with **Move to Trash as the default button**; pressing Return deletes the app. While the dialog is up the process is app-translocated and `applicationDidFinishLaunching` never fires, so an empty log means the tester is stuck at Gatekeeper, not at a later step. `spctl -a -t exec` reports `rejected` regardless of the quarantine attribute (the ad-hoc signature is the cause). `listGitDirs` has no test inside 0.3's boundary; packet 2.4's scanner replaces it.
- **Cost accepted:** The spike zip is named `BranchBar-spike-mac.zip` (not versioned) so the runbook link is stable across rebuilds; `VERSION` stays 0.1.0.
- **Deliberately not changed:** No attempt at `SMAppService`, the real scanner, or `NSOpenPanel` recursion semantics; those are packets 4.2 and 2.4 and the Gate 5 checklist.
- **Session:** `cced85a0-5ced-4282-bc94-e23dcbe42d18`

## 2026-09-01 — Codex Challenge (cross-vendor) folded in; Gate 0b moved to Sept 4 with the spike zip

- **What:** codex-cli 0.152.1 (gpt-5.6-sol, high) reviewed PLAN.md and returned KILL. Adopted after firsthand verification: the managed-Mac distribution, GUI `gh` auth, and TCC test moves to **Gate 0b on Sept 4** using a spike zip (packet 0.3) instead of Sept 12 with the release; `PRStatus.notChecked` so an unqueried branch never renders as "no PR"; open-elsewhere keyed by owner + branch; "Pushed from this Mac" wording, a delete-then-recreate boundary, and a lineage check against the remote tip; product promise changed to "repos found under home or folders you added", Add folder… as recursive scan roots, skipped-categories summary; `GitClient` owned by 2.1 and a `branchbar-cli` target owned by 3.2 (also the fallback if Gate 0b fails); arm64-only until an Intel test exists; "Merged into `<base>`, no later local commits" replaces "safe to delete"; "Upstream missing from last-known origin"; separate test-author and implementer agents for push, PR matching, discovery, and deadlines; gh env frozen (`GH_PROMPT_DISABLED`, `GH_NO_UPDATE_NOTIFIER`, `GH_PAGER=cat`, `NO_COLOR`); research ledger corrected (`SwiftUI.tbd` lists arm64; reflog expiry 90/30 days).
- **Why:** Apple documents that MDM can disable the Open Anyway override, so a Sept 12 test would have discovered a fatal distribution block after the app was built. The other items were verified contract gaps (unqueried branches, fork collisions, delete/recreate attribution).
- **Limits:** The spike zip tests distribution and `gh` auth, not the real scanner or picker; Gate 5 repeats the checklist on the release build. Codex's steelman (ship a shell script instead) is not refuted, only decided against.
- **Cost accepted:** One extra packet (0.3) and a dependency on an NYT tester by Sept 4. Depth-unlimited extra roots can be slow on huge folders; the skip list still applies.
- **Deliberately not changed:** KILL rejected (Hannah decided handout; the risk codex names is now tested first). Opus kept for all packets (Hannah's ask); independence comes from separating test authors from implementers, not from cheaper models. Auto-discovery of the home folder kept.
- **Session:** `cced85a0-5ced-4282-bc94-e23dcbe42d18`

## 2026-09-01 — Packet 0.2 spike: Command Line Tools build the whole app; Gate 0 passes

- **What:** Every Gate 0 item passed on Command Line Tools alone. Verdicts:

  | # | Item | Verdict | Decisive output |
  |---|---|---|---|
  | 1 | `swift build` links SwiftUI for arm64, no flags | **PASS** | `[7/9] Linking BranchBar` / `Build complete! (11.52s)` |
  | 2 | x86_64 cross-build + `lipo`, minos on both slices | **PASS** | `Architectures in the fat file: … are: x86_64 arm64`, `minos 13.0` twice |
  | 3 | One `@Test` under Swift Testing | **PASS** | `✔ Test run with 1 test passed after 0.001 seconds.` |
  | 4 | Bundle installs, runs, logs, no Dock icon | **PASS** | `"ApplicationType"="UIElement"`; CGWindow `layer=25 bounds=["Y": 0, "X": 919, "Height": 37, "Width": 32]` |
  | 6 | Quarantine rehearsal | **PASS (recorded)** | `spctl -a -t exec -vv` → `rejected`, exit 3, before and after the attribute |
  | 7 | `.window` `MenuBarExtra` re-runs `onAppear` per open | **PASS** | 6 scripted clicks → 4 `menu opened` lines |

- **Item 1 — the stop gate.** `swift build` with no `-Xswiftc` anything. The arm64→arm64e `.swiftinterface` fallback works: the host toolchain reports `Target: arm64-apple-macosx15.0`, `lipo -info .build/debug/BranchBar` gives `architecture: arm64` and `otool -l` gives `minos 13.0`. The build did fail once first, on `static property 'formatter' is not concurrency-safe because non-'Sendable' type 'ISO8601DateFormatter' may have shared mutable state` — my own Swift 6 strict-concurrency error in `Log`, not a toolchain finding. Fixed with `nonisolated(unsafe)` plus an `NSLock` held across every read. **Xcode was not installed and the stop rule never fired.**
- **Item 2 — the working triple.** `arm64-apple-macosx13.0` and `x86_64-apple-macosx13.0`, passed as `swift build -c release --product BranchBar --triple <triple>`, with the per-slice binary read back from `swift build … --triple <triple> --show-bin-path`. The unversioned forms (`arm64-apple-macosx`) are also accepted and resolve to the same bin path, so the version suffix documents intent without changing behavior. x86_64 needed nothing special: both slices compiled in ~33 s each and `codesign --verify --strict --verbose=2` reports `valid on disk` / `satisfies its Designated Requirement`. `ARCHS=arm64` is unaffected and stays the default.
- **Item 3 — the flags.** `make test` passes. Plain `swift test` with no flags passes identically, so `--disable-xctest --enable-swift-testing` is not load-bearing today. Keeping it anyway: it is what stops a future XCTest import from being silently picked up on a machine that has full Xcode, which is exactly CI job A. Swift Testing reports `Target Platform: arm64e-apple-macos14.0` even though the product builds arm64/13.0 — the test runner uses the interface architecture, which is cosmetic.
- **Item 4 — how "no Dock icon" was actually proved.** `lsappinfo` reports `"ApplicationType"="UIElement"`. `screencapture` was not usable as evidence: it writes a file and the left half of the menu bar renders (the frontmost app's menus are legible), but the status-item half is blank — the clock and Control Center are missing too, so layer-25 windows are simply not in the capture. Proof came from `CGWindowListCopyWindowInfo` instead: BranchBar owns one window at `layer=25`, `Y=0`, 32×37. **This breaks §5b's screenshot plan** (`screencapture` + `osascript` + `windowid.swift`) for the menu bar strip specifically; capturing the popover by window id may still work and packet 4.1 has to prove that before relying on it. Separately, `osascript … get name of every menu bar item` first failed with `Access for assistive devices is disabled. (-1719)`, then `click menu bar item 1 of menu bar 2 of process "BranchBar"` succeeded, so Accessibility is granted for scripted clicks. The status item's accessibility name is `Divide`, which is what VoiceOver reads for `arrow.triangle.branch`; packet 4.1 owes it an explicit label.
- **Item 6 — and the finding that outranks it.** `spctl -a -t exec -vv /Applications/BranchBar.app` says `rejected` with exit 3, unchanged by the quarantine attribute, because the app is ad-hoc signed and unnotarized. That verdict is the durable assertion. The rehearsal could not reproduce the first-run dialog: the app launched with no prompt under `0083` on the bundle root, under `0081` applied recursively and from a path that had never been launched, because LaunchServices keys its approval to the signing identity rather than the path. What it did surface is **app translocation**: with the attribute set, `ps -o comm=` showed the process running from `/private/var/folders/…/AppTranslocation/…/BranchBar.app/Contents/MacOS/BranchBar` **even out of `/Applications`**. Deleting the attribute from the bundle root restores the real path. Consequences: nothing may be derived from `Bundle.main.bundlePath` and `SMAppService` must refuse to register from a translocated bundle. Full commands, the undo and the macOS 15 click-path are in `docs/runbooks/quarantine-rehearsal.md`.
- **Item 7 — what it licenses.** `onAppear` fires on every open, not once per process, which is the hook packet 3.2's "refresh on popover open, debounced 30 s" depends on. Scripted clicks do not pair one-to-one with opens — six clicks produced four opens, the rest landing as dismissals — so the count is a floor, not a ratio.
- **Why:** §3 locked Swift + SwiftPM on Command Line Tools with one unproven link and a dated Xcode fallback. The link is now proven, so packet 1.1 starts on the planned stack with no toolchain change and no schedule cost.
- **Limits:** No Mac that has never run BranchBar was available, so the first-run Gatekeeper dialog is documented from Apple's published macOS 15 flow rather than observed; Gate 5's tester supplies the real wording and screenshots. The menu bar icon has no visual confirmation, only the layer-25 window. Items 5, 8, 9 and 10 need a human and were not attempted.
- **Cost accepted:** The universal build runs the release compile twice, about 33 s per slice. `Log` uses `nonisolated(unsafe)` plus an `NSLock` rather than an actor, because `onAppear` calls it synchronously from a view body; packet 2.5 revisits this when `os.Logger` lands. `dist/screens/` now holds throwaway captures and is already gitignored.
- **Deliberately not changed:** Xcode not installed. No `resources:` in `Package.swift`, no `main.swift`. `make test` keeps its flags even though they are currently redundant. PLAN.md, CLAUDE.md, ARCHITECTURE.md, the Makefile and CI were not touched by this packet; PLAN.md shows as modified in `git status` from the orchestrator's own concurrent edits.
- **Session:** `cced85a0-5ced-4282-bc94-e23dcbe42d18`

### Human-assisted spike items

Four planned items and two verification gaps need Hannah at the keyboard. `make install` first, so `/Applications/BranchBar.app` is current.

**Item 5 — `SMAppService.register()` from `/Applications` with an ad-hoc signature.** Not attempted: it needs a `SMAppService` call compiled into the app, which is packet 4.2's code and it writes a real login item. When 4.2 builds it, register once and read the status back, then confirm the app is listed under System Settings → General → Login Items. Record whether `.enabled` survives a rebuild, since the ad-hoc signature changes on every build.

**Item 8 — TCC deny, then `NSOpenPanel` rescue.** Needs packet 2.4's scanner and 4.2's picker. The question §3 turns on: after denying the Documents prompt, does picking `~/Documents` in `NSOpenPanel` grant recursive read or only the folder itself? Reset first so the prompt fires:

```bash
tccutil reset SystemPolicyDocumentsFolder com.hannahstulberg.branchbar
```

**Item 9 — does a rebuilt ad-hoc binary re-prompt for TCC?** After item 8 grants access, run `make install` again (a new ad-hoc signature) and relaunch. If the prompt returns, README (packet 5.2) has to say so and it becomes an argument for a stable signing identity.

```bash
make install && open /Applications/BranchBar.app
```

**Item 10 — push from Cursor's Source Control UI.** The only item that gates packet 2.1's reflog reader. In any repo with a remote, commit and push using Cursor's Source Control panel rather than the terminal, then confirm the GUI push wrote a reflog line the same way a terminal push does:

```bash
cat "$(git rev-parse --git-common-dir)/logs/refs/remotes/origin/$(git branch --show-current)"
```

Look for a final field of `update by push` and a non-zero new OID. If Cursor pushes through a bundled git that writes no reflog entry, "Last pushed" silently degrades to the commit-date fallback for the exact audience the app is built for.

**Gap A — is the menu bar icon visible?** `screencapture` cannot see it. Look at the menu bar with the app running, then open the popover twice and confirm the count rises by two:

```bash
open /Applications/BranchBar.app
grep -c 'menu opened' ~/Library/Logs/BranchBar/BranchBar.log
```

**Gap B — the Gatekeeper first run.** Only observable on a Mac that has never run BranchBar, which is Gate 5. Ask the tester which dialog they saw and which button they clicked; `docs/runbooks/quarantine-rehearsal.md` holds the expected sequence to check their report against.

## 2026-09-01 — Plan approved after three review rounds; Phase 0 begins

- **What:** PLAN.md approved by Hannah. Locked: Swift + SwiftPM on Command Line Tools (spike decides arm64 SwiftUI linking, Xcode is the same-day fallback), zipped ad-hoc-signed `.app` as a handout that NYT tests on a managed Mac by Sept 12, home scan to depth 6 plus "Add repository…", `gh`-based PR status with head-first matching and per-head fallback, reflog-file push time with an honest fallback label, lazy PR fetching, Merged vs Closed-without-merging groups, Open in Cursor as the primary action.
- **Why:** NYT PMs and designers on Claude Code via Bedrock have no desktop-app branch/worktree picker; the Sept 24 workshop teaches exactly that orientation.
- **Limits:** Cross-vendor codex Challenge did not run (CLI 0.142.3 rejects its configured model); the adversarial slot was a fresh-context Opus subagent. Rerun scheduled once codex upgrades.
- **Cost accepted:** Depth-6 scan is slower than depth 4 on large home folders; per-head PR queries add up to 20 gh calls per repo; the CLT constraint keeps one unproven link (arm64 SwiftUI interfaces) until the spike.
- **Deliberately not changed:** Not Electron (mirrors JobRunner but 96 MB and needs Node); not folder-picker-first discovery (Hannah chose auto-discovery); launch-at-login kept in v1 on the cut line; no `git fetch` ever.
- **Session:** `cced85a0-5ced-4282-bc94-e23dcbe42d18`
