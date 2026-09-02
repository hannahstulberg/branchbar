import Foundation

/// Every string a user reads, in one place. PLAN.md §3: "Strings are code."
///
/// `SnapshotPresenter` (packet 2.2) assembles view-models out of these and the SwiftUI layer holds
/// no copy of its own, so a wording rule — "Pushed from this Mac", never "You pushed" — is a unit
/// test over a value instead of a screenshot review.
///
/// A handful of members are fixed chrome the frozen view models have no field for — group
/// headings, the disclosure control, secondary row actions, the footer menu, Hide and Show hidden,
/// and the launch-at-login outcomes — and the views read those from here directly. They are not an
/// escape hatch: `SnapshotPresenterTests.viewOwnedChrome` pins the exact set, so a member that
/// stops being rendered cannot be made green by widening the list.
///
/// Vocabulary is the NYT workshop's: repo, branch, worktree, PR, push, commit, origin, folder.
/// Words the session never teaches (detached, HEAD, upstream, ref, SHA, reflog, stderr, exit code)
/// are banned by `noEngineeringVocabularyInUserStrings`, with one locked exception noted at
/// `upstreamMissing`.
///
/// Every member carries two machine-readable doc lines that `scripts/doc-strings.sh` reads to
/// regenerate the string table in `docs/UI-CONTRACT.md`:
///
///     /// State: <state id> — why the user is here.
///     /// Literal: `<what they read>`
///
/// Relative time goes through `relative(_:now:)` only, so tests own the clock.
public enum Strings {

    // MARK: - App chrome

    /// State: `first-run-scanning` — the menu bar item itself, in every state.
    /// Literal: `BranchBar: branches, worktrees, and PR status`
    public static let menuBarAccessibilityLabel = "BranchBar: branches, worktrees, and PR status"

    // MARK: - First run and refresh progress

    /// State: `first-run-scanning` — heading while the first home-folder scan runs.
    /// Literal: `Looking for repos`
    public static let firstRunTitle = "Looking for repos"

    /// State: `first-run-scanning` — says the scan happens once and is remembered.
    /// Literal: `BranchBar is looking through your home folder for repos. It does this once, then remembers what it found.`
    public static let firstRunMessage =
        "BranchBar is looking through your home folder for repos. It does this once, then remembers what it found."

    /// State: `refresh-running` — footer while a refresh is in flight.
    /// Literal: `Updating 3 of 12 repos…`
    public static func refreshRunning(completed: Int, total: Int) -> String {
        "Updating \(completed) of \(count(total, "repo"))…"
    }

    // MARK: - Zero repos

    /// State: `zero-repos` — heading when the scan finished and found nothing.
    /// Literal: `No repos found`
    public static let emptyStateTitle = "No repos found"

    /// State: `zero-repos` — names the two reasons a repo is missing and points at Add folder….
    /// Literal: `BranchBar looked under your home folder and found no repos. Repos kept in Google Drive, Dropbox, or iCloud Drive, or more than six folders deep, are not part of that first look. Add the folder that holds yours and BranchBar will look all the way down it.`
    public static let emptyStateMessage =
        "BranchBar looked under your home folder and found no repos. Repos kept in Google Drive, "
        + "Dropbox, or iCloud Drive, or more than six folders deep, are not part of that first look. "
        + "Add the folder that holds yours and BranchBar will look all the way down it."

    /// State: `zero-repos`, `not-scanned-folders` — primary action of the empty state.
    /// Literal: `Add folder…`
    public static let addFolderActionLabel = "Add folder…"

    /// State: `zero-repos`, `not-scanned-folders` — run the home scan again.
    /// Literal: `Rescan`
    public static let rescanActionLabel = "Rescan"

    // MARK: - What the scan could not read, and what it skipped on purpose

    /// State: `not-scanned-folders` — folders macOS would not let BranchBar read.
    /// Literal: `Not scanned: Documents, Desktop`
    public static func notScanned(folders: [String]) -> String {
        "Not scanned: \(folders.joined(separator: ", "))"
    }

    /// State: `not-scanned-folders` — re-triggers the macOS access prompt for those folders.
    /// Literal: `Allow access…`
    public static let grantFolderAccessActionLabel = "Allow access…"

    /// State: `not-scanned-folders` — the categories the home scan skips by design (PLAN.md §3).
    /// Literal: `Also skipped on purpose: hidden folders, Library, anything more than six folders deep, and folders inside a repo BranchBar already found.`
    public static let skippedCategoriesSummary =
        "Also skipped on purpose: hidden folders, Library, anything more than six folders deep, "
        + "and folders inside a repo BranchBar already found."

