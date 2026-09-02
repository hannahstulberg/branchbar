# TEST PLAN — BranchBar

Every named invariant from PLAN.md §7 mapped to the test file that holds it and the packet that
owns it, plus the fixture inventory. Written in packet 1.1 alongside the contracts so a test author
and an implementer working from the same row could not disagree about what a case is called, and
reconciled in packet 5.2 against the suite as it actually landed.

Fixture rule (PLAN.md §3): `recorded-*` files are written by `make record-fixtures`, which runs
every frozen invocation against real repos with `/usr/bin/git` and `gh` — **no model transcribes
git output**. `synthetic-*` files are hand-written extensions for cases these repos cannot
produce, and each carries a sibling `.md` note. Recorded files are byte-exact, trailing newline
included.

## The suite

```bash
make test        # swift test --disable-xctest --enable-swift-testing
```

**257 tests, all green**, Swift Testing only. Two of them touch a real repo and skip themselves
with a recorded reason rather than failing; everything else replaces all three seams and touches
no network, no real repo, and no home folder.

| Test file | Tests | Holds |
|---|---:|---|
| `ContractTests.swift` | 17 | Frozen type shapes, the frozen environments, the test doubles, and `FixtureInventoryTests` |
| `FileCacheStoreTests.swift` | 8 | Atomic save, unknown schema version |
| `ForEachRefParserTests.swift` | 10 | Branch and remote-ref rows, upstream disambiguation |
| `GHClientTests.swift` | 14 | Per-host auth, the three list invocations, the cap, failure mapping |
| `GitClientTests.swift` | 10 | Every frozen git invocation's argument array and environment |
| `GitHubSlugTests.swift` | 16 | Remote URL to host, owner, name, GitHub Enterprise included |
| `GitVersionTests.swift` | 6 | Version parsing and the 2.39 comparison |
| `GuardTests.swift` | 3 | Structural bans and fixture existence |
| `LiveRepoSanityTests.swift` | 2 | The two live-repo tests, both skippable on CI |
| `PRListDecoderTests.swift` | 8 | JSON decode and the `updatedAt` sort |
| `PRStatusMapperTests.swift` | 11 | Pill mapping, head-first matching, the open-elsewhere key |
| `ProcessCommandRunnerTests.swift` | 11 | Pipe draining, timeout, cancellation, argument safety |
| `PushInfoDeriverTests.swift` | 8 | Observation versus commit date, `originMovedSince`, gone upstream |
| `RealFileSystemTests.swift` | 3 | Directory listing with resource values |
| `ReflogFileReaderTests.swift` | 11 | The usable-line predicate and the deletion boundary |
| `ReflogParserTests.swift` | 5 | The `git reflog show` fallback format |
| `RefreshCoordinatorTests.swift` | 24 | Coalescing, cap, deadline, cancellation, stable order, lazy PR |
| `RepoAssemblerTests.swift` | 17 | The join and the three groups |
| `RepoLoaderTests.swift` | 11 | Seven stages, per-stage isolation, PR cache TTL |
| `RepoScannerTests.swift` | 21 | The walk, the skip rules, classification, dedupe |
| `ScanDeadlineTests.swift` | 6 | The 20 s scan bound, partial results, gated folders last |
| `SmokeTests.swift` | 1 | The package builds and links |
| `SnapshotPresenterTests.swift` | 15 | Every state fixture, the copy rules, accessibility labels |
| `StringsTests.swift` | 9 | State coverage, banned vocabulary, the `states/` fixture writer |
| `ToolLocatorTests.swift` | 4 | The search order and what it records |
| `WorktreeListParserTests.swift` | 6 | Primary, linked, detached, locked, prunable, bare |

Two invariants are held under a different name than PLAN.md §7 gave them, both recorded here so a
search for the plan's name finds them: `everyFrozenGitInvocationReturnsExpectedShapeOnThisRepo` is
`everyFrozenGitInvocationReturnsOutputOnThisRepo` in `LiveRepoSanityTests.swift`, and
`observedPushLabelSaysFromThisMacNeverYouPushed` is
`pushedLabelWordsDifferForYouPushedVsTipCommitDate` in `SnapshotPresenterTests.swift`, with the
string half asserted in `StringsTests.swift`.

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
which is expected. What must not move is the **shape**, and `FixtureInventoryTests` (in
`ContractTests.swift`) asserts it.

