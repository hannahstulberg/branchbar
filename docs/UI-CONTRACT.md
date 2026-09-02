# UI contract

Frozen by packet 4.0, before any SwiftUI exists. PLAN.md §5a numbers the four sections and this
document keeps those numbers: **1. State table**, **2. String table**, **3. Row hierarchy**,
**4. Token table**.

Every literal here lives in `Sources/BranchBarCore/Strings.swift` and reaches the screen through
`SnapshotPresenter` (packet 2.2), so the SwiftUI layer holds no copy of its own. Section 2 is
generated from that file by `make doc-strings` and must not be hand-edited. Sections 1, 3, and 4
are hand-written and reviewed at Gate 4.0.

One `Tests/BranchBarCoreTests/Fixtures/states/<state>.json` exists per row of section 1, recorded
by `Tests/BranchBarCoreTests/StringsTests.swift` with the real `JSONEncoder`. Each file carries the
exact argument list of `SnapshotPresenter.present` plus the strings that state is contracted to
show, so packet 2.2 asserts against it and Gate 4 screenshots it.

Vocabulary is the NYT workshop's — repo, branch, worktree, PR, push, commit, origin, folder. The
words the session never teaches (detached, HEAD, upstream, ref, SHA, reflog, stderr, exit code) are
banned by `noEngineeringVocabularyInUserStrings`, with two locked exceptions noted in section 2.

---

## 1. State table

Every state PLAN.md §5a item 1 names, plus every state implied by a case of a type packet 1.1
froze: ten `PRStatus` cases, six `PRUnavailableReason` cases, three `PushInfo.Source` cases, six
`RepoError.Stage` cases, six `UserFacingFailure.Action.Kind` cases. The `State` column is the
fixture filename stem.

