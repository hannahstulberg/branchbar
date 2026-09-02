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
make verify      # what CI checks before publishing: codesign, lipo, Info.plist keys
make snapshot ROOTS="~/one ~/two"   # branchbar-cli: every repo, branch, worktree, PR, and push as a table
make record-fixtures                # re-run every frozen git/gh invocation against real repos and rewrite Tests/.../Fixtures/recorded-*
make doc-refs    # fail if any ARCHITECTURE.md §3 file:line no longer points at its symbol
make doc-strings # regenerate the docs/UI-CONTRACT.md string table from Strings.swift
```

`make snapshot` is also the headless fallback: it produces the same list as the app without the UI, which is what Gate 3 was checked against and what the workshop falls back to if a managed Mac ever blocks the bundle.

## The three seams

All external effects go through three protocols in `BranchBarCore`, and tests replace all three: `CommandRunner` (git and gh processes), `FileSystem` (home scan, reflog files, cache), `CacheStore`. Nothing in Core imports AppKit or SwiftUI; a test enforces it. Every string a user reads is produced in Core by `SnapshotPresenter` from `Strings.swift`, so it is testable.

## Rules that came from real bugs

The full list with the evidence is `ARCHITECTURE.md` §8. These are the ones a fresh session trips on first.

- Every git or gh invocation in PLAN.md §5 was executed against `/usr/bin/git` 2.39.5 before it was frozen. A new invocation goes into `scripts/record-fixtures.sh` and is recorded before any parser is written for it.
- `%1f` is a `for-each-ref` atom only; in `reflog show` / `log` formats use `%x1f`. `reflog show` silently ignores `--` (zero rows, exit 0).
- The GUI app PATH is `/usr/bin:/bin:/usr/sbin:/sbin`; Homebrew binaries are found by `ToolLocator`, never by PATH. Testing that needs `env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin open …`, because `open` forwards the calling shell's environment.
- Every `make install` re-signs with a new cdhash, so macOS asks for folder access again. The README says so; treat a returning "Not scanned" row as expected, not a regression.
- A directory listing already blocked inside `open()` cannot be cancelled. Cancellation is checked before each listing, Desktop, Documents, and Downloads are opened last, and `RealFileSystem` lists with resource values rather than calling `attributesOfItem` per entry.
- `%(upstream:track,nobracket)` is empty for both "in sync" and "no upstream"; disambiguate with `upstream:short`.
- Reflog files can exist and be empty; `push --delete` writes an all-zero new OID; lines expire at 90 days; author names carry spaces, so the timestamp is counted from the end of the header.
- `gh pr list --json headRepositoryOwner` returns an object; use `.login`. `reviewDecision` is `""` when undecided. `gh auth status` writes to stdout on gh 2.89, so judge it by its exit code.
- `Command.environment` merges over the inherited environment; the doc comment on that field still says "replaces" and is the stale half of the pair.
- Never add `resources:` to `Package.swift` (breaks the `.app` layout). Never add `main.swift` (breaks `@main`).
- Two agents building in one checkout serialize on the SwiftPM build lock and look hung; give each one `--scratch-path`. A red packet's `fatalError` stub traps the whole Swift Testing process, so a red run reads as a crash rather than a failure list.
- `screencapture` cannot see the menu bar status item; prove it with `CGWindowListCopyWindowInfo`. The Gatekeeper dialog's default button is Move to Trash, so any tester instruction says "click Done with the mouse".

## How an edit flows

`SESSION-HANDOFF.md` → find the mechanism in `ARCHITECTURE.md` §3 → red test → green → update the §2 diagram if the mechanism changed → `make doc-refs` → `DECISION-LOG.md` entry → refresh the handoff → `/commit-push`. Commits are conventional (`feat(2.1):`, `red(2.1):`, `green(2.1):`, `docs:`) with a `Why:` body.

Two edits carry extra steps. A change that adds or edits a user-facing string edits `Strings.swift`, then runs `make doc-strings` so `docs/UI-CONTRACT.md` matches. A change that adds a git or gh invocation adds it to `scripts/record-fixtures.sh` and re-records before a parser is written. Any edit that shifts line numbers in `Sources/` re-derives the `ARCHITECTURE.md` §3 rows, which is what `make doc-refs` fails on.

## Workflow

Built with the `coding-project` skill: an Opus orchestrator writes specs, docs, and verifications; delegated Opus subagents write all production code under red/green TDD; every packet's red SHA is re-run before acceptance. Session transcripts are archived to `session-logs/` by the global commit hook.
