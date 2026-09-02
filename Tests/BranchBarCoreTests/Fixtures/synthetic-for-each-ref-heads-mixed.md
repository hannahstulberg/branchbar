# synthetic: `for-each-ref -- refs/heads` rows covering every upstream and track state, plus a tag ref that collides with a branch name

Seven U+001F-separated fields per line, matching the frozen format in PLAN.md §5. Rows:

| Ref | `upstream:short` | `track,nobracket` | Models |
|---|---|---|---|
| `refs/heads/main` | `origin/main` | empty | in sync, and `%(HEAD)` is `*` |
| `refs/heads/ahead-two` | `origin/ahead-two` | `ahead 2` | the only count the UI shows |
| `refs/heads/behind-three` | `origin/behind-three` | `behind 3` | parsed, never displayed |
| `refs/heads/diverged` | `origin/diverged` | `ahead 1, behind 4` | both clauses on one line |
| `refs/heads/upstream-gone` | `origin/upstream-gone` | `gone` | "Upstream missing from last-known origin" |
| `refs/heads/no-upstream` | empty | empty | the track field is empty here **and** for `main` |
| `refs/heads/feature/nested name` | `origin/feature/nested name` | empty | a slash and a space inside a branch name |
| `refs/tags/main` | empty | empty | a tag sharing a branch name |

The `main` and `no-upstream` pair is the fixture for `inSyncAndNoUpstreamAreDistinguishedByUpstreamShortNotTrack`: the track field cannot tell them apart, only `upstream:short` can.

The `refs/tags/main` row does not appear under the frozen `-- refs/heads` invocation; it is here so a parser that ever sees a wider pattern cannot turn it into a branch named `main`. Non-`refs/heads/` refnames must not yield a branch.
