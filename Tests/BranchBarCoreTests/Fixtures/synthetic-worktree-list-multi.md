# synthetic: a repo with six linked worktrees plus a bare mirror, covering every attribute `git worktree list --porcelain -z` can print

Records, in order: the primary worktree on `main`; an Agents-mode worktree at `.claude/worktrees/spike` on `worktree-spike`; a **detached** worktree, which has `HEAD` and `detached` and no `branch` line (PLAN.md §3 renders it "Worktree at commit abc1234 (no branch)" and it must never join a branch); a worktree whose **path contains spaces** and whose branch name also contains a space, so only the first space separates key from value; a **locked** worktree carrying a reason after `locked `; a **prunable** worktree carrying a reason; and a **bare** repo, which prints `worktree` and `bare` and no `HEAD` at all.

Written in the NUL-delimited `-z` form the invocation was re-frozen to after the codex pre-ship
review (MAJOR 12): every line is followed by `\0` and every record by one more `\0`, with no
newlines and no blank-line terminator. Extends the recorded single-worktree output, which this machine's two repos are limited to. Bare repos are out of scope for v1 (PLAN.md §3) but the parser still has to survive the record.

Invariants: `noBranchWorktreeAppearsUnderRepoAndNoBranchClaimsIt`.
