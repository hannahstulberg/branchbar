# SESSION HANDOFF — BranchBar

**Last updated:** 2026-09-03 02:00 by session `cced85a0-5ced-4282-bc94-e23dcbe42d18`

## Current state

- **Phase / packet:** **v0.9.1 released** (https://github.com/hannahstulberg/branchbar/releases/tag/v0.9.1, built by CI from bfbfc6f; zip + sha256 verified after download, both executables signed). Next external check: Gate 5 (NYT tester on a managed Mac, by 09-12) and Gate 0b (spike zip) if not already done.
- **Suite:** 444 passing; `make doc-refs` 72/72
- **In-flight agents:** none.
- **Blocked on:** nothing. Hannah's own packet 0.0 items are open: ask Andrew Lisy whether JobRunner opened on NYT-managed Macs; name the NYT tester and their macOS version.

## Next steps (in order)

1. Hannah sends the NYT tester the v0.9.1 URL + README install steps (Gate 5 checklist in PLAN.md §8); record the report in DECISION-LOG.
2. Hannah: Gate 0b spike result, Gate 4 screenshots (dist/screens/), Gate 4.0 string table (docs/UI-CONTRACT.md), Andrew Lisy question, Cursor push check (spike item 10).
3. On Gate 5 pass: 5.2 README screenshots from the tester's dialogs, tag v1.0.0 (5.1b).
4. v1.0 backlog (DECISION-LOG round-4 and round-5 entries): whole-repo-load helper for dead filesystems; component-wise openat; posix_spawn; recent-100 count-equals-limit; open-elsewhere suppression rule; a regression test for the terminateChild ordering.

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
