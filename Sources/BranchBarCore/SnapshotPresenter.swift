import Foundation

/// Which of the row-opening apps PLAN.md §3 names are on this Mac.
///
/// It is a property of the machine rather than of a `Snapshot`, so it is handed to the presenter
/// once at construction and `present`'s argument list stays exactly the six that packet 4.0 froze
/// into `Tests/BranchBarCoreTests/Fixtures/states/*.json`. Two flags are the whole type: the chain
/// ends at Show in Finder, which needs no flag because the Finder is always there (codex round 4,
/// BLOCKER 1 — Terminal used to be the last step, and Terminal runs a `.command` document).
public struct EditorAvailability: Hashable, Codable, Sendable {
    public var cursor: Bool
    public var vsCode: Bool

    /// Both editors installed — the case the recorded state fixtures assume.
    public static let all = EditorAvailability(cursor: true, vsCode: true)

    public init(cursor: Bool = true, vsCode: Bool = true) {
        self.cursor = cursor
        self.vsCode = vsCode
    }
}

/// The only place a user-facing string is produced. PLAN.md §3: "Strings are code" — every
/// literal lives in `Strings.swift` (packet 4.0) and this type assembles them, so a wording
/// invariant such as `observedPushLabelSaysFromThisMacNeverYouPushed` is a unit test over a
/// value rather than a screenshot review.
///
/// It renders `Branch.group` and never recomputes it; grouping belongs to `RepoAssembler`.
///
/// Pure and synchronous: it reads the `Snapshot` it is handed and the clock it is handed, and
/// touches no seam. `now` is a parameter for the same reason `Strings.relative` takes one — the
/// recorded fixtures stay byte-stable because the tests own the clock.
///
/// **Where several `Strings` members share one view-model field.** The view models frozen in
/// packet 1.1 have fewer slots than §5a has strings, so three joins are deliberate and documented
/// here rather than invented per call site:
///
/// - `NoticeVM.text` joins a `UserFacingFailure`'s title and message with a newline, and appends
///   one line per `RepoError` on the repo. `UserFacingFailure.diagnostic` is never joined in: §5
///   says it is logged, never rendered.
/// - `FooterVM.toolNotice` is the one footer notice slot, so every footer-level notice §5a names
///   (a failed refresh, git too old, `gh` missing, Cursor missing, stale rows, deadline exceeded)
///   is joined into it in that order, and the first of them that carries an action supplies the
///   notice's action. A failed refresh leads because it is the only one of the six that says
///   nothing on screen was refreshed at all.
/// - `BranchRowVM.aheadLabel` is the tertiary line §5a gives to the branch's relationship with
///   last-known origin (ahead / in sync / no upstream / upstream missing). On a merged or
///   closed-unmerged row the group copy is appended after " · ", the separator `pushUnknown`
///   already uses to join two facts in one line, because §5a gives the row no other slot for it.
public struct SnapshotPresenter: Sendable {

    /// Decides the primary row action: Cursor → VS Code → Show in Finder (PLAN.md §3).
    public let editors: EditorAvailability

    public init(editors: EditorAvailability = .all) {
        self.editors = editors
    }

    /// Turns a `Snapshot` into the `SnapshotVM` the SwiftUI layer renders.
    ///
    /// Sections come out in `snapshot.repos` order and are never re-sorted: §5a item 3 computes
    /// repo order once per refresh, before any repo finishes, so a repo that finishes late keeps
    /// its slot (`rowOrderIsStableAcrossProgressiveEmits`).
    public func present(
        _ snapshot: Snapshot,
        refreshState: RefreshState,
        collapsedRepoIDs: Set<RepoID>,
        scanResult: ScanResult?,
        appVersion: String,
        now: Date
    ) -> SnapshotVM {
        let sections = snapshot.repos.enumerated().map { index, repo in
            section(
                for: repo,
                isCollapsed: collapsedRepoIDs.contains(repo.id),
                scanResult: index == 0 ? scanResult : nil,
                now: now
            )
        }

        return SnapshotVM(
            sections: sections,
            footer: footer(
                snapshot: snapshot,
                refreshState: refreshState,
                scanResult: scanResult,
                appVersion: appVersion,
                now: now
            ),
            emptyState: snapshot.repos.isEmpty
                ? emptyState(refreshState: refreshState, scanResult: scanResult)
                : nil
        )
    }

    // MARK: - Sections