The `states/` fixtures are not recorded by a script. `stateFixturesAreRecordedForEveryState` in
`StringsTests.swift` writes one file per row of the `docs/UI-CONTRACT.md` state table, with the
real `JSONEncoder` and only when the bytes change, so `make test` on a clean tree leaves it clean
and a change to a frozen type breaks there rather than at Gate 4.

## Invariants → tests

Every row below is implemented and green. The `Test file` column names where the invariant lives
today; the `Packet` column names who wrote it.

### Push observation — packets 2.1 (parsers), 2.2 (derivation and copy)

| Invariant | Test file | Packet | Fixture |
|---|---|---|---|
| `reflogShowFallbackReturnsRowsForARefThatHasPushes` | `LiveRepoSanityTests.swift` | 1.1 | live `~/branchbar` |
| `reflogFieldsSplitOnUnitSeparatorNotLiteralPercent1f` | `ReflogParserTests.swift` | 2.1 | `recorded-*-reflog-show-origin-main.txt` |
| `reflogFileLastUsablePushLineParsesUnixTimestampFromField5` | `ReflogFileReaderTests.swift` | 2.1 | `recorded-reflog-hannah-personal-agent-origin-main.txt` |
| `emptyReflogFileFallsBackToTipCommitDate` | `ReflogFileReaderTests.swift` | 2.1 | `synthetic-reflog-empty.txt`, `recorded-reflog-hannah-personal-agent-origin-updates-3-29-26.txt` |
| `pushDeletionLineIsNotTreatedAsAPush` | `ReflogFileReaderTests.swift` | 2.1 | `synthetic-reflog-deletion-line.txt` |
| `pushBeforeADeletionBoundaryIsNotAttributedToTheRecreatedBranch` | `ReflogFileReaderTests.swift` | 2.1 | `synthetic-reflog-delete-then-recreate.txt` |
| `reflogFileWithOnlyFetchLinesFallsBack` | `ReflogFileReaderTests.swift` | 2.1 | `synthetic-reflog-fetch-only.txt` |
| `pushFromAnotherMachineYieldsNoObservationNotAFakeDate` | `ReflogFileReaderTests.swift` | 2.1 | `synthetic-reflog-fetch-only.txt` |
| `observedPushWhoseOIDIsNotTheRemoteTipSetsOriginMovedSince` | `PushInfoDeriverTests.swift`, `ReflogFileReaderTests.swift` | 2.1, 2.2 | `synthetic-reflog-push-oid-differs-from-tip.txt` + `synthetic-for-each-ref-remotes.txt` |
| `reflogPushBeatsTipCommitDate` | `PushInfoDeriverTests.swift` | 2.2 | `synthetic-reflog-push-and-fetch.txt` |
| `fallbackLabelDoesNotClaimGitHubObservedTheBranch` | `StringsTests.swift` | 4.0 | `PushInfo.Source` cases |
| `observedPushLabelSaysFromThisMacNeverYouPushed`, as `pushedLabelWordsDifferForYouPushedVsTipCommitDate` | `SnapshotPresenterTests.swift`, `StringsTests.swift` | 2.2, 4.0 | `states/origin-moved-since.json`, `states/last-push-unknown.json` |
| `noUpstreamRendersNeverPushedNotZeroCommits` | `PushInfoDeriverTests.swift`, `SnapshotPresenterTests.swift` | 2.2 | `synthetic-for-each-ref-heads-mixed.txt` |

### Git parsing — packet 2.1

| Invariant | Test file | Packet | Fixture |
|---|---|---|---|
| `everyFrozenGitInvocationReturnsExpectedShapeOnThisRepo`, as `everyFrozenGitInvocationReturnsOutputOnThisRepo` | `LiveRepoSanityTests.swift` | 1.1 | live `~/branchbar` |
| `inSyncAndNoUpstreamAreDistinguishedByUpstreamShortNotTrack` | `ForEachRefParserTests.swift` | 2.1 | `synthetic-for-each-ref-heads-mixed.txt` |
| `noBranchWorktreeAppearsUnderRepoAndNoBranchClaimsIt` | `WorktreeListParserTests.swift`, `RepoAssemblerTests.swift` | 2.1, 3.1 | `synthetic-worktree-list-multi.txt` |

