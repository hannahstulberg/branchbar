# SESSION HANDOFF — BranchBar

**Last updated:** 2026-09-02 12:00 by session `cced85a0-5ced-4282-bc94-e23dcbe42d18`

## Current state

- **Phase / packet:** Second review round. F1–F5 accepted (640725c). codex round 2 = DO NOT SHIP; wave F6 (runtime + helper process), F7 (Core semantics), F8 (shell) in flight. F9 docs queued.
- **Suite:** 312 passing at 640725c
- **In-flight agents:** F6, F7, F8 (specs packets/F6-8.md).
- **Blocked on:** nothing. Hannah's own packet 0.0 items are open: ask Andrew Lisy whether JobRunner opened on NYT-managed Macs; name the NYT tester and their macOS version.

## Next steps (in order)

1. Accept F6/F7/F8 (verify at SHA; zero weakened tests; full suite; bundle carries branchbar-cli helper); commit; push; CI green.
2. Dispatch F9 docs (packets/F9.md): PLAN §5 amended to what shipped, README ~/Applications + helper note, ARCHITECTURE re-derive, TEST-PLAN, record-fixtures for new invocations.
3. codex round 3; require no BLOCKER. Then VERSION 0.9.1 (+ BranchBarCore.version), tag, CI release, release notes, send to the NYT tester (Gate 5 by 09-12).
4. Hannah: Gate 0b spike result, Gate 4 screenshots, Gate 4.0 strings, Andrew Lisy question.

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
