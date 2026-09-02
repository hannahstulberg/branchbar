# BranchBar — front door

macOS menu bar app (Swift + SwiftPM, no Xcode required to build) that lists every git repo cloned under `~`, each repo's local branches and worktrees, PR status via the `gh` CLI, and when each branch was last pushed. Handout for NYT PMs and designers using Claude Code via Bedrock; they install a zipped `.app` and never need a toolchain.

## Doc map

| Read | For |
|---|---|
| `SESSION-HANDOFF.md` | Current state. Read this first in any fresh session. |
| `PLAN.md` | The approved contract: decisions (§3), architecture (§4), frozen types and git/gh invocations (§5), UI contract (§5a), build contract (§5b), security (§6), TDD rules and named invariants (§7), roadmap (§8), documentation framework (§11). Section numbers are stable; reviews cite them. |
| `ARCHITECTURE.md` | How it works today: §1 system diagram, §2 the five mechanism diagrams, §3 anatomy table with `file:line`, §4 data model, §5 testing, §6 operations, §7 security contract, §8 known footguns. |
| `DECISION-LOG.md` | Why it changed, newest first. Every spike verdict, review finding, and cut. |
| `README.md` | The only user-facing document: trust paragraph, install steps, requirements, what the rows mean, checksum, uninstall. Written for someone who will never open this repo. |
| `docs/UI-CONTRACT.md` | Every user-facing state and string, plus the row hierarchy and tokens. Section 2 is generated from `Sources/BranchBarCore/Strings.swift` by `make doc-strings` and is never hand-edited. |
| `docs/TEST-PLAN.md` | Named invariants → test files, the fixture inventory, and how to re-record. |
| `docs/runbooks/` | Multi-step procedures: `gate-0b-nyt-spike-test.md` (the tester's install checklist the README mirrors), `quarantine-rehearsal.md` (Gatekeeper and app translocation, with the commands). |
| `SESSIONS.md` | One row per Claude Code session with the local resume UUID. |
| `session-logs/` | Distilled per-session logs beside the auto-archived transcripts, and the plans and proposals that belong to them. |

## Build, test, run, ship

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not required.

```bash
make test        # swift test --disable-xctest --enable-swift-testing (Swift Testing only; XCTest is absent under CLT)
make build       # debug build, host arch
make run         # bundle (arm64) + open dist/BranchBar.app
make install     # copy to /Applications (login-item and Gatekeeper rehearsals need that path)
make logs        # tail ~/Library/Logs/BranchBar/BranchBar.log
make zip         # release bundle, ad-hoc sign, ditto zip + sha256 under dist/
make verify      # what CI checks before publishing: the bundled helper, both codesign checks, lipo, Info.plist keys
make snapshot ROOTS="~/one ~/two"   # branchbar-cli: every repo, branch, worktree, PR, and push as a table
make record-fixtures                # re-run every frozen git/gh invocation against real repos and rewrite Tests/.../Fixtures/recorded-*
make doc-refs    # fail if any ARCHITECTURE.md §3 file:line no longer points at its symbol
make doc-strings # regenerate the docs/UI-CONTRACT.md string table from Strings.swift
```

`make snapshot` is also the headless fallback: it produces the same list as the app without the UI, which is what Gate 3 was checked against and what the workshop falls back to if a managed Mac ever blocks the bundle. The same binary has a second subcommand, `branchbar-cli scan`, which is not for people: it is the discovery helper the app spawns from `Contents/MacOS`, and it streams NDJSON so that killing it at the scan deadline still yields the repos it had found.

## The seams

All external effects go through three protocols in `BranchBarCore`, and tests replace all three: `CommandRunner` (git and gh processes), `FileSystem` (home scan, reflog files, cache), `CacheStore`. Nothing in Core imports AppKit or SwiftUI; a test enforces it. Every string a user reads is produced in Core by `SnapshotPresenter` from `Strings.swift`, so it is testable.

A fourth seam, `ScanRunning`, decides *where* the repo walk runs rather than what it talks to: `InProcessScanRunner` for every unit test and for the CLI, `HelperProcessScanRunner` for the app, which spawns `branchbar-cli scan` so the scan deadline has a process it can kill.

## Rules that came from real bugs

The full list with the evidence is `ARCHITECTURE.md` §8. These are the ones a fresh session trips on first.

- Every git or gh invocation in PLAN.md §5 was executed against `/usr/bin/git` 2.39.5 before it was frozen. A new invocation goes into `scripts/record-fixtures.sh` and is recorded before any parser is written for it.
- `%1f` is a `for-each-ref` atom only; in `reflog show` / `log` formats use `%x1f`. `reflog show` silently ignores `--` (zero rows, exit 0).
- The GUI app PATH is `/usr/bin:/bin:/usr/sbin:/sbin`; Homebrew binaries are found by `ToolLocator`, never by PATH. Testing that needs `env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin open …`, because `open` forwards the calling shell's environment.
- **Nothing a repo owns is ever interpolated into shell source.** The Terminal sign-in helper is the app's one string-becomes-a-shell-script path, and it used to write `gh auth login --hostname \(host)` into a `.command` file with `host` taken from `remote.origin.url`, so `ssh://git@$(touch pwned)/o/r` was code execution on click (codex BLOCKER 1). `SignInScript.render` is now fixed text: the hostname arrives as data in the sibling file `gh-sign-in.host`, is read with a command substitution that never re-evaluates what it read, and is re-checked in zsh against the same grammar `GitHubSlug.isValidHostname` applies in Swift. Anything new that writes a script follows the same shape, and lives in Core so a test can run it.
- **Cancelling a command signals the child's process group, not the child.** `git` forks credential and lazy-fetch helpers that outlive a `kill(pid)` and keep the pipes open, so a cancelled refresh looked finished while its grandchildren were not. Foundation spawns each child as its own group leader; `signalGroup` confirms that (`getpgid(pid) == pid`, and not BranchBar's own group) before sending to `-pid`, because a negative pid on the wrong group would signal the app itself. A cancellation test that `exec`s `sleep` proves nothing here: it has to fork a child that does not `exec`.
- Every `make install` re-signs with a new cdhash, so macOS asks for folder access again. The README says so; treat a returning "Not scanned" row as expected, not a regression.
- Cancellation is checked before each listing, Desktop, Documents, and Downloads are opened last, and `RealFileSystem` lists with resource values rather than calling `attributesOfItem` per entry. None of that reaches a listing already inside `open()`; see the helper-process rule below.
- `%(upstream:track,nobracket)` is empty for both "in sync" and "no upstream"; disambiguate with `upstream:short`.
- Reflog files can exist and be empty; `push --delete` writes an all-zero new OID; lines expire at 90 days; author names carry spaces, so the timestamp is counted from the end of the header.
- `gh pr list --json headRepositoryOwner` returns an object; use `.login`. `reviewDecision` is `""` when undecided. `gh auth status` writes to stdout on gh 2.89, so judge it by its exit code.
- `Command.environment` merges over the inherited environment rather than replacing it; the frozen git and gh environments set the keys that matter and let PATH and HOME through. `environmentMergesCommandEnvOverInherited` pins it.
- **A synthesized `Codable` decoder ignores a stored property's default.** Add a field to a type that lives in `cache.json` and you have added a *required* key, so every cache an earlier build wrote fails to decode and `FileCacheStore.load` reports that as "no cache" — a cold rescan and an empty popover that looks like a first launch. Eight types carry an explicit `init(from:)` for this reason; add the field to that decoder with `decodeIfPresent` in the same edit. `cache-1.1-era.json` and `CacheCompatibilityTests` catch it.
- **A directory listing already inside `open()` cannot be cancelled, and neither can a read of a FIFO.** The walk therefore runs in the `branchbar-cli` helper, which the scan deadline kills by process group, and every repository-owned read goes through `RealFileSystem.readBoundedRegularFile` (`O_NOFOLLOW | O_NONBLOCK`, an `S_IFREG` check, then `pread`). A `FileManager` convenience added later reintroduces both silently.
- **`CommandRunner.run` throws on a timeout, and a thrown error carries no bytes.** That is right for a command whose output is one document and wrong for the scan helper, whose output is a stream of independently true lines: for three launches it reported zero repos while the helper had found 25. `runCollectingPartialOutput` is the one exception, and `PartialOutputCommandRunning` is what keeps it from spreading.
- **`git rev-parse` prints multiple paths newline-separated, and a directory name may contain a newline.** Ask once per path. `worktree list --porcelain` needs `-z` for the same reason, and without it a lost worktree stage quietly moves a checked-out branch into Merged.
- **A PR head is an (owner, branch) pair, not a name.** Owner is required for a match, not a tie-break, and `PRQueryCoverage` is keyed the same way; a branch whose owner is unresolved renders `notChecked`, never `none`. Origin's owner comes from the slug, every other remote from one `git config --get remote.<name>.url`.
- `gh auth status --hostname` is judged by its exit code; the same command with no `--hostname` is judged by its **output**, because gh exits non-zero when any configured host is logged out while still listing the ones that are not. That list is the whole set of hosts BranchBar treats as GitHub.
- Never add `resources:` to `Package.swift` (breaks the `.app` layout). Never add `main.swift` (breaks `@main`).
- Two agents building in one checkout serialize on the SwiftPM build lock and look hung; give each one `--scratch-path`. A red packet's `fatalError` stub traps the whole Swift Testing process, so a red run reads as a crash rather than a failure list.
- `screencapture` cannot see the menu bar status item; prove it with `CGWindowListCopyWindowInfo`. The Gatekeeper dialog's default button is Move to Trash, so any tester instruction says "click Done with the mouse".

## How an edit flows

`SESSION-HANDOFF.md` → find the mechanism in `ARCHITECTURE.md` §3 → red test → green → update the §2 diagram if the mechanism changed → `make doc-refs` → `DECISION-LOG.md` entry → refresh the handoff → `/commit-push`. Commits are conventional (`feat(2.1):`, `red(2.1):`, `green(2.1):`, `docs:`) with a `Why:` body.

Two edits carry extra steps. A change that adds or edits a user-facing string edits `Strings.swift`, then runs `make doc-strings` so `docs/UI-CONTRACT.md` matches. A change that adds a git or gh invocation adds it to `scripts/record-fixtures.sh` and re-records before a parser is written. Any edit that shifts line numbers in `Sources/` re-derives the `ARCHITECTURE.md` §3 rows, which is what `make doc-refs` fails on.

## Workflow

Built with the `coding-project` skill: an Opus orchestrator writes specs, docs, and verifications; delegated Opus subagents write all production code under red/green TDD; every packet's red SHA is re-run before acceptance. Session transcripts are archived to `session-logs/` by the global commit hook.