    /// State: `not-scanned-folders` — footer heading above the Add folder… roots.
    /// Literal: `Folders you added`
    public static let scanRootsHeading = "Folders you added"

    /// State: `not-scanned-folders` — drops one added folder from the scan.
    /// Literal: `Remove`
    public static let removeScanRootActionLabel = "Remove"

    // MARK: - PR status unavailable, one reason at a time

    /// State: `gh-not-installed` — heading when the GitHub CLI is not on this Mac.
    /// Literal: `GitHub CLI not found`
    public static let ghNotInstalledTitle = "GitHub CLI not found"

    /// State: `gh-not-installed` — says what is missing and what still works without it.
    /// Literal: `BranchBar could not find the GitHub CLI on this Mac, so it cannot show PR status. Branches, worktrees, and pushes still show.`
    public static let ghNotInstalledMessage =
        "BranchBar could not find the GitHub CLI on this Mac, so it cannot show PR status. "
        + "Branches, worktrees, and pushes still show."

    /// State: `gh-not-installed` — the one action for that reason.
    /// Literal: `Open cli.github.com`
    public static let installGitHubCLIActionLabel = "Open cli.github.com"

    /// State: `gh-not-installed` — where the install action goes.
    /// Literal: `https://cli.github.com`
    public static let installGitHubCLIURL = "https://cli.github.com"

    /// State: `gh-not-authenticated` — heading, per host (PLAN.md §3 preflights each host).
    /// Literal: `Not signed in to github.com`
    public static func ghNotAuthenticatedTitle(host: String) -> String {
        "Not signed in to \(host)"
    }

    /// State: `gh-not-authenticated` — offers to open Terminal with the sign-in command ready.
    /// Literal: `The GitHub CLI is installed but not signed in to github.com. BranchBar can open Terminal with the sign-in command ready for you to run.`
    public static func ghNotAuthenticatedMessage(host: String) -> String {
        "The GitHub CLI is installed but not signed in to \(host). BranchBar can open Terminal "
        + "with the sign-in command ready for you to run."
    }

    /// State: `gh-not-authenticated` — the one action for that reason.
    /// Literal: `Open Terminal`
    public static let openTerminalActionLabel = "Open Terminal"

    /// State: `gh-not-authenticated` — the command the Terminal action puts in front of the user.
    /// Literal: `gh auth login --hostname github.com`
    public static func ghAuthLoginCommand(host: String) -> String {
        "gh auth login --hostname \(host)"
    }

    /// State: `no-remote` — heading when the repo has no origin at all.
    /// Literal: `No origin for this repo`
    public static let noRemoteTitle = "No origin for this repo"

    /// State: `no-remote` — says why there is no PR to show and what still works.
    /// Literal: `This repo has no origin, so there is no PR to look up. Branches, worktrees, and commits still show.`
    public static let noRemoteMessage =
        "This repo has no origin, so there is no PR to look up. Branches, worktrees, and commits still show."

    /// State: `no-github-remote` — heading when origin points somewhere other than GitHub.
    /// Literal: `Origin is not on GitHub`
    public static let notGitHubRemoteTitle = "Origin is not on GitHub"

    /// State: `no-github-remote` — names the limit without guessing at the host.
    /// Literal: `This repo's origin is not a GitHub address, so BranchBar cannot look up PRs for it. Branches, worktrees, and pushes still show.`
    public static let notGitHubRemoteMessage =
        "This repo's origin is not a GitHub address, so BranchBar cannot look up PRs for it. "
        + "Branches, worktrees, and pushes still show."

    /// State: `rate-limited` — heading when GitHub throttles the account.
    /// Literal: `GitHub is rate limiting BranchBar`
    public static let rateLimitedTitle = "GitHub is rate limiting BranchBar"

    /// State: `rate-limited` — PLAN.md §3: the copy says waiting fixes it.
    /// Literal: `GitHub is limiting how many requests it will answer right now. Waiting a few minutes and refreshing again fixes this.`
    public static let rateLimitedMessage =
        "GitHub is limiting how many requests it will answer right now. Waiting a few minutes and "
        + "refreshing again fixes this."

    /// State: `pr-list-timeout` — heading for a PR lookup that failed or ran out of time.
    /// Literal: `PR status did not load`
    public static let commandFailedTitle = "PR status did not load"

