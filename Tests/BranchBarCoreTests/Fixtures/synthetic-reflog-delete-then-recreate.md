# synthetic: push, deletion, then a newer push of a new incarnation of the same branch name

Three lines: a push to OID a…, a deletion (all-zero new OID), then a push of a fresh branch that reuses the name and lands on OID d…. Walking newest-first, the observation is the **last** push (1788300000, OID d…); the boundary stops the walk before the first push, so the old incarnation's push is never attributed to the new branch.

Invariant: `pushBeforeADeletionBoundaryIsNotAttributedToTheRecreatedBranch`.