| State | Trigger | What the user sees (literal string) | Primary action | Secondary |
|---|---|---|---|---|
| `first-run-scanning` | No cache; the home-folder scan is running | "Looking for repos" / "BranchBar is looking through your home folder for repos. It does this once, then remembers what it found." / "Not updated yet" | — (scan in flight) | "Version 0.9.0" in the footer |
| `zero-repos` | Scan finished with no repos | "No repos found" / "BranchBar looked under your home folder and found no repos. Repos kept in Google Drive, Dropbox, or iCloud Drive, or more than six folders deep, are not part of that first look. Add the folder that holds yours and BranchBar will look all the way down it." | "Add folder…" (`addFolder`) | "Rescan" (`rescan`) |
| `zero-repos-documents-denied` | Scan finished with no repos **and** a folder macOS would not let BranchBar read | "No repos found" / "Not scanned: Documents" / "Also skipped on purpose: hidden folders, Library, anything more than six folders deep, and folders inside a repo BranchBar already found." | "Allow access…" (`grantFolderAccess`) | "Add folder…", "Rescan" |
| `not-scanned-folders` | `ScanResult.unreadableDirectories` is non-empty, or the scan skipped categories by design | "Not scanned: Documents, Desktop" / "Also skipped on purpose: hidden folders, Library, anything more than six folders deep, and folders inside a repo BranchBar already found." / "Folders you added" | "Allow access…" (`grantFolderAccess`) | "Add folder…", "Rescan", "Remove" per added folder |
| `gh-not-installed` | `ToolLocator` found no `gh` | "GitHub CLI not found" / "BranchBar could not find the GitHub CLI on this Mac, so it cannot show PR status. Branches, worktrees, and pushes still show." / pill "PR status unavailable" | "Open cli.github.com" (`openURL`) | — |
| `gh-not-authenticated` | `gh auth status --hostname <host>` failed | "Not signed in to github.com" / "The GitHub CLI is installed but not signed in to github.com. BranchBar can open Terminal with the sign-in command ready for you to run." | "Open Terminal" (`openTerminalWithGhAuthLogin`, payload `gh auth login --hostname github.com`) | — |
| `rate-limited` | `gh` returned a rate-limit response | "GitHub is rate limiting BranchBar" / "GitHub is limiting how many requests it will answer right now. Waiting a few minutes and refreshing again fixes this." | "Refresh" (`retryRefresh`) | — |
| `no-github-remote` | `remote.origin.url` parsed, host is not GitHub | "Origin is not on GitHub" / "This repo's origin is not a GitHub address, so BranchBar cannot look up PRs for it. Branches, worktrees, and pushes still show." | "Refresh" (`retryRefresh`) | — |
| `no-remote` | `git config --get remote.origin.url` returned nothing | "No origin for this repo" / "This repo has no origin, so there is no PR to look up. Branches, worktrees, and commits still show." | "Refresh" (`retryRefresh`) | — |
| `pr-list-timeout` | `gh pr list` hit its 25 s timeout: `PRUnavailableReason.timedOut`, and only the runner's timeout | "PR status did not load" / "The GitHub CLI did not answer for this repo in time. Refreshing usually fixes it." / repo notice "Could not read PR status for this repo. Refresh to try again." | "Refresh" (`retryRefresh`) | — |
| `gh-forbidden` | `gh` returned a 403 that is neither rate limiting nor a credential problem: SAML, an IP allow-list, an organization policy, a missing grant | "GitHub refused this request" / "GitHub refused this request for github.com/newsroom/demo (policy, SSO, or scopes). Signing in again will not fix it." | "Refresh" (`retryRefresh`) | — |
| `gh-command-failed` | Any other `gh` failure: a 404, a renamed repo, malformed JSON, a cancelled call | "PR status did not load" / "The GitHub CLI reported an error for this repo: HTTP 404: Not Found" | "Refresh" (`retryRefresh`) | — |
| `single-branch-no-pr-never-pushed` | The modal NYT case: one local branch, head queried, no PR, no upstream | "Branches and worktrees" / "Checked out" / pill "No PR" / "No tracked remote branch · push history not checked" / tooltip "BranchBar only reads push history for a branch that tracks one on origin, so it has not checked this one." | "Open in Cursor" | "Show in Finder", "Copy path", "Refresh PRs now", "Open BranchBar at login", "Quit BranchBar" |
| `pr-not-loaded` | Repo is collapsed, so `gh` never ran for it | pill "PR status loads when expanded" | "Expand" | "Collapse" |
| `pr-not-checked` | The per-head query never ran: cap of 20, or the 45 s deadline | pill "PR status not checked yet" | "Refresh PRs now" | — |
| `repo-failed` | One repo's git stage failed while the others populated | "Could not read this repo's branches. Refresh to try again." / "Could not read this repo's worktrees. Refresh to try again." / "Could not read this repo's last-known origin. Refresh to try again." / "Could not read this repo's push history, so push dates may be missing." | "Refresh" (`retryRefresh`) | — |
| `deadline-exceeded` | The overall 45 s deadline cut the refresh short | "BranchBar stopped after 45 seconds. Repos that did not finish are marked out of date." / per repo "This repo did not finish in time. What you see may be out of date." | "Refresh" (`retryRefresh`) | — |
| `stale-rows-at-launch` | Rows restored from `CacheFile.lastSnapshot` while the first refresh runs | "Showing the list from the last time BranchBar ran. Updating now…" | — (refresh already running) | — |
| `stale-rows-idle` | Rows left unfinished with no refresh running: a cancelled refresh, or one the 45 s deadline cut short | "Some repos did not finish updating. Refresh to try again." | "Refresh" (`retryRefresh`) | — |
| `git-too-old` | `git --version` below 2.39 | "BranchBar works best with git 2.39 or newer. This Mac has 2.30.1, so some branch details may be missing." | — | — |
| `git-not-found` | `ToolLocator` found no `git`, so the preflight failed and no command ran | "git not found" / "BranchBar could not find git on this Mac, so it cannot read any repo. Run xcode-select --install in Terminal, then try again." | "Refresh" (`retryRefresh`) | — (this state replaces the empty state; the footer carries it when a cached list is on screen) |
| `cursor-not-installed` | `open -a Cursor` has no Cursor to open | "Cursor is not installed on this Mac, so rows open in VS Code instead — or in Terminal if neither is installed." | "Open in VS Code" | "Open in Terminal" |
| `last-push-unknown` | `PushInfo.source == .tipCommitDate`: no usable push line (file absent, empty, fetch-only, deletion-only, expired) | "Last push unknown · newest commit dated 2 days ago" / tooltip "BranchBar has no record of this branch going out from this Mac. The date shown is when the newest commit was made, not when it left." | "Open in Cursor" | "Copy path" |
| `origin-moved-since` | `PushInfo.source == .reflogObserved` and the observed OID is not the remote-tracking tip | "Pushed from this Mac 2 days ago (origin has moved since)" / tooltip "BranchBar saw this push leave this Mac. It cannot see pushes made from your other computers." | "Open in Cursor" | "Open PR" |
| `pr-draft` | Matched PR with `isDraft == true` | pill "Draft" / "Pushed from this Mac 3 hours ago" | "Open in Cursor" | "Open PR" |
| `pr-open` | Matched PR, state OPEN, no review decision | pill "Open" | "Open in Cursor" | "Open PR" |
| `pr-changes-requested` | Matched PR, `reviewDecision == CHANGES_REQUESTED` | pill "Changes requested" | "Open in Cursor" | "Open PR" |
| `pr-approved` | Matched PR, `reviewDecision == APPROVED` | pill "Approved" | "Open in Cursor" | "Open PR" |
| `merged-group` | PR merged, local tip equals the PR head, no worktree holds the branch | group "Merged" / pill "Merged" / "PR merged into main. Local tip matches GitHub's current PR head." | "Open in Cursor" | "Open PR" |
| `closed-unmerged-group` | PR closed without merging | group "Closed without merging" / pill "Closed" / "PR closed without merging. This branch may hold work that was never merged." | "Open in Cursor" | "Open PR" |
| `open-prs-not-on-this-mac` | An author-`@me` open PR whose (head owner, head branch) matches no local branch | group "Open PRs not on this Mac" / "Yours and open on GitHub, with no branch of that name on this Mac." / row "#128 · hotfix-from-laptop" | "Open PR" (`openURL`) | — |
| `upstream-missing` | `%(upstream:track,nobracket)` reported `gone` | "Upstream missing from last-known origin" | "Open in Cursor" | "Copy path" |
| `ahead-of-last-known-origin` | `Upstream.ahead > 0` | "2 ahead of last-known origin" / tooltip "Counted against last-known origin, last seen 3 hours ago. BranchBar never fetches, so origin may have moved." | "Open in Cursor" | "Open PR" |
| `origin-not-fetched` | `Upstream.ahead > 0` and this clone has no `FETCH_HEAD` | tooltip "Counted against last-known origin. This repo has not fetched yet. BranchBar never fetches, so origin may have moved." | "Open in Cursor" | "Copy path" |
| `non-origin-upstream` | The branch tracks a remote other than `origin`, so every count and every moved-since clause names that remote | "2 ahead of last-known fork" / "Pushed from this Mac 1 day ago (fork has moved since)" / tooltip "Counted against last-known fork. This repo's last fetch changed FETCH_HEAD 3 hours ago. BranchBar never fetches, so fork may have moved." | "Open in Cursor" | "Copy path" |
| `untracked-remote-branch` | No tracking configuration, and `for-each-ref -- refs/remotes/` listed `origin/<branch>` — the ref whose reflog produced the push line | "Pushed from this Mac 2 days ago" / "origin has a branch of the same name, which this branch does not track" | "Open in Cursor" | "Copy path" |
| `in-sync` | Tracked (by `%(upstream:short)`), nothing ahead and nothing behind | "In sync with last-known origin" | "Open in Cursor" | "Copy path" |
| `non-origin-in-sync` | Tracked against a remote other than `origin`, nothing ahead and nothing behind: the claim names the repository the comparison used | "In sync with last-known fork" | "Open in Cursor" | "Copy path" |
| `non-origin-upstream-missing` | The branch tracked a remote other than `origin` and `%(upstream:track,nobracket)` reported `gone`: the sentence names that remote, never origin | "Upstream missing from last-known fork" | "Open in Cursor" | "Copy path" |
| `behind-only` | Tracked, `Upstream.ahead == 0` and `Upstream.behind > 0` | "No local commits ahead of last-known origin" | "Open in Cursor" | "Copy path" |
| `detached-worktree` | `git worktree list --porcelain` printed `detached` | "Worktree at commit abc1234 (no branch)" | "Open in Cursor" | "Show in Finder" |
| `worktree-checkout` | A branch is checked out in a linked worktree folder | "Worktree in demo-agents-2" | "Open in Cursor" | "Show in Finder" |
| `refresh-running` | `RefreshState.running(completed, total)` | "Updating 3 of 12 repos…" / button "Cancel", read by VoiceOver as "Cancel the running refresh" | "Cancel" (ends the running refresh) | — |
| `hidden-repo` | The user hid a repo from the list; the footer offers it back | footer "Show hidden (1)" / beside the repo "Hidden" | "Hide this repo" | "Stop hiding this repo" |
| `launch-at-login-needs-approval` | The login-item toggle was flipped and `SMAppService` has not been allowed yet, or cannot be used from where this copy is running | "macOS is waiting for approval. Open System Settings → General → Login Items and turn BranchBar on under “Open at Login”." | "Open BranchBar at login" (the toggle) | the four other outcomes: translocated, no bundle identifier, not in /Applications, both mechanisms refused |

