# synthetic: `worktree list --porcelain -z` where a worktree path and a branch name contain newlines

Three NUL-terminated records. Record 2's `worktree` path and `branch` ref both carry a literal
`\n`, and record 3's path carries a literal tab. Under the newline-delimited porcelain git 2.39.5
prints those bytes raw, so a line-based parser splits one record into several and the whole
worktree stage fails — which is codex MAJOR 12, and why `GitClient.worktrees` runs `-z` and
`WorktreeListParser` reads bytes between NULs.

Record separator is an empty field: every line is followed by `\0`, and each record is followed by
one more `\0`, exactly as `git worktree list --porcelain -z` writes it.

Invariants: `worktreePathWithNewlineParsesUnderZ`.