    /// State: `pr-list-timeout` — covers both a failure and the 25-second lookup timeout.
    /// Literal: `The GitHub CLI did not answer for this repo in time. Refreshing usually fixes it.`
    public static let commandFailedMessage =
        "The GitHub CLI did not answer for this repo in time. Refreshing usually fixes it."

    /// State: `rate-limited`, `no-remote`, `no-github-remote`, `pr-list-timeout`, `repo-failed`,
    /// `deadline-exceeded` — the fallback action when nothing more specific helps.
    /// Literal: `Refresh`
    public static let refreshActionLabel = "Refresh"

    /// State: `gh-not-installed`, `gh-not-authenticated`, `no-remote`, `no-github-remote`,
    /// `rate-limited`, `pr-list-timeout` — one `UserFacingFailure` per reason, each with exactly one
    /// action (`unavailableReasonCopyNamesOneActionPerReason`). `diagnostic` stays empty here: the
    /// caller fills it with the `gh` output, which is logged and never rendered.
    /// Literal: see the six title/message pairs above
    public static func unavailable(reason: PRUnavailableReason) -> UserFacingFailure {
        switch reason {
        case .ghNotInstalled:
            return UserFacingFailure(
                title: ghNotInstalledTitle,
                message: ghNotInstalledMessage,
                action: UserFacingFailure.Action(
                    label: installGitHubCLIActionLabel,
                    kind: .openURL,
                    payload: installGitHubCLIURL
                )
            )
        case .ghNotAuthenticated(let host):
            return UserFacingFailure(
                title: ghNotAuthenticatedTitle(host: host),
                message: ghNotAuthenticatedMessage(host: host),
                action: UserFacingFailure.Action(
                    label: openTerminalActionLabel,
                    kind: .openTerminalWithGhAuthLogin,
                    payload: ghAuthLoginCommand(host: host)
                )
            )
        case .noRemote:
            return UserFacingFailure(
                title: noRemoteTitle,
                message: noRemoteMessage,
                action: UserFacingFailure.Action(label: refreshActionLabel, kind: .retryRefresh)
            )
        case .notGitHubRemote:
            return UserFacingFailure(
                title: notGitHubRemoteTitle,
                message: notGitHubRemoteMessage,
                action: UserFacingFailure.Action(label: refreshActionLabel, kind: .retryRefresh)
            )
        case .rateLimited:
            return UserFacingFailure(
                title: rateLimitedTitle,
                message: rateLimitedMessage,
                action: UserFacingFailure.Action(label: refreshActionLabel, kind: .retryRefresh)
            )
        case .commandFailed:
            return UserFacingFailure(
                title: commandFailedTitle,
                message: commandFailedMessage,
                action: UserFacingFailure.Action(label: refreshActionLabel, kind: .retryRefresh)
            )
        }
    }

    // MARK: - PR pills

    /// State: `single-branch-no-pr-never-pushed` — the head was queried and GitHub had no PR.
    /// Literal: `No PR`
    public static let prNone = "No PR"

    /// State: `pr-draft` — PR exists and is a draft.
    /// Literal: `Draft`
    public static let prDraft = "Draft"

    /// State: `pr-open` — PR is open with no review decision yet.
    /// Literal: `Open`
    public static let prOpen = "Open"

    /// State: `pr-changes-requested` — a reviewer asked for changes.
    /// Literal: `Changes requested`
    public static let prChangesRequested = "Changes requested"

    /// State: `pr-approved` — the PR is approved and not yet merged.
    /// Literal: `Approved`
    public static let prApproved = "Approved"

    /// State: `merged-group` — the PR was merged.
    /// Literal: `Merged`
    public static let prMerged = "Merged"

    /// State: `closed-unmerged-group` — the PR was closed without merging.
    /// Literal: `Closed`
    public static let prClosed = "Closed"

    /// State: `gh-not-installed`, `gh-not-authenticated`, `rate-limited`, `no-remote`,
    /// `no-github-remote`, `pr-list-timeout` — the pill when the reason lives in the repo notice.
    /// Literal: `PR status unavailable`
    public static let prUnavailable = "PR status unavailable"

    /// State: `pr-not-loaded` — collapsed repo; PLAN.md §3 locks this wording.
    /// Literal: `PR status loads when expanded`
    public static let prNotLoaded = "PR status loads when expanded"

    /// State: `pr-not-checked` — the per-head query never ran (cap of 20, or the 45 s deadline).
    /// PLAN.md §3 locks this wording; it is never rendered as "No PR".
    /// Literal: `PR status not checked yet`
    public static let prNotChecked = "PR status not checked yet"