    /// `scanResult` is passed only for the first section: the not-scanned notice is one global
    /// fact and `RepoSectionVM.notScannedNotice` is the only slot §5a gives it, so it rides the
    /// first section rather than repeating under every repo.
    private func section(
        for repo: Repo,
        isCollapsed: Bool,
        scanResult: ScanResult?,
        now: Date
    ) -> RepoSectionVM {
        let branches = isCollapsed ? [] : repo.branches
        let worktreeRows = isCollapsed ? [] : noBranchWorktreeRows(of: repo)

        return RepoSectionVM(
            id: repo.id,
            title: repo.name,
            path: repo.path,
            isCollapsed: isCollapsed,
            active: rows(branches.filter { $0.group == .active }, in: repo, isCollapsed: isCollapsed, now: now)
                + worktreeRows,
            openElsewhere: isCollapsed ? [] : prRows(of: repo),
            merged: rows(branches.filter { $0.group == .merged }, in: repo, isCollapsed: isCollapsed, now: now),
            closedUnmerged: rows(
                branches.filter { $0.group == .closedUnmerged },
                in: repo,
                isCollapsed: isCollapsed,
                now: now
            ),
            prNotice: prNotice(for: repo, isCollapsed: isCollapsed),
            notScannedNotice: notScannedNotice(scanResult),
            host: repo.githubSlug?.host
        )
    }

    /// §5a item 3: within a group, newest `committerDate` first, ties broken by name ascending —
    /// which is plain name order for the common case of branches that share a commit date.
    private func rows(_ branches: [Branch], in repo: Repo, isCollapsed: Bool, now: Date) -> [BranchRowVM] {
        branches
            .sorted { left, right in
                left.committerDate == right.committerDate
                    ? left.name < right.name
                    : left.committerDate > right.committerDate
            }
            .map { row(for: $0, in: repo, isCollapsed: isCollapsed, now: now) }
    }

    // MARK: - Branch rows

    private func row(for branch: Branch, in repo: Repo, isCollapsed: Bool, now: Date) -> BranchRowVM {
        let push = pushCopy(for: branch, now: now)
        let pillText = Strings.prPill(for: branch.prStatus)

        return BranchRowVM(
            title: branch.name,
            worktreeMarker: worktreeMarker(for: branch, in: repo),
            // A collapsed repo shows the reason once, in the section notice, instead of repeating
            // "PR status loads when expanded" on every row.
            prPill: branch.prStatus == .notLoaded && isCollapsed
                ? nil
                : PRPillVM(text: pillText, status: branch.prStatus),
            // Every group carries it, not just `.active`: a merged or closed row's PR is the one
            // page that says what happened to the branch.
            prURL: branch.pr?.url,
            pushLabel: push.label,
            pushTooltip: push.tooltip,
            aheadLabel: aheadLabel(for: branch),
            // codex round 3, BLOCKER 1. A worktree path only reaches `Branch.worktreePath` after
            // `RepoAssembler` refused every prunable and bare record, and `RepoLoader` marks a
            // record prunable when its path is not an existing directory; the repo's own folder
            // carries the same verdict in `pathIsDirectory`. A row with neither offers nothing to
            // click: since codex round 4 no app in the chain would run what it is handed, but an
            // editor asked to open a FIFO or a device is still a hang or a nonsense window.
            primaryAction: branch.worktreePath.map(openAction(path:))
                ?? (repo.pathIsDirectory ? openAction(path: repo.path) : nil),
            accessibilityLabel: Strings.branchRowAccessibilityLabel(
                branchName: branch.name,
                prPill: pillText,
                pushLabel: push.label
            )
        )
    }

    /// PLAN.md §3: a worktree with no branch is listed under its repo and no branch claims it
    /// (`noBranchWorktreeAppearsUnderRepoAndNoBranchClaimsIt`). It gets a row of its own, titled by
    /// its folder, with the commit marker in place of a branch name and no PR to show.
    private func noBranchWorktreeRows(of repo: Repo) -> [BranchRowVM] {
        repo.worktrees
            .filter { !$0.isPrimary && !$0.isBare && $0.branch == nil }
            .map { worktree in
                let marker = Strings.detachedWorktree(shortSHA: String(worktree.headSHA.prefix(7)))
                return BranchRowVM(
                    title: folderName(worktree.path),
                    worktreeMarker: marker,
                    prPill: nil,
                    prURL: nil,
                    // There is no branch here, so there is no push fact to state and none is
                    // invented: an empty line is honest where "Never pushed" would not be.
                    pushLabel: "",
                    pushTooltip: "",
                    aheadLabel: nil,
                    // The row still lists the worktree — it is part of the repo and saying so is
                    // information — but a record git calls prunable, or one whose path this
                    // refresh could not open as a directory, has nothing to offer a click
                    // (codex round 3, BLOCKER 1).
                    primaryAction: worktree.isPrunable ? nil : openAction(path: worktree.path),
                    accessibilityLabel: marker
                )
            }
    }