**Notes on states that share copy.** `gh pr list` timing out and `gh pr list` failing are one
`PRUnavailableReason.commandFailed`, because packet 1.1 froze six reasons and no seventh; the
timeout is named in `UserFacingFailure.diagnostic`, which is logged and never rendered. `noRemote`
and `notGitHubRemote` both offer "Refresh" rather than a repo-editing action: the app runs no
write commands, so refreshing after the user adds an origin is the only honest next step.

**Notes on states whose condition is not in the fixture.** `StateFixture` froze the six arguments
of `SnapshotPresenter.present`, and three states turn on something outside that envelope: whether
Cursor is installed (`cursor-not-installed`), which repo the user hid and whether "Show hidden" is
on (`hidden-repo`), and what `SMAppService` answered on this Mac
(`launch-at-login-needs-approval`). Each carries an ordinary snapshot and supplies its own
condition — the tests off the fixture's id, the app off `BRANCHBAR_PREVIEW_HIDDEN` for the two
halves of the hide toggle.

---

## 2. String table

Generated from `Sources/BranchBarCore/Strings.swift` by `make doc-strings`. Do not hand-edit
between the markers — edit the doc comment on the member instead and rerun.

**One locked exception to the banned-vocabulary rule:** `upstreamMissing` reads "Upstream missing
from last-known origin" because PLAN.md §3 locks that wording verbatim, having chosen it over
"deleted on GitHub" (BranchBar never fetches, so it cannot assert what GitHub holds now).
`noEngineeringVocabularyInUserStrings` asserts the exception list holds nothing else.