    /// State: every row state — exhaustive over all ten `PRStatus` cases, no `default`.
    /// Literal: one of the ten pill strings above
    public static func prPill(for status: PRStatus) -> String {
        switch status {
        case .none: return prNone
        case .draft: return prDraft
        case .open: return prOpen
        case .changesRequested: return prChangesRequested
        case .approved: return prApproved
        case .merged: return prMerged
        case .closed: return prClosed
        case .unavailable: return prUnavailable
        case .notLoaded: return prNotLoaded
        case .notChecked: return prNotChecked
        }
    }

    // MARK: - Group headings

    /// State: `single-branch-no-pr-never-pushed` — first group in every repo section.
    /// Literal: `Branches and worktrees`
    public static let activeGroupHeading = "Branches and worktrees"

    /// State: `open-prs-not-on-this-mac` — second group; PLAN.md §3 locks the name.
    /// Literal: `Open PRs not on this Mac`
    public static let openElsewhereGroupHeading = "Open PRs not on this Mac"

    /// State: `open-prs-not-on-this-mac` — why a PR lands in that group.
    /// Literal: `Yours and open on GitHub, with no branch of that name on this Mac.`
    public static let openElsewhereGroupNote =
        "Yours and open on GitHub, with no branch of that name on this Mac."

    /// State: `merged-group` — third group. Never a shared "clean up" bucket (PLAN.md §3).
    /// Literal: `Merged`
    public static let mergedGroupHeading = "Merged"

    /// State: `closed-unmerged-group` — fourth group.
    /// Literal: `Closed without merging`
    public static let closedUnmergedGroupHeading = "Closed without merging"

    /// State: `merged-group` — names the base branch and makes no deletion claim (PLAN.md §3).
    /// The second sentence says exactly what the comparison proves and nothing more: `headRefOid`
    /// is GitHub's **current** head of the PR, not an immutable snapshot of what was merged, so
    /// "No later local commits found" was a claim the data could not support (codex MAJOR 8).
    /// "PR head" is the one piece of GitHub's own vocabulary the copy borrows, and it is the
    /// second locked exception to the banned-word sweep.
    /// Literal: `PR merged into main. Local tip matches GitHub's current PR head.`
    public static func mergedGroupCopy(base: String) -> String {
        "PR merged into \(base). Local tip matches GitHub's current PR head."
    }

    /// State: `closed-unmerged-group` — PLAN.md §3 locks this wording. The app deletes nothing.
    /// Literal: `PR closed without merging. This branch may hold work that was never merged.`
    public static let closedUnmergedDetail =
        "PR closed without merging. This branch may hold work that was never merged."

    // MARK: - Push observation

    /// State: `origin-moved-since`, `pr-open`, `pr-draft` — a push this clone actually recorded.
    /// PLAN.md §3 locks "Pushed from this Mac" and forbids "You pushed": the record says what this
    /// Mac observed and nothing about who did it or what other machines did.
    /// Literal: `Pushed from this Mac 2 days ago` (plus ` (origin has moved since)`)
    public static func pushed(reflogAt: Date, now: Date, originMovedSince moved: Bool = false) -> String {
        let base = "Pushed from this Mac \(relative(reflogAt, now: now))"
        return moved ? "\(base) \(originMovedSince)" : base
    }

    /// State: `origin-moved-since` — appended when the recorded push is no longer origin's tip.
    /// Literal: `(origin has moved since)`
    public static let originMovedSince = "(origin has moved since)"

    /// State: `last-push-unknown` — no usable push line (file absent, empty, fetch-only,
    /// deletion-only, expired). PLAN.md §3 locks this as a separate fact, never a quieter push
    /// claim; `fallbackLabelDoesNotClaimGitHubObservedTheBranch` guards the wording.
    /// Literal: `Last push unknown · newest commit dated 2 days ago`
    public static func pushUnknown(tipCommitDate: Date, now: Date) -> String {
        "Last push unknown · newest commit dated \(relative(tipCommitDate, now: now))"
    }

    /// State: `single-branch-no-pr-never-pushed` — the modal NYT case: a branch with no matching
    /// branch on origin. It replaced `Never pushed`, which "no upstream" never proved: a
    /// `git push origin <branch>` without `-u`, or an upstream removed after a push, leaves no
    /// tracking configuration behind a branch that really did go out (codex MAJOR 6). Never
    /// "0 commits ahead" (`noUpstreamRendersNeverPushedNotZeroCommits`).
    /// Literal: `No tracked remote branch · push history not checked`
    public static let noTrackedRemoteBranch = "No tracked remote branch · push history not checked"

