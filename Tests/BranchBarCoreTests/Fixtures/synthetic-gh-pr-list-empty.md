# synthetic: an empty `gh pr list --json` array

`[]`, two bytes. A repo with no PRs at all. Decodes to an empty list, never an error — and a branch in such a repo whose head **was** queried gets `PRStatus.none`, while one that was not gets `notChecked`.

Invariant: `unqueriedBranchIsNotCheckedNeverNone`.