<!-- BEGIN doc-strings: generated by scripts/doc-strings.sh; edit Strings.swift, not this table -->
| Group | Member | State it serves | Literal |
|---|---|---|---|
| App chrome | `menuBarAccessibilityLabel` | `first-run-scanning` — the menu bar item itself, in every state. | `BranchBar: branches, worktrees, and PR status` |
| First run and refresh progress | `firstRunTitle` | `first-run-scanning` — heading while the first home-folder scan runs. | `Looking for repos` |
| First run and refresh progress | `firstRunMessage` | `first-run-scanning` — says the scan happens once and is remembered. | `BranchBar is looking through your home folder for repos. It does this once, then remembers what it found.` |
| First run and refresh progress | `refreshRunning` | `refresh-running` — footer while a refresh is in flight. | `Updating 3 of 12 repos…` |
| First run and refresh progress | `cancelRefreshActionLabel` | `refresh-running` — the button beside the progress line. `AppModel.cancelRefresh()` has existed since F6 and had no control to call it, so a refresh stuck behind a folder macOS has not answered for could only be waited out. One word, because it sits beside Refresh and Refresh PRs in a 340 pt popover. | `Cancel` |
| First run and refresh progress | `cancelRefreshAccessibilityLabel` | `refresh-running` — what VoiceOver reads for that button. Spoken on its own, "Cancel" does not say what is being cancelled, and the row it sits in is not read with it. | `Cancel the running refresh` |
| Git not found | `gitNotFoundTitle` | `git-not-found` — heading when the preflight found no `git` on this Mac. Nothing else in the app can run without it: there is no repo to read, no branch to list, and no push to date, so this replaces the empty state rather than sitting above it (REVIEW CR-04). | `git not found` |
| Git not found | `gitNotFoundMessage` | `git-not-found` — names the missing program and the one command that installs it. Apple's copy of git ships with the Command Line Tools, which is what the README's Requirements section already tells a tester to install, so the sentence and the README give the same instruction. | `BranchBar could not find git on this Mac, so it cannot read any repo. Run xcode-select --install in Terminal, then try again.` |
| Git not found | `gitNotFound` | `git-not-found` — the whole state as one value, so the shell that discovers the missing git and the presenter that renders it cannot word it differently. `diagnostic` carries the directories `ToolLocator` looked in, which is logged and never rendered. | the title and message above, with the action `Refresh` |
| Zero repos | `emptyStateTitle` | `zero-repos` — heading when the scan finished and found nothing. | `No repos found` |
| Zero repos | `emptyStateMessage` | `zero-repos` — names the two reasons a repo is missing and points at Add folder…. | `BranchBar looked under your home folder and found no repos. Repos kept in Google Drive, Dropbox, or iCloud Drive, or more than six folders deep, are not part of that first look. Add the folder that holds yours and BranchBar will look all the way down it.` |
| Zero repos | `addFolderActionLabel` | `zero-repos`, `not-scanned-folders` — primary action of the empty state. | `Add folder…` |
| Zero repos | `rescanActionLabel` | `zero-repos`, `not-scanned-folders` — run the home scan again. | `Rescan` |
| What the scan could not read, and what it skipped on purpose | `notScanned` | `not-scanned-folders` — folders macOS would not let BranchBar read. | `Not scanned: Documents, Desktop` |
| What the scan could not read, and what it skipped on purpose | `grantFolderAccessActionLabel` | `not-scanned-folders` — re-triggers the macOS access prompt for those folders. | `Allow access…` |
| What the scan could not read, and what it skipped on purpose | `skippedCategoriesSummary` | `not-scanned-folders` — the categories the home scan skips by design (PLAN.md §3). | `Also skipped on purpose: hidden folders, Library, anything more than six folders deep, and folders inside a repo BranchBar already found.` |
| What the scan could not read, and what it skipped on purpose | `scanRootsHeading` | `not-scanned-folders` — footer heading above the Add folder… roots. | `Folders you added` |
| What the scan could not read, and what it skipped on purpose | `removeScanRootActionLabel` | `not-scanned-folders` — drops one added folder from the scan. | `Remove` |
| PR status unavailable, one reason at a time | `ghNotInstalledTitle` | `gh-not-installed` — heading when the GitHub CLI is not on this Mac. | `GitHub CLI not found` |
| PR status unavailable, one reason at a time | `ghNotInstalledMessage` | `gh-not-installed` — says what is missing and what still works without it. | `BranchBar could not find the GitHub CLI on this Mac, so it cannot show PR status. Branches, worktrees, and pushes still show.` |
| PR status unavailable, one reason at a time | `installGitHubCLIActionLabel` | `gh-not-installed` — the one action for that reason. | `Open cli.github.com` |
| PR status unavailable, one reason at a time | `installGitHubCLIURL` | `gh-not-installed` — where the install action goes. | `https://cli.github.com` |
| PR status unavailable, one reason at a time | `ghNotAuthenticatedTitle` | `gh-not-authenticated` — heading, per host (PLAN.md §3 preflights each host). | `Not signed in to github.com` |
| PR status unavailable, one reason at a time | `ghNotAuthenticatedMessage` | `gh-not-authenticated` — offers to open Terminal with the sign-in command ready. | `The GitHub CLI is installed but not signed in to github.com. BranchBar can open Terminal with the sign-in command ready for you to run.` |
| PR status unavailable, one reason at a time | `openTerminalActionLabel` | `gh-not-authenticated` — the one action for that reason. | `Open Terminal` |
| PR status unavailable, one reason at a time | `ghAuthLoginCommand` | `gh-not-authenticated` — the command the Terminal action puts in front of the user. | `gh auth login --hostname github.com` |
| PR status unavailable, one reason at a time | `noRemoteTitle` | `no-remote` — heading when the repo has no origin at all. | `No origin for this repo` |
| PR status unavailable, one reason at a time | `noRemoteMessage` | `no-remote` — says why there is no PR to show and what still works. | `This repo has no origin, so there is no PR to look up. Branches, worktrees, and commits still show.` |
| PR status unavailable, one reason at a time | `notGitHubRemoteTitle` | `no-github-remote` — heading when origin points somewhere other than GitHub. | `Origin is not on GitHub` |
| PR status unavailable, one reason at a time | `notGitHubRemoteMessage` | `no-github-remote` — names the limit without guessing at the host. | `This repo's origin is not a GitHub address, so BranchBar cannot look up PRs for it. Branches, worktrees, and pushes still show.` |
| PR status unavailable, one reason at a time | `rateLimitedTitle` | `rate-limited` — heading when GitHub throttles the account. | `GitHub is rate limiting BranchBar` |
| PR status unavailable, one reason at a time | `rateLimitedMessage` | `rate-limited` — PLAN.md §3: the copy says waiting fixes it. | `GitHub is limiting how many requests it will answer right now. Waiting a few minutes and refreshing again fixes this.` |
| PR status unavailable, one reason at a time | `commandFailedTitle` | `pr-list-timeout`, `gh-command-failed` — heading for a PR lookup that failed or ran out of time. | `PR status did not load` |
| PR status unavailable, one reason at a time | `commandFailedMessage` | `gh-command-failed` — a `gh` failure the reason list does not name: a 404, a renamed repo, malformed JSON, a permission error on the CLI itself. It used to share `timedOutMessage`, which asserted both a cause the app cannot know and a cure that does not exist — a deleted repository does not come back on refresh (codex round 2, MAJOR 7). The detail is the first stderr line, flattened and capped by `diagnosticLine`. | `The GitHub CLI reported an error for this repo: HTTP 404: Not Found` |
| PR status unavailable, one reason at a time | `timedOutMessage` | `pr-list-timeout` — the one failure whose copy may say the CLI ran out of time, because the runner's own timeout is what produced it (codex round 2, MAJOR 7). | `The GitHub CLI did not answer for this repo in time. Refreshing usually fixes it.` |
| PR status unavailable, one reason at a time | `forbiddenTitle` | `gh-forbidden` — heading for a 403 that is neither rate limiting nor a bad token. | `GitHub refused this request` |
| PR status unavailable, one reason at a time | `forbiddenMessage` | `gh-forbidden` — SAML enforcement, an IP allow-list, an organization policy, a grant the account does not have. Every one of them is HTTP 403 and none of them is answered by `gh auth login`, which is where the old blanket mapping sent a managed NYT account (codex round 2, MAJOR 7). | `GitHub refused this request for github.com/newsroom/demo (policy, SSO, or scopes). Signing in again will not fix it.` |
| PR status unavailable, one reason at a time | `refreshActionLabel` | `rate-limited`, `no-remote`, `no-github-remote`, `pr-list-timeout`, `repo-failed`, `deadline-exceeded` — the fallback action when nothing more specific helps. | `Refresh` |
| PR status unavailable, one reason at a time | `unavailable` | `gh-not-installed`, `gh-not-authenticated`, `no-remote`, `no-github-remote`, `rate-limited`, `pr-list-timeout`, `gh-forbidden`, `gh-command-failed` — one `UserFacingFailure` per reason, each with exactly one action (`unavailableReasonCopyNamesOneActionPerReason`). `detail` is the `gh` output, and exactly one reason repeats it: `commandFailed`, whose copy has nothing else to say (codex round 2, MAJOR 7). Every other reason still logs it and renders none of it. | see the eight title/message pairs above |
| PR pills | `prNone` | `single-branch-no-pr-never-pushed` — the head was queried and GitHub had no PR. | `No PR` |
| PR pills | `prDraft` | `pr-draft` — PR exists and is a draft. | `Draft` |
| PR pills | `prOpen` | `pr-open` — PR is open with no review decision yet. | `Open` |
| PR pills | `prChangesRequested` | `pr-changes-requested` — a reviewer asked for changes. | `Changes requested` |
| PR pills | `prApproved` | `pr-approved` — the PR is approved and not yet merged. | `Approved` |
| PR pills | `prMerged` | `merged-group` — the PR was merged. | `Merged` |
| PR pills | `prClosed` | `closed-unmerged-group` — the PR was closed without merging. | `Closed` |
| PR pills | `prUnavailable` | `gh-not-installed`, `gh-not-authenticated`, `rate-limited`, `no-remote`, `no-github-remote`, `pr-list-timeout` — the pill when the reason lives in the repo notice. | `PR status unavailable` |
| PR pills | `prNotLoaded` | `pr-not-loaded` — collapsed repo; PLAN.md §3 locks this wording. | `PR status loads when expanded` |
| PR pills | `prNotChecked` | `pr-not-checked` — the per-head query never ran (cap of 20, or the 45 s deadline). PLAN.md §3 locks this wording; it is never rendered as "No PR". | `PR status not checked yet` |
| PR pills | `prPill` | every row state — exhaustive over all ten `PRStatus` cases, no `default`. | one of the ten pill strings above |
| Group headings | `activeGroupHeading` | `single-branch-no-pr-never-pushed` — first group in every repo section. | `Branches and worktrees` |
| Group headings | `openElsewhereGroupHeading` | `open-prs-not-on-this-mac` — second group; PLAN.md §3 locks the name. | `Open PRs not on this Mac` |
| Group headings | `openElsewhereGroupNote` | `open-prs-not-on-this-mac` — why a PR lands in that group. | `Yours and open on GitHub, with no branch of that name on this Mac.` |
| Group headings | `mergedGroupHeading` | `merged-group` — third group. Never a shared "clean up" bucket (PLAN.md §3). | `Merged` |
| Group headings | `closedUnmergedGroupHeading` | `closed-unmerged-group` — fourth group. | `Closed without merging` |
| Group headings | `mergedGroupCopy` | `merged-group` — names the base branch and makes no deletion claim (PLAN.md §3). The second sentence says exactly what the comparison proves and nothing more: `headRefOid` is GitHub's **current** head of the PR, not an immutable snapshot of what was merged, so "No later local commits found" was a claim the data could not support (codex MAJOR 8). "PR head" is the one piece of GitHub's own vocabulary the copy borrows, and it is the second locked exception to the banned-word sweep. | `PR merged into main. Local tip matches GitHub's current PR head.` |
| Group headings | `closedUnmergedDetail` | `closed-unmerged-group` — PLAN.md §3 locks this wording. The app deletes nothing. | `PR closed without merging. This branch may hold work that was never merged.` |
| Push observation | `pushed` | `origin-moved-since`, `pr-open`, `pr-draft` — a push this clone actually recorded. PLAN.md §3 locks "Pushed from this Mac" and forbids "You pushed": the record says what this Mac observed and nothing about who did it or what other machines did. | `Pushed from this Mac 2 days ago` (plus ` (origin has moved since)`) |
| Push observation | `remoteMovedSince` | `origin-moved-since`, `non-origin-upstream` — appended when the recorded push is no longer the tip of the remote this branch was compared against. It named origin whatever the remote was, on a row whose count had been measured against a fork (codex round 2, MAJOR 5). | `(origin has moved since)` |
| Push observation | `pushUnknown` | `last-push-unknown` — no usable push line (file absent, empty, fetch-only, deletion-only, expired). PLAN.md §3 locks this as a separate fact, never a quieter push claim; `fallbackLabelDoesNotClaimGitHubObservedTheBranch` guards the wording. | `Last push unknown · newest commit dated 2 days ago` |
| Push observation | `noTrackedRemoteBranch` | `single-branch-no-pr-never-pushed` — the modal NYT case: a branch with no matching branch on origin. It replaced `Never pushed`, which "no upstream" never proved: a `git push origin <branch>` without `-u`, or an upstream removed after a push, leaves no tracking configuration behind a branch that really did go out (codex MAJOR 6). Never "0 commits ahead" (`noUpstreamRendersNeverPushedNotZeroCommits`). | `No tracked remote branch · push history not checked` |
| Push observation | `noUpstream` | `single-branch-no-pr-never-pushed` — secondary line for a branch that tracks nothing. | `No matching branch on last-known origin` |
| Push observation | `untrackedRemoteBranchExists` | `single-branch-no-pr-never-pushed` — the untracked branch whose `origin/<name>` this clone does hold. `noUpstream` was rendered there too, on the same row as a push line the reflog of that very ref produced: two sentences contradicting each other (codex round 2, MAJOR 5). This one says the part that is true. | `origin has a branch of the same name, which this branch does not track` |
| Push observation | `upstreamMissing` | `upstream-missing` — the tracked branch is gone from the last-known origin. PLAN.md §3 locks this verbatim and chose it over "deleted on GitHub" because BranchBar never fetches, so it cannot assert what GitHub holds now. This is the one string exempted from the banned-vocabulary sweep, and the exemption list is asserted to hold nothing else. | `Upstream missing from last-known origin` |
| Push observation | `upstreamMissing` | `upstream-missing` — the same sentence about the remote the branch actually tracked (codex round 2, MAJOR 5). `upstreamMissing` stays as the origin spelling PLAN.md §3 locked and the SwiftUI row tests prefixes against. | `Upstream missing from last-known origin` |
| Push observation | `ahead` | `ahead-of-last-known-origin` — PLAN.md §3 locks the wording and forbids showing behind. One is "1 ahead", never "1 aheads": the count has no noun after it. | `2 ahead of last-known origin` |
| Push observation | `inSync` | `in-sync` — tracked, with nothing local that origin has not seen **and** nothing on origin this clone has not seen. Distinguished from "no upstream" by `%(upstream:short)`, never by the track field (PLAN.md §3). | `In sync with last-known origin` |
| Push observation | `inSync` | `in-sync`, `non-origin-upstream` — the same claim about the remote the comparison actually used (codex round 2, MAJOR 5). `inSync` stays as the origin spelling the SwiftUI row still tests prefixes against. | `In sync with last-known origin` |
| Push observation | `noLocalCommitsAhead` | `behind-only` — nothing local is ahead, but last-known origin carries commits this clone does not. PLAN.md §3 still forbids showing the behind count, so the line states only the half BranchBar is willing to say; "In sync" there would be false (codex MAJOR 5). | `No local commits ahead of last-known origin` |
| Push observation | `pushedTooltip` | `origin-moved-since` — tooltip on an observed push. | `BranchBar saw this push leave this Mac. It cannot see pushes made from your other computers.` |
| Push observation | `pushUnknownTooltip` | `last-push-unknown` — tooltip on the fallback, saying plainly what the date is. | `BranchBar has no record of this branch going out from this Mac. The date shown is when the newest commit was made, not when it left.` |
| Push observation | `noTrackedRemoteBranchTooltip` | `single-branch-no-pr-never-pushed` — tooltip on a branch that tracks nothing. It says what BranchBar did rather than what the branch did, because the old wording ("nothing has gone out from this Mac") asserted something the absence of tracking cannot show (codex MAJOR 6). | `BranchBar only reads push history for a branch that tracks one on origin, so it has not checked this one.` |
| Push observation | `aheadTooltip` | `ahead-of-last-known-origin` — tooltip carrying when this clone last heard from origin. `remoteObservedAt` is the `FETCH_HEAD` modification date, which is a local observation; it used to be the remote tip's committer date, so fetching a two-year-old commit today read as "last seen 2 years ago" (codex MAJOR 7). | `Counted against last-known origin. This repo's last fetch changed FETCH_HEAD 3 hours ago. BranchBar never fetches, so origin may have moved.` |
| Push observation | `notFetchedYet` | `origin-not-fetched` — the anchor clause when there is no `FETCH_HEAD` to date. A clone that has only ever been pushed from has never fetched, and saying so is honest where a silent omission read as "we know when, we just did not say". It is a fact about the repo and not about one remote: `FETCH_HEAD` is repo-wide (codex round 2, MAJOR 5). | `This repo has not fetched yet.` |
| Worktree markers | `worktreeMarker` | `worktree-checkout` — leading marker for a branch checked out in its own folder. | `Worktree in demo-agents-2` |
| Worktree markers | `checkedOutMarker` | `single-branch-no-pr-never-pushed` — the branch the main repo folder is showing. | `Checked out` |
| Worktree markers | `detachedWorktree` | `detached-worktree` — PLAN.md §3 locks this in place of "detached HEAD". | `Worktree at commit abc1234 (no branch)` |
| Row actions | `openInCursorActionLabel` | `single-branch-no-pr-never-pushed` — primary row action (PLAN.md §3). | `Open in Cursor` |
| Row actions | `openInVSCodeActionLabel` | `cursor-not-installed` — first fallback when Cursor is absent. | `Open in VS Code` |
| Row actions | `openInTerminalActionLabel` | `cursor-not-installed` — last fallback when neither editor is installed. | `Open in Terminal` |
| Row actions | `cursorNotInstalledNotice` | `cursor-not-installed` — footer notice naming the fallback chain. | `Cursor is not installed on this Mac, so rows open in VS Code instead — or in Terminal if neither is installed.` |
| Row actions | `openInAvailableEditorLabel` | `cursor-not-installed` — the same fallback chain, resolved to the one label that names the app a row will actually open. `SnapshotPresenter` puts it on a branch row's primary action and the shell's repo-header menu offers the same thing for a whole folder, so both read it from here rather than each picking a winner of their own. | one of `Open in Cursor`, `Open in VS Code`, `Open in Terminal` |
| Row actions | `openPRActionLabel` | `pr-open`, `open-prs-not-on-this-mac` — opens the PR in the browser. | `Open PR` |
| Row actions | `revealInFinderActionLabel` | `single-branch-no-pr-never-pushed` — secondary row action. | `Show in Finder` |
| Row actions | `copyPathActionLabel` | `single-branch-no-pr-never-pushed` — secondary row action. | `Copy path` |
| Row actions | `expandSectionActionLabel` | `pr-not-loaded` — VoiceOver and pointer label on a collapsed repo's disclosure. | `Expand` |
| Row actions | `collapseSectionActionLabel` | `pr-not-loaded` — the same control once the repo is open. | `Collapse` |
| Hiding a repo | `hideRepoActionLabel` | `hidden-repo` — drops one repo out of the list. The app never deletes anything, so the wording is about this list and not about the repo on disk. | `Hide this repo` |
| Hiding a repo | `unhideRepoActionLabel` | `hidden-repo` — the way back, offered on a repo that is only visible because "Show hidden" is on. | `Stop hiding this repo` |
| Hiding a repo | `showHiddenToggleLabel` | `hidden-repo` — footer toggle. The count is what tells a user a hidden repo exists at all: without it the only evidence of hiding is a repo that is not there. | `Show hidden (1)` |
| Hiding a repo | `hiddenRepoMarker` | `hidden-repo` — beside a repo that is showing only because the toggle is on. | `Hidden` |
| Rows without a local branch | `prRowTitle` | `open-prs-not-on-this-mac` — title of a PR row in that group. | `#128 · hotfix-from-laptop` |
| Accessibility | `branchRowAccessibilityLabel` | `single-branch-no-pr-never-pushed` — one spoken sentence per branch row; PLAN.md §5a requires a VoiceOver label per row type and forbids emoji as status. | `Branch notes-cleanup. No PR. Never pushed.` |
| Accessibility | `prRowAccessibilityLabel` | `open-prs-not-on-this-mac` — spoken label for a PR row with no local branch. | `PR 128, hotfix-from-laptop. Open.` |
| Per-repo failures | `repoBranchesFailed` | `repo-failed` — the branch listing failed for this repo. | `Could not read this repo's branches. Refresh to try again.` |
| Per-repo failures | `repoWorktreesFailed` | `repo-failed` — the worktree listing failed for this repo. | `Could not read this repo's worktrees. Refresh to try again.` |
| Per-repo failures | `repoRemotesFailed` | `repo-failed` — origin could not be read, so PR lookups were skipped. | `Could not read this repo's last-known origin. Refresh to try again.` |
| Per-repo failures | `repoPushHistoryFailed` | `repo-failed` — the push record could not be read, so push dates may be missing. | `Could not read this repo's push history, so push dates may be missing.` |
| Per-repo failures | `repoPRStatusFailed` | `pr-list-timeout` — the PR lookup stage failed for this repo. | `Could not read PR status for this repo. Refresh to try again.` |
| Per-repo failures | `repoDeadlineExceeded` | `deadline-exceeded` — this repo was cut off by the overall deadline. | `This repo did not finish in time. What you see may be out of date.` |
| Per-repo failures | `repoErrorNotice` | `repo-failed`, `pr-list-timeout`, `deadline-exceeded` — exhaustive over all six `RepoError.Stage` cases, no `default`. | one of the six repo-failure strings above |
| Footer | `updated` | `first-run-scanning`, `single-branch-no-pr-never-pushed` — footer freshness label. | `Updated 12 s ago`, or `Not updated yet` |
| Footer | `versionLabel` | `first-run-scanning` — footer build label. | `Version 0.9.0` |
| Footer | `refreshPRsNowActionLabel` | `single-branch-no-pr-never-pushed` — bypasses the 10-minute PR cache (PLAN.md §3). | `Refresh PRs now` |
| Footer | `gitTooOldNotice` | `git-too-old` — git below 2.39 raises a tool notice (PLAN.md §5). | `BranchBar works best with git 2.39 or newer. This Mac has 2.30.1, so some branch details may be missing.` |
| Footer | `staleRowsNotice` | `stale-rows-at-launch` — rows restored from the cache while the first refresh runs. | `Showing the list from the last time BranchBar ran. Updating now…` |
| Footer | `staleRowsIdleNotice` | `stale-rows-idle` — rows that were never refreshed, with no refresh running to finish them: a cancelled refresh, or one the deadline cut short. The launch-time wording promises an update that is not coming, and the footer beside it says "Updated just now". | `Some repos did not finish updating. Refresh to try again.` |
| Footer | `deadlineExceededNotice` | `deadline-exceeded` — the whole refresh stopped at 45 seconds (PLAN.md §3). | `BranchBar stopped after 45 seconds. Repos that did not finish are marked out of date.` |
| Footer | `launchAtLoginToggleLabel` | `single-branch-no-pr-never-pushed` — opt-in toggle (PLAN.md §3, packet 4.2). | `Open BranchBar at login` |
| Footer | `quitActionLabel` | `single-branch-no-pr-never-pushed` — last item in the menu. | `Quit BranchBar` |
| Launch at login outcomes | `launchAtLoginNeedsApproval` | `launch-at-login-needs-approval` — `SMAppService` returned `.requiresApproval`: BranchBar registered, and macOS is waiting for the user to allow it in the one place that can allow it. | `macOS is waiting for approval. Open System Settings → General → Login Items and turn BranchBar on under “Open at Login”.` |
| Launch at login outcomes | `launchAtLoginTranslocated` | `launch-at-login-needs-approval` — the 0.2 spike's translocation finding, said to the user: a quarantined bundle runs from a throwaway copy under `/private/var/folders/…/AppTranslocation/`, and registering that path would register a folder that disappears. | `Move BranchBar to your Applications folder and open it from there, then this can be turned on. Right now it is running from a temporary copy macOS made.` |
| Launch at login outcomes | `launchAtLoginUnbundled` | `launch-at-login-needs-approval` — no bundle identifier: `swift run`, or a bundle whose Info.plist did not come along. | `This only works from the BranchBar app in your Applications folder.` |
| Launch at login outcomes | `launchAtLoginNotInApplications` | `launch-at-login-needs-approval` — the LaunchAgent fallback writes an absolute path, so the app has to be at one of the two paths it will write. The second one is there because a standard non-admin account on a managed Mac normally cannot write `/Applications`, which made the login item unreachable for exactly the testers it ships to. | `Move BranchBar into your Applications folder first — either /Applications or the Applications folder inside your home folder.` |
| Launch at login outcomes | `launchAtLoginFailed` | `launch-at-login-needs-approval` — both mechanisms refused. The diagnostic goes to the log, never into this sentence. | `macOS would not add BranchBar to your login items. The log has the details.` |
| The gh sign-in setup action | `ghSignInScriptBanner` | `gh-not-authenticated` — header of the `.command` file the sign-in action opens in Terminal, so the window a user lands in says what it is before they read the command. | `BranchBar: sign in to the GitHub CLI` |
| Grant folder access | `filesAndFoldersSettingsURL` | `not-scanned-folders` — where "Allow access…" goes: macOS's own pane, named the way the user will see it. The prompt itself cannot be re-raised, so this is the pane. | `x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders` |
| Relative time | `relative` | every state showing an age — the only relative-time formatter in the app. Pure arithmetic on the two dates: no `Date()`, no `Calendar`, no locale, so tests own the clock and the recorded state fixtures stay byte-stable. A date in the future reads "just now" rather than a negative age. | `just now`, `12 s ago`, `1 minute ago`, `3 hours ago`, `2 days ago`, `1 week ago`, `2 months ago`, `2 years ago` |
<!-- END doc-strings -->

