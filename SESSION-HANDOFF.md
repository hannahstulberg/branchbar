# SESSION HANDOFF — BranchBar

**Last updated:** 2026-09-02 15:00 by session `cced85a0-5ced-4282-bc94-e23dcbe42d18`

## Current state

- **Phase / packet:** Waves F1–F10 accepted and pushed (01d1ae0). In flight: F11 (streaming scan helper so a killed helper still yields the repos it found; cancel strings; Repo.remoteOwners; non-origin fixtures). Queued: F12 (shell: FooterStrings → Strings, remoteOwners log), F9 docs (PLAN §5 amended, README, ARCHITECTURE re-derive), codex round 3, then v0.9.1.
- **Suite:** 360 passing
- **In-flight agents:** F11 (packets/F11.md).
- **Blocked on:** nothing. Hannah's own packet 0.0 items are open: ask Andrew Lisy whether JobRunner opened on NYT-managed Macs; name the NYT tester and their macOS version.

## Next steps (in order)

1. Accept F11; commit; push. Dispatch F12 (shell) then F9 (docs; packets/F9.md).
2. codex round 3 on HEAD; require no BLOCKER; fold majors.
3. Cut v0.9.1: VERSION + BranchBarCore.version, tag, CI release, notes; send URL + README steps to the NYT tester (Gate 5 by 09-12).
4. Hannah: Gate 0b spike result, Gate 4 screenshots, Gate 4.0 strings, Andrew Lisy question.

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
