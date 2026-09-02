# TEST PLAN — BranchBar

Every named invariant from PLAN.md §7 mapped to the test file that will hold it and the packet
that owns it, plus the fixture inventory. Frozen in packet 1.1 alongside the contracts, so a test
author and an implementer working from the same row cannot disagree about what a case is called.

Fixture rule (PLAN.md §3): `recorded-*` files are written by `make record-fixtures`, which runs
every frozen invocation against real repos with `/usr/bin/git` and `gh` — **no model transcribes
git output**. `synthetic-*` files are hand-written extensions for cases these repos cannot
produce, and each carries a sibling `.md` note. Recorded files are byte-exact, trailing newline
included.

## Re-recording

```bash
make record-fixtures        # rewrites Tests/BranchBarCoreTests/Fixtures/recorded-*
```

The script exits non-zero, naming the offending command, when an invocation that must return rows
returns empty stdout or an empty JSON array. That is Gate 1.1's criterion and it is why a frozen
command that quietly stopped matching — the way `git reflog show --` returns zero rows and exit 0
— cannot survive a re-record. Overrides for another machine or a rotated fixture repo:
`BRANCHBAR_RECORD_GIT`, `BRANCHBAR_RECORD_GH`, `BRANCHBAR_RECORD_REPO_A`,
`BRANCHBAR_RECORD_REPO_B`, `BRANCHBAR_RECORD_SLUG`, `BRANCHBAR_RECORD_HOST`,
`BRANCHBAR_RECORD_HEAD`.

Row counts in the inventory below are from the 2026-09-01 recording; they move as the repos move,
which is expected. What must not move is the **shape**, and `FixtureInventoryTests` asserts it.

## Invariants → tests

Rows marked ✅ are implemented and green as of packet 1.1. Everything else names the file the
owning packet creates.

### Push observation — packet 2.1 (parsers) and 2.2 (derivation and copy)

| Invariant | Test file | Packet | Fixture |
|---|---|---|---|
| `reflogShowFallbackReturnsRowsForARefThatHasPushes` ✅ | `LiveRepoSanityTests.swift` | 1.1 | live `~/branchbar` |
| `reflogFieldsSplitOnUnitSeparatorNotLiteralPercent1f` | `ReflogParserTests.swift` | 2.1 | `recorded-*-reflog-show-origin-main.txt` |
| `reflogFileLastUsablePushLineParsesUnixTimestampFromField5` | `ReflogFileReaderTests.swift` | 2.1 | `recorded-reflog-hannah-personal-agent-origin-main.txt` |
| `emptyReflogFileFallsBackToTipCommitDate` | `ReflogFileReaderTests.swift` | 2.1 | `synthetic-reflog-empty.txt`, `recorded-reflog-hannah-personal-agent-origin-updates-3-29-26.txt` |
| `pushDeletionLineIsNotTreatedAsAPush` | `ReflogFileReaderTests.swift` | 2.1 | `synthetic-reflog-deletion-line.txt` |
| `pushBeforeADeletionBoundaryIsNotAttributedToTheRecreatedBranch` | `ReflogFileReaderTests.swift` | 2.1 | `synthetic-reflog-delete-then-recreate.txt` |
| `reflogFileWithOnlyFetchLinesFallsBack` | `ReflogFileReaderTests.swift` | 2.1 | `synthetic-reflog-fetch-only.txt` |
| `pushFromAnotherMachineYieldsNoObservationNotAFakeDate` | `ReflogFileReaderTests.swift` | 2.1 | `synthetic-reflog-fetch-only.txt` |
| `observedPushWhoseOIDIsNotTheRemoteTipSetsOriginMovedSince` | `PushInfoDeriverTests.swift` | 2.2 | `synthetic-reflog-push-oid-differs-from-tip.txt` + `synthetic-for-each-ref-remotes.txt` |
| `reflogPushBeatsTipCommitDate` | `PushInfoDeriverTests.swift` | 2.2 | `synthetic-reflog-push-and-fetch.txt` |
| `fallbackLabelDoesNotClaimGitHubObservedTheBranch` | `SnapshotPresenterTests.swift` | 2.2 | `synthetic-reflog-fetch-only.txt` |
| `observedPushLabelSaysFromThisMacNeverYouPushed` | `SnapshotPresenterTests.swift` | 2.2 | `synthetic-reflog-push-and-fetch.txt` |
| `noUpstreamRendersNeverPushedNotZeroCommits` | `SnapshotPresenterTests.swift` | 2.2 | `synthetic-for-each-ref-heads-mixed.txt` |

