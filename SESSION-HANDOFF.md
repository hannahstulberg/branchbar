# SESSION HANDOFF — BranchBar

**Last updated:** 2026-09-02 07:30 by session `cced85a0-5ced-4282-bc94-e23dcbe42d18`

## Current state

- **Phase / packet:** Pre-ship gate. 4.3 (56d3f49) and 5.2 docs (db8281f) accepted. codex ship review = DO NOT SHIP; v0.9.0 marked superseded pre-release. Fix wave in flight: F1 (shell security), F2 (Core honesty), F3 (runtime). gsd-code-reviewer still running (REVIEW.md in scratchpad/review/).
- **Suite:** 257 passing before the fix wave
- **In-flight agents:** F1, F2, F3 (specs packets/F1-3.md), gsd-code-reviewer.
- **Blocked on:** nothing. Hannah's own packet 0.0 items are open: ask Andrew Lisy whether JobRunner opened on NYT-managed Macs; name the NYT tester and their macOS version.

## Next steps (in order)

1. Accept F1/F2/F3 (verify at SHA, zero weakened tests, full suite green, `make doc-strings`/`make doc-refs`); commit; push; CI green.
2. Fold gsd-code-reviewer findings: fix / defer / reject each in DECISION-LOG; dispatch F4 if anything material remains.
3. Re-run codex challenge on the fixed code; require no BLOCKER. Then bump VERSION 0.9.1, tag, CI release; send to the NYT tester (Gate 5 by 09-12).
4. Sync ARCHITECTURE.md (`make doc-refs`) and README wording for the changed strings.
5. Hannah: Gate 0b spike result, Gate 4 screenshots feedback, Andrew Lisy question.

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