---

## 3. Row hierarchy

### Tiers within one branch row

| Tier | Element | Source |
|---|---|---|
| Leading | Worktree marker glyph plus `worktreeMarker` / `detachedWorktree` / `checkedOutMarker` | `BranchRowVM.worktreeMarker` |
| Primary | Branch name | `BranchRowVM.title` |
| Secondary | PR pill: text plus the status colour from section 4 | `BranchRowVM.prPill` |
| Tertiary | Push line, then the ahead count | `BranchRowVM.pushLabel`, `BranchRowVM.aheadLabel` |
| Hover / VoiceOver | Push tooltip, ahead tooltip, row accessibility label | `pushTooltip`, `accessibilityLabel` |

A PR row in "Open PRs not on this Mac" has two tiers only: primary `#128 · hotfix-from-laptop`,
secondary PR pill. It carries no branch actions, because there is no branch on this Mac to act on.

### Groups within one repo section, in this order, always

1. **Branches and worktrees** — `Branch.group == .active`
2. **Open PRs not on this Mac** — `Repo.openPRsNotOnThisMac`
3. **Merged** — `Branch.group == .merged`
4. **Closed without merging** — `Branch.group == .closedUnmerged`

An empty group is not rendered — no heading, no placeholder row. Grouping is decided once by
`RepoAssembler` (packet 3.1); `SnapshotPresenter` renders `Branch.group` and never recomputes it.

