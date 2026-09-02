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
