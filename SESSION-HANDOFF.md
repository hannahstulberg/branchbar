# SESSION HANDOFF — BranchBar

**Last updated:** 2026-09-02 06:00 by session `cced85a0-5ced-4282-bc94-e23dcbe42d18`

## Current state

- **Phase / packet:** 3.3 accepted (320c086). `v0.9.0` tagged at 4c2cacc; CI release job builds and attaches the zip. In flight: 4.3 (ShellStrings → Strings, prURL, repo path). Queued: 5.2 docs, Gate 5 (NYT tester on v0.9.0 by 09-12), 5.1b v1.0.0.
- **Suite:** 256 passing
- **In-flight agents:** 4.3 (packets/4.3.md).
- **Blocked on:** nothing. Hannah's own packet 0.0 items are open: ask Andrew Lisy whether JobRunner opened on NYT-managed Macs; name the NYT tester and their macOS version.

## Next steps (in order)

1. Accept 3.3 (scan under deadline, resource-values enumeration, TCC folders last); commit; push; confirm CI.
2. Dispatch 4.3 (small Core+shell follow-up: move shell strings into Strings.swift + exemption list; BranchRowVM.prURL; RepoSectionVM.path; docs/UI-CONTRACT regenerate).
3. 5.1a: bump VERSION to 0.9.0, `make zip`, tag v0.9.0, Release with zip + sha256 + install note; send to NYT tester (Gate 5 by 09-12).
4. Dispatch 5.2 docs (packets/5.2.md). Then Gate 4 screenshot review with Hannah (dist/screens/).
5. Hannah: Gate 0b NYT tester result, Gate 4.0 read of docs/UI-CONTRACT.md, Andrew Lisy question, Cursor push check.

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
