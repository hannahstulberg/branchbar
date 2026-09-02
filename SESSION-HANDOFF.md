# SESSION HANDOFF — BranchBar

**Last updated:** 2026-09-03 00:30 by session `cced85a0-5ced-4282-bc94-e23dcbe42d18`

## Current state

- **Phase / packet:** v0.9.1 tagged at 1038a4c after five codex rounds and waves F1–F18. CI release job attaches the zip. Next: release notes, send to the NYT tester (Gate 5 by 09-12), Gate 4/4.0 reviews with Hannah.
- **Suite:** 444 passing; `make doc-refs` 72/72; bundle verify passes with the helper
- **In-flight agents:** none.
- **Blocked on:** nothing. Hannah's own packet 0.0 items are open: ask Andrew Lisy whether JobRunner opened on NYT-managed Macs; name the NYT tester and their macOS version.

## Next steps (in order)

1. Confirm the v0.9.1 CI run created the release; `gh release edit v0.9.1 --notes-file <scratch release-notes-0.9.1.md>`; keep v0.9.0 as a superseded pre-release (or delete it).
2. Send Hannah the release URL + the README install section for the NYT tester (Gate 5 checklist in PLAN.md §8).
3. Hannah: Gate 0b spike result, Gate 4 screenshots (dist/screens/), Gate 4.0 string table (docs/UI-CONTRACT.md), Andrew Lisy question, Cursor push check.
4. v1.0 backlog (DECISION-LOG round-4 entry): whole-repo-load helper for dead filesystems; component-wise openat; posix_spawn; recent-100 count-equals-limit caveat; open-elsewhere suppression rule revisit.

## Re-read order for a fresh session

1. This file
2. `PLAN.md` §3 decisions and §8 roadmap
3. `ARCHITECTURE.md`
4. Latest `DECISION-LOG.md` entries

## Gotchas active right now

- The app's own first launch blocks until the user answers the folder-access prompt for Documents/Desktop/Downloads; the helper is killed at the scan deadline and (after F11) returns the repos it streamed before the block. Each `make install` re-signs and re-prompts.
- Codex upgraded to 0.152.1 via npm (`/opt/homebrew/bin/codex` is an npm symlink, not a brew formula). Challenge ran; verdict KILL, folded in (see DECISION-LOG).
- App translocation: a quarantined bundle runs from `/private/var/folders/.../AppTranslocation/...` even from /Applications; never derive paths from `Bundle.main.bundlePath`; `SMAppService` must refuse when translocated.
- `screencapture` cannot capture menu bar status items (layer 25); prove the icon via `CGWindowListCopyWindowInfo`; popover capture by window id still to be proven in 4.1.
- Repo was cloned by `gh repo create --clone` into the wrong cwd and moved to `~/branchbar`; canonical checkout is `~/branchbar`.
- Hannah's machine has no Xcode; `/usr/bin/git` is 2.39.5, Homebrew git 2.52 is first on PATH. Verify against 2.39.5.
