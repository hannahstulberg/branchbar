# SESSION HANDOFF — BranchBar

**Last updated:** 2026-09-02 10:30 by session `cced85a0-5ced-4282-bc94-e23dcbe42d18`

## Current state

- **Phase / packet:** Fix wave F1–F4 accepted and pushed (7764920). In flight: second codex challenge on the fixed code; F5 (two-line cleanup: empty-state glyph/Rescan, Command.environment doc comment). v0.9.0 stays a superseded pre-release; v0.9.1 is cut only if codex round 2 has no BLOCKER.
- **Suite:** 312 passing; `make doc-refs` 60 rows green
- **In-flight agents:** F5; codex round 2 (scratchpad/review/codex-ship2.md).
- **Blocked on:** nothing. Hannah's own packet 0.0 items are open: ask Andrew Lisy whether JobRunner opened on NYT-managed Macs; name the NYT tester and their macOS version.

## Next steps (in order)

1. Read codex round 2; verify any blocker firsthand; fix/defer/reject each finding in DECISION-LOG; small fixes → F6.
2. Accept F5; commit; push; CI green.
3. Cut v0.9.1: bump VERSION, tag, CI release; edit the release notes; send the URL + README install steps to the NYT tester (Gate 5 by 09-12). Then delete or leave v0.9.0 as superseded.
4. Gate 4: Hannah reviews dist/screens/ (34+ states); Gate 4.0: string table read.
5. Hannah: Gate 0b spike result from the NYT tester, Andrew Lisy question.

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