    private func worktreeMarker(for branch: Branch, in repo: Repo) -> String? {
        if let path = branch.worktreePath, path != repo.path {
            return Strings.worktreeMarker(folderName: folderName(path))
        }
        if branch.isCheckedOutInPrimary { return Strings.checkedOutMarker }
        return nil
    }

    /// PLAN.md §3: the observed push and the tip-commit fallback are two different facts with two
    /// different wordings, and neither is ever "You pushed".
    private func pushCopy(for branch: Branch, now: Date) -> (label: String, tooltip: String) {
        let push = branch.push
        var label: String
        var tooltip: String

        let remote = Self.remoteName(for: branch)

        switch push.source {
        case .reflogObserved:
            label = Strings.pushed(
                reflogAt: push.observedPushAt ?? branch.committerDate,
                now: now,
                remote: remote,
                originMovedSince: push.originMovedSince
            )
            tooltip = Strings.pushedTooltip
        case .tipCommitDate:
            // The **remote** tip's commit date, which is what `.tipCommitDate` was selected on.
            // The local tip can sit many commits ahead of what origin holds, so reading
            // `branch.committerDate` here dated a fallback against a commit origin never saw
            // (codex MAJOR 7). The `??` is unreachable from `PushInfoDeriver`, which only chooses
            // this source when the date exists.
            label = Strings.pushUnknown(
                tipCommitDate: push.remoteTipCommitDate ?? branch.committerDate, now: now)
            tooltip = Strings.pushUnknownTooltip
        case .unreadable:
            // codex round 3, MAJOR 7: the reflog walk stopped at a line it could not vouch for.
            // Falling through to `.tipCommitDate` here would state a date over the corruption
            // that stopped the walk, which is the fabricated push history the finding is about.
            label = Strings.pushHistoryUnreadable
            tooltip = Strings.pushHistoryUnreadableTooltip
        case .none:
            if push.remoteRefsKnown {
                // Not "Never pushed": no tracking configuration is not evidence that nothing left
                // this Mac, and the reflog for `origin/<branch>` was either absent or never read
                // (codex MAJOR 6). A gone upstream that was never fetched lands here too, and the
                // tertiary line says so beside this one.
                label = Strings.noTrackedRemoteBranch
                tooltip = Strings.noTrackedRemoteBranchTooltip
            } else {
                // codex round 3, MAJOR 6: `for-each-ref -- refs/remotes/` failed, so there is no
                // tip for a reason that says nothing about the branch. "No tracked remote branch"
                // would be a claim this refresh never established.
                label = Strings.pushHistoryNotChecked
                tooltip = Strings.pushHistoryNotCheckedTooltip
            }
        }

        // §5a item 3 hangs both the push tooltip and the ahead tooltip off the tertiary tier, and
        // `BranchRowVM` has one tooltip field, so the anchor rides along when there is a count.
        if aheadCount(for: branch) > 0 {
            tooltip += " " + Strings.aheadTooltip(
                remote: remote, remoteObservedAt: push.remoteRefObservedAt, now: now)
        }
        return (label, tooltip)
    }

    /// The remote every wording on this row names: the one the counts and the moved-since
    /// comparison were actually measured against, not the word "origin" (codex round 2, MAJOR 5).
    /// It falls back to `origin` only where there is nothing to name, which is where the copy
    /// says there is no matching branch on origin.
    private static func remoteName(for branch: Branch) -> String {
        branch.push.remoteName ?? branch.upstream?.remote ?? "origin"
    }

    private func aheadCount(for branch: Branch) -> Int {
        branch.push.aheadOfLastKnownRemote ?? branch.upstream?.ahead ?? 0
    }

