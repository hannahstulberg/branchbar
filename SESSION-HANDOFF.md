# SESSION HANDOFF — BranchBar

**Last updated:** 2026-09-02 00:20 by session `cced85a0-5ced-4282-bc94-e23dcbe42d18`

## Current state

- **Phase / packet:** Phase 1 done (0.3 spike zip published as v0.0.1-spike; 1.1 contracts frozen). Phase 2 lanes + 4.0 dispatched concurrently: 4.0 (Strings/UI contract), 2.1-T, 2.3-T, 2.4-T (test authors), 2.5 (runner/cache/fs, single agent).
- **Suite:** 43 passing (`make test`)
- **In-flight agents:** 4.0, 2.1-T, 2.3-T, 2.4-T, 2.5 (specs in the session scratchpad `packets/`). Each uses its own `--scratch-path .build/pk-<name>` to avoid build-lock contention. Stub files are flat under `Sources/BranchBarCore/`.
- **Blocked on:** nothing. Hannah's own packet 0.0 items are open: ask Andrew Lisy whether JobRunner opened on NYT-managed Macs; name the NYT tester and their macOS version.

## Next steps (in order)

1. Accept the three test-author packets (2.1-T, 2.3-T, 2.4-T): tests exist and fail for the right reason; commit as `red(2.x)`; then dispatch the matching implementers (specs 2.1-impl.md; 2.3.md and 2.4.md implementer role).
2. Accept 4.0 (Hannah reads the string table = Gate 4.0) and 2.5; commit.
3. After 2.1/2.2/2.3 green: dispatch 3.1, then 3.2 (with `branchbar-cli`), then 4.1.
4. Hannah: Cursor push test (spike item 10, commands in DECISION-LOG), Andrew Lisy question, NYT tester named.

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
