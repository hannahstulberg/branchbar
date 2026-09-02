# 2026-09-01 — Scope, plan, review, and bootstrap BranchBar
session: cced85a0-5ced-4282-bc94-e23dcbe42d18 | model: Fable 5.1 orchestrator, Opus subagents | project-state-before: nothing existed

## Commits this session
- (first) docs(0.1): bootstrap repo with plan, doc skeleton, Makefile, CI

## Decisions & discoveries
- Hannah chose Swift over Electron after a three-round discussion; deciding argument: Claude Code extends either equally, so size and native feel win once readability is off the table.
- Users never need Xcode; Hannah's machine builds with Command Line Tools only. XCTest is absent under CLT, so Swift Testing only.
- JobRunner (Andrew Lisy) is Electron, ad-hoc signed, unnotarized: proves the zip-and-share path was used, not that NYT-managed Macs opened it. NYT will test before the workshop.
- Verified on this machine: `%1f` is not a reflog format atom (`%x1f` is); `reflog show -- <ref>` returns zero rows; reflog files can be empty; `headRepositoryOwner` is an object; `%(upstream:track)` is empty for both in-sync and no-upstream; 4 real repos at depth 5–7.
- Gate 1 ran: gstack plan-design-review + plan-eng-review (headless, on 1.58.5), fresh-context Opus adversarial review. Codex could not run: CLI 0.142.3 (npm-managed at /opt/homebrew/lib/node_modules) rejects configured model gpt-5.6-sol.
- gstack upgraded 1.58.5.0 → 1.79.0.0 mid-session at Hannah's request.
- `gh repo create --clone` clones into cwd, not ~; moved to ~/branchbar.

## Open threads
- Packet 0.2 spike agent dispatched (Opus); human-assisted items 5, 8, 9, 10 await Hannah.
- Hannah to ask Andrew Lisy about JobRunner on managed Macs and name the NYT tester.
- codex upgrade via npm pending; rerun Challenge after.

## Later in session
- Gate 0 PASSED on CLT (spike agent): arm64 SwiftUI links, universal via `--triple arm64-apple-macosx13.0` / `x86_64-apple-macosx13.0` + lipo, Swift Testing runs, bundle launches as UIElement, onAppear fires per open. Findings: app translocation under quarantine; screencapture blind to status items.
- Codex 0.152.1 Challenge: KILL verdict; verified + folded (Gate 0b on 09-04 with spike zip, notChecked PR state, push wording/boundary, promise wording, arm64-only). Rejected KILL (Hannah decided handout).
- Commits: feat(0.2) spike; docs: plan revised for codex round.

## 2026-09-02 (continued): review rounds and the 0.9.1 cut
- Phases 2–5 executed as parallel waves with separate test-author and implementer agents for the risky semantics; every packet has a verified red SHA and a green SHA (see git log prefixes red()/green()).
- Pre-ship gate: gsd-code-reviewer + five codex Challenge rounds (verdicts: DO NOT SHIP ×4, then no blocker). Waves F1–F18 closed: shell injection in the sign-in helper, Terminal document fallback, helper-process discovery with streamed partial results, FD-based special-file-safe reads, process-group kill, honest push/fetch/PR wording, slug-bound PR cache, lenient decoders, login-item verification. Deferred with reasons: dead-filesystem isolation of the whole repo load, component-wise openat, posix_spawn.
- Release: v0.9.1 tagged at 1038a4c (444 tests, 72 anatomy rows, bundle with signed helper). v0.9.0 remains a superseded pre-release.
- Open with Hannah: Gate 0b spike result from the NYT tester, Gate 4 screenshots, Gate 4.0 string table, Andrew Lisy question, Cursor push check.