Acceptance tests for 2.1 are written by a separate agent before the implementer starts (PLAN.md §3).

### Git parsing — packet 2.1

| Invariant | Test file | Packet | Fixture |
|---|---|---|---|
| `everyFrozenGitInvocationReturnsExpectedShapeOnThisRepo` ✅ | `LiveRepoSanityTests.swift`, as `everyFrozenGitInvocationReturnsOutputOnThisRepo` | 1.1 | live `~/branchbar` |
| `inSyncAndNoUpstreamAreDistinguishedByUpstreamShortNotTrack` | `ForEachRefParserTests.swift` | 2.1 | `synthetic-for-each-ref-heads-mixed.txt` |
| `noBranchWorktreeAppearsUnderRepoAndNoBranchClaimsIt` | `WorktreeListParserTests.swift`, `RepoAssemblerTests.swift` | 2.1, 3.1 | `synthetic-worktree-list-multi.txt` |

### PR status — packet 2.2 (pure mapping) and 2.3 (the client)

| Invariant | Test file | Packet | Fixture |
|---|---|---|---|
| `prListDecoderSortsByUpdatedAtDescendingRegardlessOfInputOrder` | `PRListDecoderTests.swift` | 2.2 | `synthetic-gh-pr-list-mixed.json` |
| `emptyReviewDecisionStringIsNotAReviewDecision` | `PRStatusMapperTests.swift` | 2.2 | `synthetic-gh-pr-list-mixed.json`, `recorded-gh-pr-list-hannah-personal-agent.json` |
| `forkOriginatedPRStillMatchesItsLocalBranch` | `PRStatusMapperTests.swift` | 2.2 | `synthetic-gh-pr-list-mixed.json` (PR 110) |
| `openElsewhereKeyedByOwnerAndBranchNotBranchAlone` | `PRStatusMapperTests.swift` | 2.2 | `synthetic-gh-pr-list-mixed.json` |
| `openPRsNotOnThisMacExcludesHeadsThatExistLocally` | `PRStatusMapperTests.swift` | 2.2 | `synthetic-gh-pr-list-mixed.json` + `synthetic-for-each-ref-heads-mixed.txt` |
| `unqueriedBranchIsNotCheckedNeverNone` | `GHClientTests.swift`, `RepoAssemblerTests.swift` | 2.3, 3.1 | `synthetic-gh-pr-list-empty.json` |
| `branchWithAnOlderPRStillResolvesItsPRStatusViaHeadQuery` | `GHClientTests.swift` | 2.3 | `recorded-gh-pr-list-head-hannah-personal-agent.json` |
| `perHeadFallbackRespectsPerRepoCap` | `GHClientTests.swift` | 2.3 | `RecordedCommandRunner` call count |
| `ghMissingMakesEveryBranchUnavailableWithoutThrowing` | `GHClientTests.swift` | 2.3 | `synthetic-gh-not-found.txt` |
| `authStatusFailureShortCircuitsPRListForAllReposOnThatHost` | `GHClientTests.swift` | 2.3 | `synthetic-gh-auth-status-401.txt` |
| `rateLimitResponseMapsToRateLimitedNotCommandFailed` | `GHClientTests.swift` | 2.3 | `synthetic-gh-rate-limit-403.txt` |
| `enterpriseHostRemoteResolvesSlugAndAuthPreflightPerHost` | `GitHubSlugTests.swift` ✅ (slug half), `GHClientTests.swift` (preflight half) | 1.1, 2.3 | `synthetic-config-remote-origin-url-ghe.txt` |
| `prCacheWithinTTLIssuesNoGhCalls` | `RepoLoaderTests.swift` | 3.1 | `RecordedCommandRunner` call count |
| `firstRefreshDoesNotIssueGhCallsForCollapsedRepos` | `RefreshCoordinatorTests.swift` | 3.2 | `RecordedCommandRunner` call count |
| `refreshStillUpdatesGitStateWhenPRCacheIsWarm` | `RefreshCoordinatorTests.swift` | 3.2 | `RecordedCommandRunner` call count |

