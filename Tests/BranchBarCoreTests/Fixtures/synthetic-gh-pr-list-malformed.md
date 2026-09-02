# synthetic: `gh pr list --json` stdout truncated mid-row

`gh` exited 0 but the JSON stream stops inside the fourth field of the first object, which is what a killed child, a full pipe, or a proxy that closed the connection leaves behind. There is no way to record this from a healthy `gh`, so it is hand-written.

PLAN.md §3 and the packet 2.3 behavior line: malformed JSON is `PRUnavailableReason.commandFailed` — the repo says its PR status could not be read, and never a partial list presented as the truth.

Invariant: `malformedJSONIsCommandFailed`.
