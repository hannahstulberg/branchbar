# BranchBar — front door

macOS menu bar app (Swift + SwiftPM, no Xcode required to build) that lists every git repo cloned under `~`, each repo's local branches and worktrees, PR status via the `gh` CLI, and when each branch was last pushed. Handout for NYT PMs and designers using Claude Code via Bedrock; they install a zipped `.app` and never need a toolchain.

## Doc map

| Read | For |
|---|---|
| `SESSION-HANDOFF.md` | Current state. Read this first in any fresh session. |
| `PLAN.md` | The approved contract: decisions (§3), architecture (§4), frozen types and git/gh invocations (§5), UI contract (§5a), build contract (§5b), tests (§7), roadmap (§8). Section numbers are stable; reviews cite them. |
| `ARCHITECTURE.md` | How it works today, with `file:line` anatomy, Mermaid flows, and known footguns. |
| `DECISION-LOG.md` | Why it changed, newest first. Every spike verdict, review finding, and cut. |
| `docs/UI-CONTRACT.md` | Every user-facing state and string; mirrors `Sources/BranchBarCore/Strings.swift`. |
| `docs/TEST-PLAN.md` | Named invariants → test files; fixture inventory; how to re-record. |
| `docs/runbooks/` | Multi-step procedures (re-record fixtures, TCC reset, quarantine rehearsal). |
| `SESSIONS.md` | One row per Claude Code session with the local resume UUID. |
| `session-logs/` | Distilled per-session logs beside the auto-archived transcripts. |

## Build, test, run, ship

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not required.

```bash
make test        # swift test --disable-xctest --enable-swift-testing (Swift Testing only; XCTest is absent under CLT)
make build       # debug build, host arch
make run         # bundle (arm64) + open dist/BranchBar.app
make logs        # tail ~/Library/Logs/BranchBar/BranchBar.log
make zip         # release bundle, ad-hoc sign, ditto zip + sha256 under dist/
make record-fixtures   # re-run every frozen git/gh invocation against real repos and rewrite Tests/.../Fixtures/recorded-*
make doc-refs    # fail if any ARCHITECTURE.md file:line no longer points at its symbol
```

## The three seams

All external effects go through three protocols in `BranchBarCore`, and tests replace all three: `CommandRunner` (git and gh processes), `FileSystem` (home scan, reflog files, cache), `CacheStore`. Nothing in Core imports AppKit or SwiftUI; a test enforces it. Every string a user reads is produced in Core by `SnapshotPresenter` from `Strings.swift`, so it is testable.

## Rules that came from real bugs

- Every git or gh invocation in PLAN.md §5 was executed against `/usr/bin/git` 2.39.5 before it was frozen. A new invocation goes into `scripts/record-fixtures.sh` and is recorded before any parser is written for it.
- `%1f` is a `for-each-ref` atom only; in `reflog show` / `log` formats use `%x1f`. `reflog show` silently ignores `--` (zero rows, exit 0).
- The GUI app PATH is `/usr/bin:/bin:/usr/sbin:/sbin`; Homebrew binaries are found by `ToolLocator`, never by PATH.
- `%(upstream:track,nobracket)` is empty for both "in sync" and "no upstream"; disambiguate with `upstream:short`.
- Reflog files can exist and be empty; `push --delete` writes an all-zero new OID; lines expire at 90 days.
- `gh pr list --json headRepositoryOwner` returns an object; use `.login`. `reviewDecision` is `""` when undecided.
- Never add `resources:` to `Package.swift` (breaks the `.app` layout). Never add `main.swift` (breaks `@main`).

## How an edit flows

`SESSION-HANDOFF.md` → find the mechanism in `ARCHITECTURE.md` §3 → red test → green → update the Mermaid diagram if the mechanism changed → `make doc-refs` → `DECISION-LOG.md` entry → refresh the handoff → `/commit-push`. Commits are conventional (`feat(2.1):`, `red(2.1):`, `green(2.1):`, `docs:`) with a `Why:` body.

## Workflow

Built with the `coding-project` skill: an Opus orchestrator writes specs, docs, and verifications; delegated Opus subagents write all production code under red/green TDD; every packet's red SHA is re-run before acceptance. Session transcripts are archived to `session-logs/` by the global commit hook.
