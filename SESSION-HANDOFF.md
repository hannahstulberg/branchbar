# SESSION HANDOFF — BranchBar

**Last updated:** 2026-09-02 19:30 by session `cced85a0-5ced-4282-bc94-e23dcbe42d18`

## Current state

- **Phase / packet:** Waves F1–F14 and docs F9 accepted and pushed (f922f83 code, 29a841f docs). codex round 4 running on HEAD (scratchpad/review/codex-ship4.md). Stop rule: ship v0.9.1 on no BLOCKER; majors triaged into DECISION-LOG (fix if they falsify a user-facing claim, else v1.0 backlog).
- **Suite:** 416 passing; `make doc-refs` 72 rows green; bundle verify passes with the helper
- **In-flight agents:** none (codex round 4 is a background shell task).
- **Blocked on:** nothing. Hannah's own packet 0.0 items are open: ask Andrew Lisy whether JobRunner opened on NYT-managed Macs; name the NYT tester and their macOS version.

## Next steps (in order)

1. Read codex round 4; verify any blocker firsthand; small fixes → F15; log every finding.
2. Cut v0.9.1: VERSION 0.9.1 + `BranchBarCore.version`, commit, tag, push; CI release job attaches the zip; edit release notes (install steps, both Applications folders, folder-access prompt); send URL + README to the NYT tester (Gate 5 by 09-12).
3. Update PLAN.md §8 status rows and the review log; refresh this file.
4. Hannah: Gate 0b spike result, Gate 4 screenshot feedback, Gate 4.0 string table, Andrew Lisy question.

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