Acceptance tests for 2.3 are written by a separate agent before the implementer starts.

### Discovery — packet 2.4

| Invariant | Test file | Packet | Fixture |
|---|---|---|---|
| `hiddenDirectoriesUnderHomeAreSkipped` | `RepoScannerTests.swift` | 2.4 | `InMemoryFileSystem` |
| `repoAtDepthSixIsFoundAndDepthSevenIsNot` | `RepoScannerTests.swift` | 2.4 | `InMemoryFileSystem` |
| `extraRootScansRecursivelyWithoutDepthLimit` | `RepoScannerTests.swift` | 2.4 | `InMemoryFileSystem` |
| `doesNotDescendIntoDiscoveredRepo` | `RepoScannerTests.swift` | 2.4 | `InMemoryFileSystem` |
| `gitFilePointingIntoWorktreesIsExcludedAndReported` | `RepoScannerTests.swift` | 2.4 | `InMemoryFileSystem.addGitFile` |
| `unreadableDirectoryIsReportedNotSilentlySkipped` | `RepoScannerTests.swift` | 2.4 | `InMemoryFileSystem.markUnreadable` |
| `scanSummaryReportsDepthCutAndHiddenSkips` | `RepoScannerTests.swift` | 2.4 | `InMemoryFileSystem` |

Acceptance tests for 2.4 are written by a separate agent before the implementer starts.

### Process and cache seams — packet 2.5

| Invariant | Test file | Packet | Fixture |
|---|---|---|---|
| `commandRunnerReturnsFullOutputWhenStdoutExceedsPipeBuffer` (≥ 1 MB) | `ProcessCommandRunnerTests.swift` | 2.5 | generated in-test, `/bin/cat` |
| `commandRunnerDrainsStderrConcurrentlyWithStdout` | `ProcessCommandRunnerTests.swift` | 2.5 | generated in-test |
| `branchNameBeginningWithDashIsPassedAsOperandNotFlag` | `ProcessCommandRunnerTests.swift` | 2.5 | argument array (shape asserted in `ContractTests.swift` ✅) |
| `interruptedSaveLeavesPreviousCacheIntact` | `FileCacheStoreTests.swift` | 2.5 | temp directory |
| `unknownSchemaVersionLoadsNil` | `FileCacheStoreTests.swift` | 2.5 | in-test JSON |

### Join and grouping — packet 3.1

| Invariant | Test file | Packet | Fixture |
|---|---|---|---|
| `branchWithCommitsAfterItsMergeIsNotInMergedGroup` | `RepoAssemblerTests.swift` | 3.1 | `synthetic-gh-pr-list-mixed.json` (PR 106) |
| `closedUnmergedBranchIsNotLabelledMerged` | `RepoAssemblerTests.swift` | 3.1 | `synthetic-gh-pr-list-mixed.json` (PR 107) |
| `oneRepoFailingLeavesOthersPopulated` | `RepoLoaderTests.swift` | 3.1 | `RecordedCommandRunner` failure stub |

### Refresh lifecycle — packet 3.2

| Invariant | Test file | Packet | Fixture |
|---|---|---|---|
| `peakConcurrencyNeverExceedsCap` | `RefreshCoordinatorTests.swift` | 3.2 | `RecordedCommandRunner.tracksConcurrency` |
| `secondRefreshWhileRunningCoalesces` | `RefreshCoordinatorTests.swift` | 3.2 | `RecordedCommandRunner` call count |
| `refreshHonorsOverallDeadlineAndMarksUnfinishedReposStale` | `RefreshCoordinatorTests.swift` | 3.2 | `RecordedCommandRunner` stub delays |
| `cancelledRepoTasksTerminateTheirChildProcesses` | `RefreshCoordinatorTests.swift` | 3.2 | `ProcessCommandRunner` + a sleeping child |
| `rowOrderIsStableAcrossProgressiveEmits` | `RefreshCoordinatorTests.swift` | 3.2 | `RecordedCommandRunner` staggered delays |

Acceptance tests for 3.2's deadline and cancellation are written by a separate agent before the
implementer starts.

### Copy — packet 4.0 (strings) and 2.2 (presenter)

