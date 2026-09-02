# SESSION HANDOFF — BranchBar

**Last updated:** 2026-09-02 04:00 by session `cced85a0-5ced-4282-bc94-e23dcbe42d18`

## Current state

- **Phase / packet:** Phase 3 complete; Gate 3 PASSED. Pushed at c09e55a (CI pending). Phase 4/5 in flight: 4.1 SwiftUI shell and 5.1a icon/packaging.
- **Suite:** 248 passing (`make test`)
- **In-flight agents:** 4.1 (packets/4.1.md; Sources/BranchBar/**, scripts/screenshot-states.sh, scripts/windowid.swift) and 5.1a-icon (scripts/render-icon.swift, scripts/make-icns.sh, Resources/icon-1024.png, scripts/bundle.sh icns step, Resources/Info.plist.template CFBundleIconFile).
- **Blocked on:** nothing. Hannah's own packet 0.0 items are open: ask Andrew Lisy whether JobRunner opened on NYT-managed Macs; name the NYT tester and their macOS version.

## Next steps (in order)

1. Confirm CI green at c09e55a.
2. Accept 4.1 (real popover shows real repos; 32 state fixtures render; ≥ 1 popover screenshot) and 5.1a-icon; commit; push.
3. Tag `v0.9.0`: `make zip` (arm64), Release with zip + sha256 + install note; send URL to the NYT tester (Gate 5 by 09-12). Target 09-10.
4. Dispatch 4.2 (packets/4.2.md: actions, Add folder…, Hide, gh sign-in action, launch at login) → Gate 4 screenshots reviewed by Hannah.
5. 5.1b hardening + 5.2 README/ARCHITECTURE/CLAUDE.md docs sync (`make doc-refs` script still to be written; ARCHITECTURE §2/§3 to fill).
6. Hannah: Gate 0b NYT tester (runbook sent), Gate 4.0 read of docs/UI-CONTRACT.md, Andrew Lisy question, Cursor push check.

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