### Ordering rules

- Repo sections: most recently active first, by `Repo.lastActivity` (newest committer date across
  the repo's branches), ties broken by `Repo.name` ascending, then `RepoID.commonDir` ascending so
  the order is total.
- Within a group: newest `Branch.committerDate` first, ties broken by branch name ascending.
- "Open PRs not on this Mac": newest `PRInfo.updatedAt` first, ties broken by PR number descending.

### Never-reorder rule

Order is computed once per refresh, from the repo list, before any repo finishes. Progressive
emits fill rows in; they never move a row that is already on screen. A repo that finishes late
keeps the slot it was given, marked out of date rather than resorted. The invariant is
`rowOrderIsStableAcrossProgressiveEmits`.

### Collapse defaults

- Exactly one repo found: it is expanded.
- More than one: only the most recently active repo is expanded; the rest start collapsed and show
  "PR status loads when expanded".
- The user's choice per repo is persisted in `CacheFile.collapsedRepoIDs` and outranks the default
  on every later launch.
- Collapsed repos are why `gh` never runs for them (PLAN.md §3, lazy PR fetching), so collapse is a
  cost control as well as a layout choice.

### Keyboard and VoiceOver

Arrow keys traverse rows and section headers; Return runs the row's primary action; Escape
dismisses the popover; Space toggles the focused section. Every row type has an accessibility label
built by `branchRowAccessibilityLabel` or `prRowAccessibilityLabel`. No emoji is ever used to carry
status: colour plus pill shape plus the pill text carry it, and the text alone is sufficient.

---

## 4. Token table

### Layout

| Token | Value | Note |
|---|---|---|
| Popover width | 340 pt, fixed | PLAN.md §5a item 4 |
| Popover max height | 70 % of the active screen's `visibleFrame.height` | content scrolls inside; the popover itself never scrolls the screen |
| Scroll region | The repo list only | Footer is pinned below it, notices pinned above it |
| Branch row height | 44 pt (two lines) | 36 pt when there is no push line to show |
| PR row height | 32 pt (one line) | "Open PRs not on this Mac" |
| Group heading height | 24 pt | |
| Repo section header height | 28 pt | |
| Footer height | 32 pt | |
| Horizontal padding | 12 pt | rows, headings, notices |
| Row vertical spacing | 6 pt | |
| Group vertical spacing | 8 pt above a group heading | |
| Section vertical spacing | 12 pt between repo sections | |
| Leading glyph column | 16 pt | keeps branch names aligned whether or not a row has a marker |

### Type scale — system text styles only, so Dynamic Type and Accessibility sizes work

| Element | Text style | Weight | Colour role |
|---|---|---|---|
| Repo section title | `.headline` | semibold | `labelColor` |
| Branch name | `.body` | regular; semibold when checked out in the main repo folder | `labelColor` |
| PR pill text | `.caption` | medium | status colour (section below) |
| Worktree marker | `.caption` | regular | `secondaryLabelColor` |
| Push line | `.caption` | regular | `secondaryLabelColor` |
| Ahead count | `.caption2` | regular | `secondaryLabelColor` |
| Group heading | `.subheadline` | semibold | `secondaryLabelColor` |
| Notice (PR, not-scanned, tool) | `.caption` | regular | `secondaryLabelColor` |
| Empty-state title | `.headline` | semibold | `labelColor` |
| Empty-state message | `.callout` | regular | `secondaryLabelColor` |
| Footer | `.caption` | regular | `tertiaryLabelColor` |

### PR pill: shape and the ten `PRStatus` colours

Shape: a capsule, 16 pt tall, 6 pt horizontal padding, corner radius 8 pt (height ÷ 2). Filled
variants use the status colour at 12 % opacity behind text in the full-strength colour. Outline
variants use a 1 pt border in the status colour with no fill; the dashed variant uses a
`[2, 2]` dash. Shape is what separates "BranchBar knows the PR state" from "BranchBar does not",
so the three unknown states stay legible without a colour of their own.

| `PRStatus` | Pill treatment | Light | Dark | System colour |
|---|---|---|---|---|
| `none` | text only, no pill | `#6C6C70` | `#98989D` | `secondaryLabelColor` |
| `draft` | filled | `#8E8E93` | `#98989D` | `systemGrayColor` |
| `open` | filled | `#007AFF` | `#0A84FF` | `systemBlueColor` |
| `changesRequested` | filled | `#FF9500` | `#FF9F0A` | `systemOrangeColor` |
| `approved` | filled | `#34C759` | `#30D158` | `systemGreenColor` |
| `merged` | filled | `#AF52DE` | `#BF5AF2` | `systemPurpleColor` |
| `closed` | filled | `#FF3B30` | `#FF453A` | `systemRedColor` |
| `unavailable` | outline plus `exclamationmark.triangle` glyph | `#6C6C70` | `#98989D` | `secondaryLabelColor` |
| `notLoaded` | outline | `#6C6C70` | `#98989D` | `secondaryLabelColor` |
| `notChecked` | dashed outline | `#6C6C70` | `#98989D` | `secondaryLabelColor` |

Hex values are the macOS system colours as of macOS 13; the implementation names the `NSColor`, not
the hex, so a future macOS keeps its own palette. The hexes are here for review and for the Gate 4
screenshot comparison.

### Icons — SF Symbols, all available on macOS 13

| Purpose | SF Symbol |
|---|---|
| Menu bar item (template, monochrome, never conveys state) | `arrow.triangle.branch` |
| Branch row | `arrow.triangle.branch` |
| Worktree marker glyph | `folder` |
| Worktree with no branch | `folder.badge.questionmark` |
| Repo section disclosure, collapsed / expanded | `chevron.right` / `chevron.down` |
| Open PR (leaves the app) | `arrow.up.right.square` |
| Open in Cursor / VS Code / Terminal | `arrow.up.forward.app` |
| Show in Finder | `folder` |
| Copy path | `doc.on.doc` |
| Refresh, Refresh PRs now | `arrow.clockwise` |
| Add folder… | `folder.badge.plus` |
| Allow access… | `lock.open` |
| Rescan | `magnifyingglass` |
| Remove an added folder | `minus.circle` |
| Tool notice, PR unavailable | `exclamationmark.triangle` |
| Not-scanned folders | `eye.slash` |
| Rate limited | `clock` |
| Push observed from this Mac | `arrow.up.circle` |
| Last push unknown | `questionmark.circle` |
| Ahead of last-known origin | `arrow.up` |

Every glyph is decorative: it repeats what the adjacent text already says and carries no meaning of
its own, so VoiceOver skips it and a screenshot in greyscale loses nothing.
