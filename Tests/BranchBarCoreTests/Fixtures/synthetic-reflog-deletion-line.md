# synthetic: a reflog file whose newest line is a deletion, with real pushes below it

The last line has an all-zero **new** OID, which is what `git push --delete` writes. Walking newest-first hits the deletion boundary immediately, so the two genuine pushes below it are never reported: the branch was deleted on the remote and this clone has no current push to claim.

Invariant: `pushDeletionLineIsNotTreatedAsAPush`.