### PR status — packets 2.2 (pure mapping), 2.3 (the client), 3.1 (the loader)

| Invariant | Test file | Packet | Fixture |
|---|---|---|---|
| `prListDecoderSortsByUpdatedAtDescendingRegardlessOfInputOrder` | `PRListDecoderTests.swift` | 2.2 | `synthetic-gh-pr-list-mixed.json` |
| `emptyReviewDecisionStringIsNotAReviewDecision` | `PRStatusMapperTests.swift` | 2.2 | `synthetic-gh-pr-list-mixed.json`, `recorded-gh-pr-list-hannah-personal-agent.json` |
| `forkOriginatedPRStillMatchesItsLocalBranch` | `PRStatusMapperTests.swift`, `RepoAssemblerTests.swift` | 2.2, 3.1 | `synthetic-gh-pr-list-mixed.json` (PR 110) |
| `openElsewhereKeyedByOwnerAndBranchNotBranchAlone` | `PRStatusMapperTests.swift`, `RepoAssemblerTests.swift` | 2.2, 3.1 | `synthetic-gh-pr-list-mixed.json` |
| `openPRsNotOnThisMacExcludesHeadsThatExistLocally` | `PRStatusMapperTests.swift`, `RepoAssemblerTests.swift` | 2.2, 3.1 | `synthetic-gh-pr-list-mixed.json` + `synthetic-for-each-ref-heads-mixed.txt` |
| `unqueriedBranchIsNotCheckedNeverNone` | `GHClientTests.swift`, `RepoAssemblerTests.swift` | 2.3, 3.1 | `synthetic-gh-pr-list-empty.json` |
| `branchWithAnOlderPRStillResolvesItsPRStatusViaHeadQuery` | `GHClientTests.swift` | 2.3 | `recorded-gh-pr-list-head-hannah-personal-agent.json` |
| `perHeadFallbackRespectsPerRepoCap` | `GHClientTests.swift` | 2.3 | `RecordedCommandRunner` call count |
| `ghMissingMakesEveryBranchUnavailableWithoutThrowing` | `GHClientTests.swift` | 2.3 | `synthetic-gh-not-found.txt` |
| `authStatusFailureShortCircuitsPRListForAllReposOnThatHost` | `GHClientTests.swift` | 2.3 | `synthetic-gh-auth-status-401.txt` |
| `rateLimitResponseMapsToRateLimitedNotCommandFailed` | `GHClientTests.swift` | 2.3 | `synthetic-gh-rate-limit-403.txt` |
| `enterpriseHostRemoteResolvesSlugAndAuthPreflightPerHost` | `GitHubSlugTests.swift` (slug half), `GHClientTests.swift` (preflight half) | 1.1, 2.3 | `synthetic-config-remote-origin-url-ghe.txt` |
| `prCacheWithinTTLIssuesNoGhCalls` | `RepoLoaderTests.swift`, `GHClientTests.swift` | 3.1, 2.3 | `RecordedCommandRunner` call count |
| `firstRefreshDoesNotIssueGhCallsForCollapsedRepos` | `RefreshCoordinatorTests.swift` | 3.2 | `RecordedCommandRunner` call count |
| `refreshStillUpdatesGitStateWhenPRCacheIsWarm` | `RefreshCoordinatorTests.swift` | 3.2 | `RecordedCommandRunner` call count |

### Discovery — packets 2.4 (the walk) and 3.3 (the bound)