    /// State: `single-branch-no-pr-never-pushed` — secondary line for a branch that tracks nothing.
    /// Literal: `No matching branch on last-known origin`
    public static let noUpstream = "No matching branch on last-known origin"

    /// State: `upstream-missing` — the tracked branch is gone from the last-known origin. PLAN.md
    /// §3 locks this verbatim and chose it over "deleted on GitHub" because BranchBar never
    /// fetches, so it cannot assert what GitHub holds now. This is the one string exempted from the
    /// banned-vocabulary sweep, and the exemption list is asserted to hold nothing else.
    /// Literal: `Upstream missing from last-known origin`
    public static let upstreamMissing = "Upstream missing from last-known origin"

    /// State: `ahead-of-last-known-origin` — PLAN.md §3 locks the wording and forbids showing
    /// behind. One is "1 ahead", never "1 aheads": the count has no noun after it.
    /// Literal: `2 ahead of last-known origin`
    public static func ahead(_ n: Int) -> String {
        "\(n) ahead of last-known origin"
    }

    /// State: `in-sync` — tracked, with nothing local that origin has not seen **and** nothing on
    /// origin this clone has not seen. Distinguished from "no upstream" by `%(upstream:short)`,
    /// never by the track field (PLAN.md §3).
    /// Literal: `In sync with last-known origin`
    public static let inSync = "In sync with last-known origin"

    /// State: `behind-only` — nothing local is ahead, but last-known origin carries commits this
    /// clone does not. PLAN.md §3 still forbids showing the behind count, so the line states only
    /// the half BranchBar is willing to say; "In sync" there would be false (codex MAJOR 5).
    /// Literal: `No local commits ahead of last-known origin`
    public static let noLocalCommitsAhead = "No local commits ahead of last-known origin"

    /// State: `origin-moved-since` — tooltip on an observed push.
    /// Literal: `BranchBar saw this push leave this Mac. It cannot see pushes made from your other computers.`
    public static let pushedTooltip =
        "BranchBar saw this push leave this Mac. It cannot see pushes made from your other computers."

    /// State: `last-push-unknown` — tooltip on the fallback, saying plainly what the date is.
    /// Literal: `BranchBar has no record of this branch going out from this Mac. The date shown is when the newest commit was made, not when it left.`
    public static let pushUnknownTooltip =
        "BranchBar has no record of this branch going out from this Mac. The date shown is when the "
        + "newest commit was made, not when it left."

    /// State: `single-branch-no-pr-never-pushed` — tooltip on a branch that tracks nothing. It
    /// says what BranchBar did rather than what the branch did, because the old wording ("nothing
    /// has gone out from this Mac") asserted something the absence of tracking cannot show
    /// (codex MAJOR 6).
    /// Literal: `BranchBar only reads push history for a branch that tracks one on origin, so it has not checked this one.`
    public static let noTrackedRemoteBranchTooltip =
        "BranchBar only reads push history for a branch that tracks one on origin, so it has not "
        + "checked this one."

    /// State: `ahead-of-last-known-origin` — tooltip carrying when this clone last heard from
    /// origin. `remoteObservedAt` is the `FETCH_HEAD` modification date, which is a local
    /// observation; it used to be the remote tip's committer date, so fetching a two-year-old
    /// commit today read as "last seen 2 years ago" (codex MAJOR 7).
    /// Literal: `Counted against last-known origin, last seen 3 hours ago. BranchBar never fetches, so origin may have moved.`
    public static func aheadTooltip(remoteObservedAt: Date?, now: Date) -> String {
        let anchor = remoteObservedAt.map { ", last seen \(relative($0, now: now))" }
            ?? ", \(originNotFetchedYet)"
        return "Counted against last-known origin\(anchor). BranchBar never fetches, so origin may have moved."
    }

    /// State: `origin-not-fetched` — the anchor clause when there is no `FETCH_HEAD` to date. A
    /// clone that has only ever been pushed from has never fetched, and saying so is honest where
    /// a silent omission read as "we know when, we just did not say".
    /// Literal: `origin not fetched by this clone yet`
    public static let originNotFetchedYet = "origin not fetched by this clone yet"

    // MARK: - Worktree markers

    /// State: `worktree-checkout` — leading marker for a branch checked out in its own folder.
    /// Literal: `Worktree in demo-agents-2`
    public static func worktreeMarker(folderName: String) -> String {
        "Worktree in \(folderName)"
    }

