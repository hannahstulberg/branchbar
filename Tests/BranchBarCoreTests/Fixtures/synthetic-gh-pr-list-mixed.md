# synthetic: a `gh pr list --json` array covering all ten PR states plus a shared head and a fork PR

The recorded list from `hannah-personal-agent` holds only `MERGED` and `CLOSED` PRs with an empty `reviewDecision`, so every other pill state is modelled here. Ten rows, deliberately **not** sorted by `updatedAt`:

| # | Head | State | Models |
|---|---|---|---|
| 101 | `draft-branch` | OPEN, `isDraft` | the draft pill |
| 102 | `awaiting-review` | OPEN, `REVIEW_REQUIRED` | open with a decision pending |
| 103 | `no-decision-yet` | OPEN, `""` | an empty string is not a review decision |
| 104 | `needs-changes` | OPEN, `CHANGES_REQUESTED` | the changes-requested pill |
| 105 | `signed-off` | OPEN, `APPROVED` | the approved pill |
| 106 | `shipped` | MERGED, `mergeCommit.oid` set, base `release/2026-09` | the Merged group, whose copy names the base ref |
| 107 | `abandoned` | CLOSED, `mergeCommit` null | Closed without merging |
| 108 | `shared-head` | CLOSED | first of two PRs on one head |
| 109 | `shared-head` | OPEN | second of two; the tie-break prefers OPEN |
| 110 | `fork-feature` | OPEN, owner `contributor` | head owner differs from the repo owner |

Row 110 is the fork case: matching is by `headRefName` first, so a differing `headRepositoryOwner.login` must never exclude it.

Invariants: `emptyReviewDecisionStringIsNotAReviewDecision`, `forkOriginatedPRStillMatchesItsLocalBranch`, `prListDecoderSortsByUpdatedAtDescendingRegardlessOfInputOrder`, `closedUnmergedBranchIsNotLabelledMerged`, `mergedCopyNamesBaseRefAndMakesNoDeletionClaim`.