| Invariant | Test file | Packet | Fixture |
|---|---|---|---|
| `hiddenDirectoriesUnderHomeAreSkipped` | `RepoScannerTests.swift` | 2.4 | `InMemoryFileSystem` |
| `repoAtDepthSixIsFoundAndDepthSevenIsNot` | `RepoScannerTests.swift` | 2.4 | `InMemoryFileSystem` |
| `extraRootScansRecursivelyWithoutDepthLimit` | `RepoScannerTests.swift` | 2.4 | `InMemoryFileSystem` |
| `doesNotDescendIntoDiscoveredRepo` | `RepoScannerTests.swift` | 2.4 | `InMemoryFileSystem` |
| `gitFilePointingIntoWorktreesIsExcludedAndReported` | `RepoScannerTests.swift` | 2.4 | `InMemoryFileSystem.addGitFile` |
| `unreadableDirectoryIsReportedNotSilentlySkipped` | `RepoScannerTests.swift` | 2.4 | `InMemoryFileSystem.markUnreadable` |
| `scanSummaryReportsDepthCutAndHiddenSkips` | `RepoScannerTests.swift` | 2.4 | `InMemoryFileSystem` |
| `tccGatedFoldersAreEnumeratedLast`, and `anAddedRootNamedDocumentsIsWalkedWithoutDeferral` beside it (packet 3.3, beyond §7) | `ScanDeadlineTests.swift` | 3.3 | `InMemoryFileSystem` with a blocking directory |
| `scanIsCooperativelyCancellable`, `aScanThatFinishesIsNotMarkedTruncated` (packet 3.3, beyond §7) | `ScanDeadlineTests.swift` | 3.3 | `InMemoryFileSystem` with a listing that blocks |
| `realFileSystemNeverCallsAttributesOfItem`, `realFileSystemListsFiveThousandEntriesUnderOneSecond` (packet 3.3, beyond §7) | `ScanDeadlineTests.swift` | 3.3 | a real temp directory |
| `scanThatExceedsTheDeadlineYieldsPartialReposAndMarksScanStale`, `aScanThatFinishesInsideTheDeadlineIsNotDelayedOrMarkedStale` (packet 3.3, beyond §7) | `RefreshCoordinatorTests.swift` | 3.3 | `RefreshPolicy.scanDeadline` plus a blocking scanner |

### Process and cache seams — packet 2.5

| Invariant | Test file | Packet | Fixture |
|---|---|---|---|
| `commandRunnerReturnsFullOutputWhenStdoutExceedsPipeBuffer` (≥ 1 MB) | `ProcessCommandRunnerTests.swift` | 2.5 | generated in-test, `/bin/cat` |
| `commandRunnerDrainsStderrConcurrentlyWithStdout` | `ProcessCommandRunnerTests.swift` | 2.5 | generated in-test |
| `branchNameBeginningWithDashIsPassedAsOperandNotFlag` | `ProcessCommandRunnerTests.swift`, `GitClientTests.swift` | 2.5, 2.1 | argument array (shape asserted in `ContractTests.swift`) |
| `interruptedSaveLeavesPreviousCacheIntact` | `FileCacheStoreTests.swift` | 2.5 | temp directory |
| `unknownSchemaVersionLoadsNil` | `FileCacheStoreTests.swift` | 2.5 | in-test JSON |

### Join and grouping — packet 3.1

| Invariant | Test file | Packet | Fixture |
|---|---|---|---|
| `branchWithCommitsAfterItsMergeIsNotInMergedGroup` | `RepoAssemblerTests.swift` | 3.1 | `synthetic-gh-pr-list-mixed.json` (PR 106) |
| `closedUnmergedBranchIsNotLabelledMerged` | `RepoAssemblerTests.swift` | 3.1 | `synthetic-gh-pr-list-mixed.json` (PR 107) |
| `oneRepoFailingLeavesOthersPopulated` | `RepoLoaderTests.swift`, `RefreshCoordinatorTests.swift` | 3.1, 3.2 | `RecordedCommandRunner` failure stub |

### Refresh lifecycle — packet 3.2

| Invariant | Test file | Packet | Fixture |
|---|---|---|---|
| `peakConcurrencyNeverExceedsCap` | `RefreshCoordinatorTests.swift` | 3.2 | `RecordedCommandRunner.tracksConcurrency` |
| `secondRefreshWhileRunningCoalesces` | `RefreshCoordinatorTests.swift` | 3.2 | `RecordedCommandRunner` call count |
| `refreshHonorsOverallDeadlineAndMarksUnfinishedReposStale` | `RefreshCoordinatorTests.swift` | 3.2 | `RecordedCommandRunner` stub delays |
| `cancelledRepoTasksTerminateTheirChildProcesses` | `RefreshCoordinatorTests.swift`, `ProcessCommandRunnerTests.swift` | 3.2, 2.5 | `ProcessCommandRunner` + a sleeping child |
| `rowOrderIsStableAcrossProgressiveEmits` | `RefreshCoordinatorTests.swift` | 3.2 | `synthetic-refresh-charlie-*` + both recorded repos, staggered delays |

