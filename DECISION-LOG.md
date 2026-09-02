# DECISION LOG — BranchBar

<!-- Newest first. What / Why / Limits / Cost accepted / Deliberately not changed / Session. -->

## 2026-09-01 — Plan approved after three review rounds; Phase 0 begins

- **What:** PLAN.md approved by Hannah. Locked: Swift + SwiftPM on Command Line Tools (spike decides arm64 SwiftUI linking, Xcode is the same-day fallback), zipped ad-hoc-signed `.app` as a handout that NYT tests on a managed Mac by Sept 12, home scan to depth 6 plus "Add repository…", `gh`-based PR status with head-first matching and per-head fallback, reflog-file push time with an honest fallback label, lazy PR fetching, Merged vs Closed-without-merging groups, Open in Cursor as the primary action.
- **Why:** NYT PMs and designers on Claude Code via Bedrock have no desktop-app branch/worktree picker; the Sept 24 workshop teaches exactly that orientation.
- **Limits:** Cross-vendor codex Challenge did not run (CLI 0.142.3 rejects its configured model); the adversarial slot was a fresh-context Opus subagent. Rerun scheduled once codex upgrades.
- **Cost accepted:** Depth-6 scan is slower than depth 4 on large home folders; per-head PR queries add up to 20 gh calls per repo; the CLT constraint keeps one unproven link (arm64 SwiftUI interfaces) until the spike.
- **Deliberately not changed:** Not Electron (mirrors JobRunner but 96 MB and needs Node); not folder-picker-first discovery (Hannah chose auto-discovery); launch-at-login kept in v1 on the cut line; no `git fetch` ever.
- **Session:** `cced85a0-5ced-4282-bc94-e23dcbe42d18`