    /// State: `single-branch-no-pr-never-pushed` — the branch the main repo folder is showing.
    /// Literal: `Checked out`
    public static let checkedOutMarker = "Checked out"

    /// State: `detached-worktree` — PLAN.md §3 locks this in place of "detached HEAD".
    /// Literal: `Worktree at commit abc1234 (no branch)`
    public static func detachedWorktree(shortSHA: String) -> String {
        "Worktree at commit \(shortSHA) (no branch)"
    }

    // MARK: - Row actions

    /// State: `single-branch-no-pr-never-pushed` — primary row action (PLAN.md §3).
    /// Literal: `Open in Cursor`
    public static let openInCursorActionLabel = "Open in Cursor"

    /// State: `cursor-not-installed` — first fallback when Cursor is absent.
    /// Literal: `Open in VS Code`
    public static let openInVSCodeActionLabel = "Open in VS Code"

    /// State: `cursor-not-installed` — last fallback when neither editor is installed.
    /// Literal: `Open in Terminal`
    public static let openInTerminalActionLabel = "Open in Terminal"

    /// State: `cursor-not-installed` — footer notice naming the fallback chain.
    /// Literal: `Cursor is not installed on this Mac, so rows open in VS Code instead — or in Terminal if neither is installed.`
    public static let cursorNotInstalledNotice =
        "Cursor is not installed on this Mac, so rows open in VS Code instead — or in Terminal if "
        + "neither is installed."

    /// State: `cursor-not-installed` — the same fallback chain, resolved to the one label that
    /// names the app a row will actually open. `SnapshotPresenter` puts it on a branch row's
    /// primary action and the shell's repo-header menu offers the same thing for a whole folder,
    /// so both read it from here rather than each picking a winner of their own.
    /// Literal: one of `Open in Cursor`, `Open in VS Code`, `Open in Terminal`
    public static func openInAvailableEditorLabel(_ editors: EditorAvailability) -> String {
        if editors.cursor { return openInCursorActionLabel }
        if editors.vsCode { return openInVSCodeActionLabel }
        return openInTerminalActionLabel
    }

    /// State: `pr-open`, `open-prs-not-on-this-mac` — opens the PR in the browser.
    /// Literal: `Open PR`
    public static let openPRActionLabel = "Open PR"

    /// State: `single-branch-no-pr-never-pushed` — secondary row action.
    /// Literal: `Show in Finder`
    public static let revealInFinderActionLabel = "Show in Finder"

    /// State: `single-branch-no-pr-never-pushed` — secondary row action.
    /// Literal: `Copy path`
    public static let copyPathActionLabel = "Copy path"

    /// State: `pr-not-loaded` — VoiceOver and pointer label on a collapsed repo's disclosure.
    /// Literal: `Expand`
    public static let expandSectionActionLabel = "Expand"

    /// State: `pr-not-loaded` — the same control once the repo is open.
    /// Literal: `Collapse`
    public static let collapseSectionActionLabel = "Collapse"

    // MARK: - Hiding a repo

    /// State: `hidden-repo` — drops one repo out of the list. The app never deletes anything, so
    /// the wording is about this list and not about the repo on disk.
    /// Literal: `Hide this repo`
    public static let hideRepoActionLabel = "Hide this repo"

    /// State: `hidden-repo` — the way back, offered on a repo that is only visible because
    /// "Show hidden" is on.
    /// Literal: `Stop hiding this repo`
    public static let unhideRepoActionLabel = "Stop hiding this repo"

    /// State: `hidden-repo` — footer toggle. The count is what tells a user a hidden repo exists
    /// at all: without it the only evidence of hiding is a repo that is not there.
    /// Literal: `Show hidden (1)`
    public static func showHiddenToggleLabel(count: Int) -> String {
        "Show hidden (\(count))"
    }

    /// State: `hidden-repo` — beside a repo that is showing only because the toggle is on.
    /// Literal: `Hidden`
    public static let hiddenRepoMarker = "Hidden"

    // MARK: - Rows without a local branch

    /// State: `open-prs-not-on-this-mac` — title of a PR row in that group.
    /// Literal: `#128 · hotfix-from-laptop`
    public static func prRowTitle(number: Int, branchName: String) -> String {
        "#\(number) · \(branchName)"
    }

    // MARK: - Accessibility

    /// State: `single-branch-no-pr-never-pushed` — one spoken sentence per branch row; PLAN.md §5a
    /// requires a VoiceOver label per row type and forbids emoji as status.
    /// Literal: `Branch notes-cleanup. No PR. Never pushed.`
    public static func branchRowAccessibilityLabel(
        branchName: String,
        prPill: String,
        pushLabel: String
    ) -> String {
        "Branch \(branchName). \(prPill). \(pushLabel)."
    }

