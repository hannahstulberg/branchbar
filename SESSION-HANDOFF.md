# SESSION HANDOFF — BranchBar

**Last updated:** 2026-09-01 23:30 by session `cced85a0-5ced-4282-bc94-e23dcbe42d18`

## Current state

- **Phase / packet:** Phase 0 done (0.1 committed, 0.2 spike PASSED Gate 0 on CLT). Packets 0.3 (spike zip for NYT) and 1.1 (freeze contracts) dispatched concurrently.
- **Suite:** 1 passing (`make test`)
- **In-flight agents:** packet 0.3 (Opus: ToolLocator, SpikeChecks, spike UI, runbook) and packet 1.1 (Opus: §5 types, seams, stubs, doubles, record-fixtures, live-repo tests). Disjoint boundaries: 0.3 owns ToolLocator.swift + SpikeChecks.swift + BranchBarApp.swift; 1.1 owns the rest of Core + Tests.
- **Blocked on:** nothing. Hannah's own packet 0.0 items are open: ask Andrew Lisy whether JobRunner opened on NYT-managed Macs; name the NYT tester and their macOS version.

## Next steps (in order)

1. Accept 0.3: verify `make test`, `make zip`, GUI gh report in the log; commit; tag `v0.0.1-spike` pre-release; send the runbook + zip URL to the NYT tester (Gate 0b by 09-04).
2. Accept 1.1: verify red SHA, `make record-fixtures` output, live-repo tests; commit.
3. Dispatch 4.0 (UI contract) and the phase-2 lanes (2.1 test-author → implementer, 2.3, 2.4, 2.5) per PLAN.md §8.
4. Hannah: Cursor push test (spike item 10, commands in DECISION-LOG), Andrew Lisy question, NYT tester named.

## Re-read order for a fresh session

1. This file
2. `PLAN.md` §3 decisions and §8 roadmap
3. `ARCHITECTURE.md`
4. Latest `DECISION-LOG.md` entries

## Gotchas active right now

- Codex upgraded to 0.152.1 via npm (`/opt/homebrew/bin/codex` is an npm symlink, not a brew formula). Challenge ran; verdict KILL, folded in (see DECISION-LOG).
- App translocation: a quarantined bundle runs from `/private/var/folders/.../AppTranslocation/...` even from /Applications; never derive paths from `Bundle.main.bundlePath`; `SMAppService` must refuse when translocated.
- `screencapture` cannot capture menu bar status items (layer 25); prove the icon via `CGWindowListCopyWindowInfo`; popover capture by window id still to be proven in 4.1.
- Repo was cloned by `gh repo create --clone` into the wrong cwd and moved to `~/branchbar`; canonical checkout is `~/branchbar`.
- Hannah's machine has no Xcode; `/usr/bin/git` is 2.39.5, Homebrew git 2.52 is first on PATH. Verify against 2.39.5.