### Copy — packets 4.0 (strings) and 2.2 (presenter)

| Invariant | Test file | Packet | Fixture |
|---|---|---|---|
| `mergedCopyNamesBaseRefAndMakesNoDeletionClaim` | `SnapshotPresenterTests.swift` | 2.2 | `synthetic-gh-pr-list-mixed.json` (PR 106, base `release/2026-09`) |
| `upstreamGoneCopySaysLastKnownOriginNotDeletedOnGitHub` | `SnapshotPresenterTests.swift` | 2.2 | `synthetic-for-each-ref-heads-mixed.txt` (`upstream-gone`) |
| `aheadCountLabelledRelativeToLastKnownRemoteNotAbsolute` | `SnapshotPresenterTests.swift` | 2.2 | `synthetic-for-each-ref-heads-mixed.txt` (`ahead-two`) |
| `emptyScanRendersActionableEmptyState` | `SnapshotPresenterTests.swift` | 2.2 | empty `Snapshot` |
| `unavailableReasonCopyNamesOneActionPerReason` | `StringsTests.swift`, `SnapshotPresenterTests.swift` | 4.0, 2.2 | `PRUnavailableReason` cases |
| `everyStringsEntryIsReachableFromSomeState` | `StringsTests.swift` | 4.0 | the §5a state table |
| `everyStateFixtureRendersItsExpectedStrings` (parameterized over all 34 states) | `SnapshotPresenterTests.swift` | 2.2 | `states/*.json` |
| `everyFixtureStringIsRenderedOrOnAFrozenExemptionList` | `SnapshotPresenterTests.swift` | 2.2 | `states/*.json` plus the frozen view-owned chrome list |

### Structural guards — packet 1.1

| Invariant | Test file | Packet | Fixture |
|---|---|---|---|
| `noAppKitOrSwiftUIImportInCore` | `GuardTests.swift` | 1.1 | source tree via `#filePath` |
| `noXCTestImportAnywhere` | `GuardTests.swift` | 1.1 | source tree via `#filePath` |
| `everyFixtureReferencedByATestExists` | `GuardTests.swift` | 1.1 | source tree via `#filePath` |
| Every synthetic fixture has a sibling `# synthetic:` note | `ContractTests.swift` | 1.1 | the fixtures directory |

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
| `recorded-gh-auth-status-github.com.txt` | 6 | 267 | a successful keyring auth report. The script merges stdout and stderr, which is why it is right on both the gh releases that print to stderr and gh 2.89, which prints to stdout |
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
| `synthetic-for-each-ref-heads-malformed.txt` | 5 | 257 | a truncated row and blank lines between good rows, so the parser reports rather than crashes |
| `synthetic-for-each-ref-remotes.txt` | 7 | 573 | the `origin/HEAD` symbolic ref, tips for the mixed heads, and a second remote (`upstream`) |
| `synthetic-reflog-push-and-fetch.txt` | 3 | 459 | pushes interleaved with a fetch; the newest usable line is a push |
| `synthetic-reflog-fetch-only.txt` | 3 | 475 | fetch and pull lines only — a push from another machine, which this clone never observed |
| `synthetic-reflog-deletion-line.txt` | 3 | 447 | newest line is a deletion (all-zero **new** OID) with real pushes below it |
| `synthetic-reflog-delete-then-recreate.txt` | 3 | 447 | push, deletion, then a newer push of a new incarnation of the same name |
| `synthetic-reflog-push-oid-differs-from-tip.txt` | 2 | 298 | an observed push whose OID is not the current remote tip |
| `synthetic-reflog-empty.txt` | 0 | 0 | a zero-byte reflog file |
| `synthetic-gh-pr-list-mixed.json` | 10 | 4701 | draft, `REVIEW_REQUIRED`, `""`, `CHANGES_REQUESTED`, `APPROVED`, `MERGED` with `mergeCommit`, `CLOSED` unmerged, two PRs on one head (one OPEN one CLOSED), a fork PR |
| `synthetic-gh-pr-list-empty.json` | 0 | 3 | `[]` for a repo with no PRs |
| `synthetic-gh-pr-list-malformed.json` | — | 184 | stdout truncated mid-row, so a decode failure is a `RepoError` and not a crash |
| `synthetic-gh-auth-status-401.txt` | 8 | 328 | `HTTP 401: Bad credentials` |
| `synthetic-gh-rate-limit-403.txt` | 3 | 246 | `HTTP 403: API rate limit exceeded` |
| `synthetic-gh-not-found.txt` | 1 | 35 | the launch failure a GUI process gets when `gh` is not on its PATH |
| `synthetic-config-remote-origin-url-ghe.txt` | 1 | 60 | a GitHub Enterprise remote |
| `synthetic-refresh-charlie-rev-parse.txt` | 2 | 75 | the third repo packet 3.2 needs so a stable order has a middle element |
| `synthetic-refresh-charlie-for-each-ref-heads.txt` | 1 | 90 | its one branch, dated older than both recorded repos |
| `synthetic-refresh-charlie-for-each-ref-remotes.txt` | 1 | 77 | its one remote-tracking ref |
| `synthetic-refresh-charlie-worktree-list.txt` | 4 | 114 | its one primary worktree |
| `synthetic-refresh-charlie-config-remote-origin-url.txt` | 1 | 46 | its remote, on a third owner |