| Invariant | Test file | Packet | Fixture |
|---|---|---|---|
| `mergedCopyNamesBaseRefAndMakesNoDeletionClaim` | `SnapshotPresenterTests.swift` | 2.2 | `synthetic-gh-pr-list-mixed.json` (PR 106, base `release/2026-09`) |
| `upstreamGoneCopySaysLastKnownOriginNotDeletedOnGitHub` | `SnapshotPresenterTests.swift` | 2.2 | `synthetic-for-each-ref-heads-mixed.txt` (`upstream-gone`) |
| `aheadCountLabelledRelativeToLastKnownRemoteNotAbsolute` | `SnapshotPresenterTests.swift` | 2.2 | `synthetic-for-each-ref-heads-mixed.txt` (`ahead-two`) |
| `emptyScanRendersActionableEmptyState` | `SnapshotPresenterTests.swift` | 2.2 | empty `Snapshot` |
| `unavailableReasonCopyNamesOneActionPerReason` | `StringsTests.swift` | 4.0 | `PRUnavailableReason` cases |
| `everyStringsEntryIsReachableFromSomeState` | `StringsTests.swift` | 4.0 | §5a state table |

### Structural guards — packet 1.1

| Invariant | Test file | Packet | Fixture |
|---|---|---|---|
| `noAppKitOrSwiftUIImportInCore` ✅ | `GuardTests.swift` | 1.1 | source tree via `#filePath` |
| `noXCTestImportAnywhere` ✅ | `GuardTests.swift` | 1.1 | source tree via `#filePath` |
| `everyFixtureReferencedByATestExists` ✅ | `GuardTests.swift` | 1.1 | source tree via `#filePath` |

## Fixture inventory

### Recorded — `make record-fixtures`, 2026-09-01

`/usr/bin/git` 2.39.5 (Apple Git-154) and `gh` 2.89.0, against `~/hannah-personal-agent`
(3 local branches, 1 worktree, 19 remote refs including many `origin/claude/*`, 17 PRs) and
`~/branchbar`.

| File | Rows | Bytes | What it holds |
|---|---:|---:|---|
| `recorded-hannah-personal-agent-for-each-ref-heads.txt` | 3 | 285 | in-sync `main` with `%(HEAD)` `*`, a branch with no upstream, a branch with an upstream and an empty track field |
| `recorded-hannah-personal-agent-for-each-ref-remotes.txt` | 19 | 1969 | the `origin/HEAD` symbolic ref the parser skips, plus 18 real remote-tracking refs |
| `recorded-hannah-personal-agent-worktree-list.txt` | 4 | 123 | one primary worktree on a branch |
| `recorded-hannah-personal-agent-rev-parse.txt` | 2 | 93 | absolute common dir and top level |
| `recorded-hannah-personal-agent-config-remote-origin-url.txt` | 1 | 60 | an HTTPS github.com remote with `.git` |
| `recorded-hannah-personal-agent-reflog-show-origin-main.txt` | 29 | 2349 | the fallback invocation with **no** `--`, three U+001F fields per row |
| `recorded-branchbar-for-each-ref-heads.txt` | 1 | 90 | a single-branch repo |
| `recorded-branchbar-for-each-ref-remotes.txt` | 1 | 77 | a repo with one remote-tracking ref |
| `recorded-branchbar-worktree-list.txt` | 4 | 111 | one primary worktree |
| `recorded-branchbar-rev-parse.txt` | 2 | 69 | absolute common dir and top level |
| `recorded-branchbar-config-remote-origin-url.txt` | 1 | 48 | this repo's remote |
| `recorded-branchbar-reflog-show-origin-main.txt` | 4 | 324 | the fallback on a young repo |
| `recorded-reflog-hannah-personal-agent-origin-main.txt` | 29 | 4582 | a real reflog **file** full of `update by push` lines |
| `recorded-reflog-hannah-personal-agent-origin-updates-3-29-26.txt` | 0 | 0 | a reflog file that exists and is **empty** — the observation behind the rule |
| `recorded-reflog-branchbar-origin-main.txt` | 4 | 632 | a reflog file whose first line is a creation (all-zero **old** OID, not a deletion) |
| `recorded-gh-auth-status-github.com.txt` | 6 | 267 | a successful keyring auth report |
| `recorded-gh-pr-list-hannah-personal-agent.json` | 17 | 8322 | `headRepositoryOwner` as an object, `reviewDecision` as `""`, one null `mergeCommit` |
| `recorded-gh-pr-list-head-hannah-personal-agent.json` | 1 | 497 | the per-head fallback returning one PR |
| `recorded-gh-pr-list-author-me-hannah-personal-agent.json` | 0 | 3 | `[]` — an honest empty answer, allowed by Gate 1.1 |

