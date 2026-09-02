# SESSIONS — BranchBar

<!-- One row per Claude Code session. Store the LOCAL session UUID (`claude --resume <uuid>`). -->

| Date | Session UUID | Model | What happened | Distilled log |
|---|---|---|---|---|
| 2026-09-01 | `cced85a0-5ced-4282-bc94-e23dcbe42d18` | Fable 5.1 (orchestrator), Opus subagents | Scoped and planned BranchBar with Hannah; Gate 1 (design, eng, Opus adversarial, then codex); built phases 0–5 via parallel Opus packets with red/green SHAs; pre-ship gate (code review + five codex rounds) drove fix waves F1–F18; cut v0.9.1 at 1038a4c | `session-logs/2026-09-01-plan-and-bootstrap.md` |

Provenance queries:

```bash
git log --format='%h %s %(trailers:key=Claude-Session-Local,valueonly)' | grep cced85a0
zgrep -h "<term>" session-logs/*.jsonl.gz
```