### States — `Fixtures/states/`, written by the suite

34 files, one per row of the `docs/UI-CONTRACT.md` state table, each carrying the exact argument
list of `SnapshotPresenter.present` plus the literal strings that state is contracted to show.
`SnapshotPresenterTests` asserts against every one of them, `scripts/screenshot-states.sh` renders
every one of them through the real app for Gate 4, and `StringsTests` rewrites a file only when its
bytes change.

`ahead-of-last-known-origin`, `closed-unmerged-group`, `cursor-not-installed`, `deadline-exceeded`,
`detached-worktree`, `first-run-scanning`, `gh-not-authenticated`, `gh-not-installed`,
`git-too-old`, `hidden-repo`, `in-sync`, `last-push-unknown`, `launch-at-login-needs-approval`,
`merged-group`, `no-github-remote`, `no-remote`, `not-scanned-folders`, `open-prs-not-on-this-mac`,
`origin-moved-since`, `pr-approved`, `pr-changes-requested`, `pr-draft`, `pr-list-timeout`,
`pr-not-checked`, `pr-not-loaded`, `pr-open`, `rate-limited`, `refresh-running`, `repo-failed`,
`single-branch-no-pr-never-pushed`, `stale-rows-at-launch`, `upstream-missing`, `worktree-checkout`,
`zero-repos`.

## Test doubles

`Tests/BranchBarCoreTests/Support/`. They replace all three seams, so `swift test` never touches
the network, a real repo, or the home folder (PLAN.md §4 trust boundary).

| Double | Replaces | Notes |
|---|---|---|
| `RecordedCommandRunner` | `CommandRunner` | Matches on executable **basename** plus arguments plus working directory, so a stub is machine-independent. Records every call; fails the test on an unstubbed command; per-stub delays and an opt-in `tracksConcurrency` peak-in-flight probe for `peakConcurrencyNeverExceedsCap`. |
| `InMemoryFileSystem` | `FileSystem` | Dictionary-backed tree with directory entries, file contents, mtimes, executable flags, symlink marks, and an unreadable set that throws an EPERM-shaped `PermissionDenied`. `addGitFile` writes a `gitdir:` pointer the way a worktree checkout does. |
| `InMemoryCacheStore` | `CacheStore` | Counts loads and saves; `saveError` / `loadError` force failures. |
| `Fixture` | — | `Fixture.text(_:)` / `Fixture.data(_:)` resolve from `#filePath`, because PLAN.md §5b forbids `resources:` in `Package.swift`. |