    /// State: `open-prs-not-on-this-mac` — spoken label for a PR row with no local branch.
    /// Literal: `PR 128, hotfix-from-laptop. Open.`
    public static func prRowAccessibilityLabel(number: Int, branchName: String, prPill: String) -> String {
        "PR \(number), \(branchName). \(prPill)."
    }

    // MARK: - Per-repo failures

    /// State: `repo-failed` — the branch listing failed for this repo.
    /// Literal: `Could not read this repo's branches. Refresh to try again.`
    public static let repoBranchesFailed = "Could not read this repo's branches. Refresh to try again."

    /// State: `repo-failed` — the worktree listing failed for this repo.
    /// Literal: `Could not read this repo's worktrees. Refresh to try again.`
    public static let repoWorktreesFailed = "Could not read this repo's worktrees. Refresh to try again."

    /// State: `repo-failed` — origin could not be read, so PR lookups were skipped.
    /// Literal: `Could not read this repo's last-known origin. Refresh to try again.`
    public static let repoRemotesFailed = "Could not read this repo's last-known origin. Refresh to try again."

    /// State: `repo-failed` — the push record could not be read, so push dates may be missing.
    /// Literal: `Could not read this repo's push history, so push dates may be missing.`
    public static let repoPushHistoryFailed =
        "Could not read this repo's push history, so push dates may be missing."

    /// State: `pr-list-timeout` — the PR lookup stage failed for this repo.
    /// Literal: `Could not read PR status for this repo. Refresh to try again.`
    public static let repoPRStatusFailed = "Could not read PR status for this repo. Refresh to try again."

    /// State: `deadline-exceeded` — this repo was cut off by the overall deadline.
    /// Literal: `This repo did not finish in time. What you see may be out of date.`
    public static let repoDeadlineExceeded =
        "This repo did not finish in time. What you see may be out of date."

    /// State: `repo-failed`, `pr-list-timeout`, `deadline-exceeded` — exhaustive over all six
    /// `RepoError.Stage` cases, no `default`.
    /// Literal: one of the six repo-failure strings above
    public static func repoErrorNotice(stage: RepoError.Stage) -> String {
        switch stage {
        case .branches: return repoBranchesFailed
        case .worktrees: return repoWorktreesFailed
        case .remotes: return repoRemotesFailed
        case .reflog: return repoPushHistoryFailed
        case .github: return repoPRStatusFailed
        case .deadlineExceeded: return repoDeadlineExceeded
        }
    }

    // MARK: - Footer

    /// State: `first-run-scanning`, `single-branch-no-pr-never-pushed` — footer freshness label.
    /// Literal: `Updated 12 s ago`, or `Not updated yet`
    public static func updated(at date: Date?, now: Date) -> String {
        guard let date else { return "Not updated yet" }
        return "Updated \(relative(date, now: now))"
    }

    /// State: `first-run-scanning` — footer build label.
    /// Literal: `Version 0.9.0`
    public static func versionLabel(_ version: String) -> String {
        "Version \(version)"
    }

    /// State: `single-branch-no-pr-never-pushed` — bypasses the 10-minute PR cache (PLAN.md §3).
    /// Literal: `Refresh PRs now`
    public static let refreshPRsNowActionLabel = "Refresh PRs now"

    /// State: `git-too-old` — git below 2.39 raises a tool notice (PLAN.md §5).
    /// Literal: `BranchBar works best with git 2.39 or newer. This Mac has 2.30.1, so some branch details may be missing.`
    public static func gitTooOldNotice(version: String) -> String {
        "BranchBar works best with git 2.39 or newer. This Mac has \(version), so some branch "
        + "details may be missing."
    }

    /// State: `stale-rows-at-launch` — rows restored from the cache while the first refresh runs.
    /// Literal: `Showing the list from the last time BranchBar ran. Updating now…`
    public static let staleRowsNotice = "Showing the list from the last time BranchBar ran. Updating now…"

    /// State: `deadline-exceeded` — the whole refresh stopped at 45 seconds (PLAN.md §3).
    /// Literal: `BranchBar stopped after 45 seconds. Repos that did not finish are marked out of date.`
    public static let deadlineExceededNotice =
        "BranchBar stopped after 45 seconds. Repos that did not finish are marked out of date."

