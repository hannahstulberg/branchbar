# synthetic: the error a GUI-launched process gets when `gh` is not on its PATH

PLAN.md §2 verified that a GUI app's PATH is `/usr/bin:/bin:/usr/sbin:/sbin`, so a Homebrew `gh` is invisible unless `ToolLocator` finds it. This is the launch failure that has to become `PRUnavailableReason.ghNotInstalled` — a per-reason message with one action, not a thrown error that blanks the repo.

Invariant: `ghMissingMakesEveryBranchUnavailableWithoutThrowing`.