### Synthetic — hand-written, each with a sibling `.md` note

None of these formats has a comment syntax a parser could safely skip, so the
`# synthetic: <what it models>` header lives on the first line of the sibling note rather than
inside the fixture. `FixtureInventoryTests` enforces that every synthetic has one.

| File | Rows | Bytes | What it models |
|---|---:|---:|---|
| `synthetic-worktree-list-multi.txt` | 29 | 911 | 7 records: primary, Agents-mode worktree, detached (no branch), path and branch with spaces, locked with reason, prunable with reason, bare |
| `synthetic-for-each-ref-heads-mixed.txt` | 8 | 810 | ahead / behind / both / gone / no upstream / in sync / nested-and-spaced name / a `refs/tags/main` colliding with a branch name |
| `synthetic-for-each-ref-remotes.txt` | 7 | 573 | the `origin/HEAD` symbolic ref, tips for the mixed heads, and a second remote (`upstream`) |
| `synthetic-reflog-push-and-fetch.txt` | 3 | 459 | pushes interleaved with a fetch; the newest usable line is a push |
| `synthetic-reflog-fetch-only.txt` | 3 | 475 | fetch and pull lines only — a push from another machine, which this clone never observed |
| `synthetic-reflog-deletion-line.txt` | 3 | 447 | newest line is a deletion (all-zero **new** OID) with real pushes below it |
| `synthetic-reflog-delete-then-recreate.txt` | 3 | 447 | push, deletion, then a newer push of a new incarnation of the same name |
| `synthetic-reflog-push-oid-differs-from-tip.txt` | 2 | 298 | an observed push whose OID is not the current remote tip |
| `synthetic-reflog-empty.txt` | 0 | 0 | a zero-byte reflog file |
| `synthetic-gh-pr-list-mixed.json` | 10 | 4701 | draft, `REVIEW_REQUIRED`, `""`, `CHANGES_REQUESTED`, `APPROVED`, `MERGED` with `mergeCommit`, `CLOSED` unmerged, two PRs on one head (one OPEN one CLOSED), a fork PR |
| `synthetic-gh-pr-list-empty.json` | 0 | 3 | `[]` for a repo with no PRs |
| `synthetic-gh-auth-status-401.txt` | 8 | 328 | `HTTP 401: Bad credentials` |
| `synthetic-gh-rate-limit-403.txt` | 3 | 246 | `HTTP 403: API rate limit exceeded` |
| `synthetic-gh-not-found.txt` | 1 | 35 | the launch failure a GUI process gets when `gh` is not on its PATH |
| `synthetic-config-remote-origin-url-ghe.txt` | 1 | 60 | a GitHub Enterprise remote |

## Test doubles

`Tests/BranchBarCoreTests/Support/`. They replace all three seams, so `swift test` never touches
the network, a real repo, or the home folder (PLAN.md §4 trust boundary).

| Double | Replaces | Notes |
|---|---|---|
| `RecordedCommandRunner` | `CommandRunner` | Matches on executable **basename** plus arguments plus working directory, so a stub is machine-independent. Records every call; fails the test on an unstubbed command; per-stub delays and an opt-in `tracksConcurrency` peak-in-flight probe for `peakConcurrencyNeverExceedsCap`. |
| `InMemoryFileSystem` | `FileSystem` | Dictionary-backed tree with directory entries, file contents, mtimes, executable flags, symlink marks, and an unreadable set that throws an EPERM-shaped `PermissionDenied`. `addGitFile` writes a `gitdir:` pointer the way a worktree checkout does. |
| `InMemoryCacheStore` | `CacheStore` | Counts loads and saves; `saveError` / `loadError` force failures. |
| `Fixture` | — | `Fixture.text(_:)` / `Fixture.data(_:)` resolve from `#filePath`, because PLAN.md §5b forbids `resources:` in `Package.swift`. |
