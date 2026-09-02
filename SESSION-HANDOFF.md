# SESSION HANDOFF — BranchBar

**Last updated:** 2026-09-02 03:10 by session `cced85a0-5ced-4282-bc94-e23dcbe42d18`

## Current state

- **Phase / packet:** Phase 3: 3.1 green (b98b0eb); red(3.2) 9d8fb7d committed; 3.2 implementer in flight (coordinator + branchbar-cli + PRCacheEntry.queriedHeads). 2.2 presenter green (2b1b083). Local main is ahead of origin (push held until 3.2 is green because red(3.2) traps the whole run).
- **Suite:** 226 passing with `--skip RefreshCoordinator` (clean worktree at b98b0eb); CI green at d9444b6.
- **In-flight agents:** 3.2-I (spec packets/3.2.md implementer role).
- **Blocked on:** nothing. Hannah's own packet 0.0 items are open: ask Andrew Lisy whether JobRunner opened on NYT-managed Macs; name the NYT tester and their macOS version.

## Next steps (in order)

1. Accept 3.2-I: full `make test` green at its SHA, zero edits to RefreshCoordinatorTests since 9d8fb7d; commit `green(3.2)`; push; confirm CI.
2. Gate 3: run `swift run branchbar-cli snapshot --root ~/hannah-personal-agent --root ~/branchbar --root ~/WalkTimer-or-a-third-repo --git /usr/bin/git` and hand-check against `git branch -vv` / `git worktree list` / `gh pr list` for 3 repos; record in DECISION-LOG.
3. Dispatch 4.1 (packets/4.1.md) after Gate 3; Hannah's Gate 4.0 read of docs/UI-CONTRACT.md is async.
4. Then 5.1a (first zip, tag v0.9.0) by 09-10, 4.2 (actions + launch at login), 5.1b, 5.2.
5. Hannah: Gate 0b NYT tester (runbook sent), Andrew Lisy question, Cursor push check.

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