    /// Never rendered as a number — PLAN.md §3 forbids that — but "In sync" is a claim about both
    /// directions, so the count decides which of the two zero-ahead lines the row carries
    /// (codex MAJOR 5).
    private func behindCount(for branch: Branch) -> Int {
        branch.upstream?.behind ?? 0
    }

    /// The tertiary line: where this branch stands against last-known origin, plus the group copy
    /// on a merged or closed row. PLAN.md §3 forbids "0 ahead" for a branch that tracks nothing and
    /// forbids showing `behind` at all.
    private func aheadLabel(for branch: Branch) -> String? {
        let hasUpstream = branch.push.hasConfiguredUpstream || branch.upstream != nil
        let isGone = branch.push.upstreamGone || branch.upstream?.isGone == true
        let remote = Self.remoteName(for: branch)

        var parts: [String] = []
        // codex round 3, MAJOR 6. Two of the five lines below are claims **about the remote**:
        // "no matching branch on last-known origin" and "in sync with last-known origin". A failed
        // `for-each-ref -- refs/remotes/` proves neither, and pairing either with the push line
        // above produced a row that contradicted itself. The three that survive — gone, ahead,
        // and nothing-ahead — come from `%(upstream:track)`, which git computed itself and this
        // refresh did read.
        let remoteRefsKnown = branch.push.remoteRefsKnown
        if isGone {
            parts.append(Strings.upstreamMissing(remote: remote))
        } else if !hasUpstream {
            if remoteRefsKnown {
            // codex round 2, MAJOR 5: `origin/<name>` is what the reflog on this row was read
            // from, so "no matching branch on origin" contradicts the line above it. The branch
            // still tracks nothing, and that is what the copy says instead.
            parts.append(branch.push.remoteRefExists
                ? Strings.untrackedRemoteBranchExists(remote: remote)
                : Strings.noUpstream)
            }
        } else if aheadCount(for: branch) > 0 {
            parts.append(Strings.ahead(aheadCount(for: branch), remote: remote))
        } else if behindCount(for: branch) > 0 {
            // Nothing local is ahead, but the remote holds commits this clone does not, so "In
            // sync" would be false. The count itself still never reaches the row.
            parts.append(Strings.noLocalCommitsAhead(remote: remote))
        } else if remoteRefsKnown {
            parts.append(Strings.inSync(remote: remote))
        }

        switch branch.group {
        case .merged:
            // The copy names the base branch, so a merged branch with no PR row to name it gets
            // no claim made on its behalf.
            if let pr = branch.pr { parts.append(Strings.mergedGroupCopy(base: pr.baseRefName)) }
        case .closedUnmerged:
            parts.append(Strings.closedUnmergedDetail)
        case .active:
            break
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - PR rows with no local branch

    /// §5a item 3: newest `updatedAt` first, ties broken by PR number descending. State and link
    /// only — there is no branch on this Mac, so there is nothing to open in an editor.
    private func prRows(of repo: Repo) -> [PRRowVM] {
        repo.openPRsNotOnThisMac
            .sorted { left, right in
                left.updatedAt == right.updatedAt
                    ? left.number > right.number
                    : left.updatedAt > right.updatedAt
            }
            .map { pr in
                let status = PRStatusMapper.status(for: pr)
                let pill = Strings.prPill(for: status)
                return PRRowVM(
                    title: Strings.prRowTitle(number: pr.number, branchName: pr.headRefName),
                    prPill: PRPillVM(text: pill, status: status),
                    url: pr.url,
                    accessibilityLabel: Strings.prRowAccessibilityLabel(
                        number: pr.number,
                        branchName: pr.headRefName,
                        prPill: pill
                    )
                )
            }
    }

    // MARK: - Notices

    /// Why this repo's PR column reads the way it does, with the one action for the reason.
    private func prNotice(for repo: Repo, isCollapsed: Bool) -> NoticeVM? {
        var lines: [String] = []
        var action: UserFacingFailure.Action?

        if isCollapsed {
            lines.append(Strings.prNotLoaded)
        } else if case .unavailable(let reason, let detail) = repo.prAvailability {
            // The one reason whose copy repeats the diagnostic is `commandFailed`, which has
            // nothing else to say (codex round 2, MAJOR 7); `Strings.diagnosticLine` flattens and
            // caps it, because the text came off a remote.
            let failure = Strings.unavailable(reason: reason, detail: detail)
            lines.append(failure.title)
            lines.append(failure.message)
            action = failure.action
        } else if repo.branches.contains(where: { $0.prStatus == .notChecked }) {
            lines.append(Strings.prNotChecked)
        }

        // One line per stage that failed; PLAN.md §5 keeps `RepoError.message` (a git or gh
        // diagnostic) out of the copy the user reads.
        for error in repo.errors {
            lines.append(Strings.repoErrorNotice(stage: error.stage))
        }

        guard !lines.isEmpty else { return nil }
        if action == nil, !repo.errors.isEmpty {
            action = UserFacingFailure.Action(label: Strings.refreshActionLabel, kind: .retryRefresh)
        }
        return NoticeVM(text: lines.joined(separator: "\n"), action: action)
    }

    /// PLAN.md §3: a folder macOS would not let BranchBar read is reported, never silently skipped,
    /// and the categories the scan skips on purpose are named beside it so the list reads as a
    /// choice rather than a gap.
    private func notScannedNotice(_ scanResult: ScanResult?) -> NoticeVM? {
        guard let scanResult else { return nil }
        guard !scanResult.unreadableDirectories.isEmpty else {
            // codex round 3, MAJOR 2: the notice used to be gated on that list alone, so a walk the
            // deadline cut off inside an ordinary directory or an added root — which names no
            // folder, because nothing refused it — showed a short repo list with nothing at all
            // saying it was short. `truncatedByDeadline` is that claim, and it is enough on its
            // own.
            guard scanResult.truncatedByDeadline else { return nil }
            return NoticeVM(
                text: Strings.scanIncomplete,
                action: UserFacingFailure.Action(label: Strings.rescanActionLabel, kind: .rescan)
            )
        }
        var text = Strings.notScanned(folders: scanResult.unreadableDirectories.map(folderName))
            + "\n" + Strings.skippedCategoriesSummary
        if scanResult.truncatedByDeadline { text += "\n" + Strings.scanIncomplete }
        return NoticeVM(
            text: text,
            action: UserFacingFailure.Action(
                label: Strings.grantFolderAccessActionLabel,
                kind: .grantFolderAccess
            )
        )
    }

    // MARK: - Footer

    private func footer(
        snapshot: Snapshot,
        refreshState: RefreshState,
        scanResult: ScanResult?,
        appVersion: String,
        now: Date
    ) -> FooterVM {
        var updatedLabel = Strings.updated(at: snapshot.refreshedAt, now: now)
        var isRefreshing = false
        if case .running(let completed, let total) = refreshState {
            isRefreshing = true
            // A first run has nothing to count yet, so it says what it knows: nothing is updated.
            if total > 0 { updatedLabel = Strings.refreshRunning(completed: completed, total: total) }
        }

        return FooterVM(
            updatedLabel: updatedLabel,
            version: Strings.versionLabel(appVersion),
            toolNotice: toolNotice(
                snapshot: snapshot,
                isRefreshing: isRefreshing,
                failure: Self.failure(in: refreshState)
            ),
            scanRoots: scanResult?.policy.extraRoots ?? []
        )
    }

    /// Everything the footer has to say about this Mac and this refresh, in one slot.
    private func toolNotice(
        snapshot: Snapshot,
        isRefreshing: Bool,
        failure: UserFacingFailure?
    ) -> NoticeVM? {
        var lines: [String] = []
        var action: UserFacingFailure.Action?

        // A refresh that failed outright leads, because it is the one fact here that says the rows
        // below it were not refreshed at all. Rows exist in this case whenever a cache was restored
        // before the failure, which is exactly when the empty state is absent and this slot is the
        // only place the reason can be read (REVIEW CR-04).
        if let failure {
            lines.append("\(failure.title)\n\(failure.message)")
            action = failure.action
        }
        // The notice quotes the number, not the whole banner: `2.30.1`, never
        // `git version 2.30.1 (Apple Git-130)`.
        if let git = snapshot.tools.gitVersion.flatMap(GitVersion.parse), git.isBelowMinimumSupported {
            lines.append(Strings.gitTooOldNotice(version: git.description))
        }
        if snapshot.tools.ghPath == nil {
            let ghFailure = Strings.unavailable(reason: .ghNotInstalled)
            lines.append(ghFailure.message)
            // First writer wins, so a failed refresh keeps its own Refresh rather than handing the
            // user "Open cli.github.com" for a Mac that has no git.
            if action == nil { action = ghFailure.action }
        }
        if !editors.cursor {
            lines.append(Strings.cursorNotInstalledNotice)
        }
        // Rows that were not refreshed, whether or not a refresh is still running. Gating this on
        // `isRefreshing` meant a cancelled refresh left stale rows on screen under a footer that
        // said "Updated just now": the warning went away at the moment it became the only thing
        // saying the rows are old.
        if snapshot.repos.contains(where: { $0.isStale || $0.prLoadState == .stale }) {
            lines.append(isRefreshing ? Strings.staleRowsNotice : Strings.staleRowsIdleNotice)
            if !isRefreshing, action == nil {
                action = UserFacingFailure.Action(label: Strings.refreshActionLabel, kind: .retryRefresh)
            }
        }
        if snapshot.repos.contains(where: { $0.errors.contains { $0.stage == .deadlineExceeded } }) {
            lines.append(Strings.deadlineExceededNotice)
            if action == nil {
                action = UserFacingFailure.Action(label: Strings.refreshActionLabel, kind: .retryRefresh)
            }
        }

        guard !lines.isEmpty else { return nil }
        return NoticeVM(text: lines.joined(separator: "\n"), action: action)
    }

    // MARK: - Empty state

    /// §5a item 1 has two ways to show no repos, and `RefreshState` is what tells them apart: a
    /// scan still running is "Looking for repos", a finished one is "No repos found".
    ///
    /// Either way it carries the not-scanned notice when the scan hit a folder macOS would not let
    /// BranchBar read. With zero repos there is no first section for that notice to ride on, and
    /// zero repos is exactly what a denied Documents folder produces — so the one state that most
    /// needs "Allow access…" was the one state that never offered it (codex MAJOR 3).
    ///
    /// A third way in arrived with REVIEW CR-04: a refresh that failed before it could produce a
    /// snapshot, which on this Mac means no `git` at all. "No repos found" is not the reason and
    /// "Add folder…" is a dead end for it, so the failure's own title, message, and action replace
    /// both. The failure is rendered from `RefreshState` here rather than in the SwiftUI layer for
    /// the same reason every other sentence is: this is where user-facing copy is assembled.
    private func emptyState(refreshState: RefreshState, scanResult: ScanResult?) -> EmptyStateVM {
        let addFolder = UserFacingFailure.Action(label: Strings.addFolderActionLabel, kind: .addFolder)
        let notice = notScannedNotice(scanResult)

        if let failure = Self.failure(in: refreshState) {
            return EmptyStateVM(
                title: failure.title,
                message: failure.message,
                // `EmptyStateVM.action` is not optional; a failure with no action of its own falls
                // back to the one action that is always available from an empty list.
                action: failure.action ?? addFolder,
                notice: notice
            )
        }

        if case .running = refreshState {
            // §5a offers no action while the first scan runs; `EmptyStateVM.action` is not
            // optional, so the state carries the action it will offer when the scan finishes.
            return EmptyStateVM(
                title: Strings.firstRunTitle,
                message: Strings.firstRunMessage,
                action: addFolder,
                notice: notice
            )
        }
        return EmptyStateVM(
            title: Strings.emptyStateTitle,
            message: Strings.emptyStateMessage,
            action: addFolder,
            notice: notice
        )
    }

    // MARK: - Row actions

    /// PLAN.md §3, as amended by codex round 4: Cursor → VS Code → Show in Finder.
    /// `UserFacingFailure.Action.Kind` (frozen in packet 1.1) has no case for opening a folder, so
    /// the payload carries the path and `.openURL` is the closest frozen kind; the shell already
    /// routes an absolute-path `.openURL` through `Actions.openInAvailableEditor`, whose own last
    /// step is `revealInFinder`. The label is what the row shows either way, and on a Mac with
    /// neither editor it now names the thing that actually happens.
    private func openAction(path: String) -> UserFacingFailure.Action {
        UserFacingFailure.Action(
            label: Strings.openInAvailableEditorLabel(editors),
            kind: .openURL,
            payload: path
        )
    }

    // MARK: - Small helpers

    /// The failure a refresh ended in, if it ended in one. Both the empty state and the footer
    /// notice ask the same question of `RefreshState`, so they ask it in one place.
    private static func failure(in refreshState: RefreshState) -> UserFacingFailure? {
        if case .failed(let failure) = refreshState { return failure }
        return nil
    }

    private func folderName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}