    /// State: `single-branch-no-pr-never-pushed` — opt-in toggle (PLAN.md §3, packet 4.2).
    /// Literal: `Open BranchBar at login`
    public static let launchAtLoginToggleLabel = "Open BranchBar at login"

    /// State: `single-branch-no-pr-never-pushed` — last item in the menu.
    /// Literal: `Quit BranchBar`
    public static let quitActionLabel = "Quit BranchBar"

    // MARK: - Launch at login outcomes

    /// State: `launch-at-login-needs-approval` — `SMAppService` returned `.requiresApproval`:
    /// BranchBar registered, and macOS is waiting for the user to allow it in the one place that
    /// can allow it.
    /// Literal: `macOS is waiting for approval. Open System Settings → General → Login Items and turn BranchBar on under “Open at Login”.`
    public static let launchAtLoginNeedsApproval =
        "macOS is waiting for approval. Open System Settings → General → Login Items and turn "
        + "BranchBar on under \u{201C}Open at Login\u{201D}."

    /// State: `launch-at-login-needs-approval` — the 0.2 spike's translocation finding, said to
    /// the user: a quarantined bundle runs from a throwaway copy under
    /// `/private/var/folders/…/AppTranslocation/`, and registering that path would register a
    /// folder that disappears.
    /// Literal: `Move BranchBar to your Applications folder and open it from there, then this can be turned on. Right now it is running from a temporary copy macOS made.`
    public static let launchAtLoginTranslocated =
        "Move BranchBar to your Applications folder and open it from there, then this can be "
        + "turned on. Right now it is running from a temporary copy macOS made."

    /// State: `launch-at-login-needs-approval` — no bundle identifier: `swift run`, or a bundle
    /// whose Info.plist did not come along.
    /// Literal: `This only works from the BranchBar app in your Applications folder.`
    public static let launchAtLoginUnbundled =
        "This only works from the BranchBar app in your Applications folder."

    /// State: `launch-at-login-needs-approval` — the LaunchAgent fallback writes an absolute path,
    /// so the app has to be at that path.
    /// Literal: `Copy BranchBar into your Applications folder first — the login item points at /Applications/BranchBar.app.`
    public static let launchAtLoginNotInApplications =
        "Copy BranchBar into your Applications folder first — the login item points at "
        + "/Applications/BranchBar.app."

    /// State: `launch-at-login-needs-approval` — both mechanisms refused. The diagnostic goes to
    /// the log, never into this sentence.
    /// Literal: `macOS would not add BranchBar to your login items. The log has the details.`
    public static let launchAtLoginFailed =
        "macOS would not add BranchBar to your login items. The log has the details."

    // MARK: - The gh sign-in setup action

    /// State: `gh-not-authenticated` — header of the `.command` file the sign-in action opens in
    /// Terminal, so the window a user lands in says what it is before they read the command.
    /// Literal: `BranchBar: sign in to the GitHub CLI`
    public static let ghSignInScriptBanner = "BranchBar: sign in to the GitHub CLI"

    // MARK: - Grant folder access

    /// State: `not-scanned-folders` — where "Allow access…" goes: macOS's own pane, named the way
    /// the user will see it. The prompt itself cannot be re-raised, so this is the pane.
    /// Literal: `x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders`
    public static let filesAndFoldersSettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"

    // MARK: - Relative time

    /// State: every state showing an age — the only relative-time formatter in the app. Pure
    /// arithmetic on the two dates: no `Date()`, no `Calendar`, no locale, so tests own the clock
    /// and the recorded state fixtures stay byte-stable. A date in the future reads "just now"
    /// rather than a negative age.
    /// Literal: `just now`, `12 s ago`, `1 minute ago`, `3 hours ago`, `2 days ago`, `1 week ago`, `2 months ago`, `2 years ago`
    public static func relative(_ date: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= 1 else { return justNow }

        let seconds = Int(elapsed)
        if seconds < 60 { return "\(seconds) s ago" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(count(minutes, "minute")) ago" }

        let hours = minutes / 60
        if hours < 24 { return "\(count(hours, "hour")) ago" }

        let days = hours / 24
        if days < 7 { return "\(count(days, "day")) ago" }
        if days < 35 { return "\(count(days / 7, "week")) ago" }
        if days < 365 { return "\(count(days / 30, "month")) ago" }
        return "\(count(days / 365, "year")) ago"
    }

    /// Anything less than a second old. Not public: it is reachable only through `relative`.
    static let justNow = "just now"

    /// "1 day" / "2 days". Every plural in this file goes through here.
    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
