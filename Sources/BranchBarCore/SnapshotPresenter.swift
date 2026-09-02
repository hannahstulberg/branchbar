import Foundation

/// Which of the row-opening apps PLAN.md §3 names are on this Mac.
///
/// It is a property of the machine rather than of a `Snapshot`, so it is handed to the presenter
/// once at construction and `present`'s argument list stays exactly the six that packet 4.0 froze
/// into `Tests/BranchBarCoreTests/Fixtures/states/*.json`. Terminal is always present, which is
/// why the fallback chain in §3 ends there and this type has no third flag.
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
///   (git too old, `gh` missing, Cursor missing, stale rows, deadline exceeded) is joined into it
///   in that order, and the first of them that carries an action supplies the notice's action.
/// - `BranchRowVM.aheadLabel` is the tertiary line §5a gives to the branch's relationship with
///   last-known origin (ahead / in sync / no upstream / upstream missing). On a merged or
///   closed-unmerged row the group copy is appended after " · ", the separator `pushUnknown`
///   already uses to join two facts in one line, because §5a gives the row no other slot for it.
public struct SnapshotPresenter: Sendable {

    /// Decides the primary row action: Cursor → VS Code → Terminal (PLAN.md §3).
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
            emptyState: snapshot.repos.isEmpty ? emptyState(refreshState: refreshState) : nil
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
            notScannedNotice: notScannedNotice(scanResult)
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
            pushLabel: push.label,
            pushTooltip: push.tooltip,
            aheadLabel: aheadLabel(for: branch),
            primaryAction: openAction(path: branch.worktreePath ?? repo.path),
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
                    // There is no branch here, so there is no push fact to state and none is
                    // invented: an empty line is honest where "Never pushed" would not be.
                    pushLabel: "",
                    pushTooltip: "",
                    aheadLabel: nil,
                    primaryAction: openAction(path: worktree.path),
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

        switch push.source {
        case .reflogObserved:
            label = Strings.pushed(
                reflogAt: push.observedPushAt ?? branch.committerDate,
                now: now,
                originMovedSince: push.originMovedSince
            )
            tooltip = Strings.pushedTooltip
        case .tipCommitDate:
            label = Strings.pushUnknown(tipCommitDate: branch.committerDate, now: now)
            tooltip = Strings.pushUnknownTooltip
        case .none:
            label = Strings.neverPushed
            tooltip = Strings.neverPushedTooltip
        }

        // §5a item 3 hangs both the push tooltip and the ahead tooltip off the tertiary tier, and
        // `BranchRowVM` has one tooltip field, so the anchor rides along when there is a count.
        if aheadCount(for: branch) > 0 {
            tooltip += " " + Strings.aheadTooltip(remoteObservedAt: push.remoteRefObservedAt, now: now)
        }
        return (label, tooltip)
    }

    private func aheadCount(for branch: Branch) -> Int {
        branch.push.aheadOfLastKnownRemote ?? branch.upstream?.ahead ?? 0
    }

    /// The tertiary line: where this branch stands against last-known origin, plus the group copy
    /// on a merged or closed row. PLAN.md §3 forbids "0 ahead" for a branch that tracks nothing and
    /// forbids showing `behind` at all.
    private func aheadLabel(for branch: Branch) -> String? {
        let hasUpstream = branch.push.hasUpstream || branch.upstream != nil
        let isGone = branch.push.upstreamGone || branch.upstream?.isGone == true

        var parts: [String] = []
        if isGone {
            parts.append(Strings.upstreamMissing)
        } else if !hasUpstream {
            parts.append(Strings.noUpstream)
        } else if aheadCount(for: branch) > 0 {
            parts.append(Strings.ahead(aheadCount(for: branch)))
        } else {
            parts.append(Strings.inSync)
        }

        switch branch.group {
        case .merged:
            // The copy names the base branch, so a merged branch with no PR row to name it gets
            // no claim made on its behalf.
            if let pr = branch.pr { parts.append(Strings.mergedDetail(baseRefName: pr.baseRefName)) }
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
        } else if case .unavailable(let reason, _) = repo.prAvailability {
            let failure = Strings.unavailable(reason: reason)
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
        guard let scanResult, !scanResult.unreadableDirectories.isEmpty else { return nil }
        return NoticeVM(
            text: Strings.notScanned(folders: scanResult.unreadableDirectories.map(folderName))
                + "\n" + Strings.skippedCategoriesSummary,
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
            toolNotice: toolNotice(snapshot: snapshot, isRefreshing: isRefreshing),
            scanRoots: scanResult?.policy.extraRoots ?? []
        )
    }

    /// Everything the footer has to say about this Mac and this refresh, in one slot.
    private func toolNotice(snapshot: Snapshot, isRefreshing: Bool) -> NoticeVM? {
        var lines: [String] = []
        var action: UserFacingFailure.Action?

        // The notice quotes the number, not the whole banner: `2.30.1`, never
        // `git version 2.30.1 (Apple Git-130)`.
        if let git = snapshot.tools.gitVersion.flatMap(GitVersion.parse), git.isBelowMinimumSupported {
            lines.append(Strings.gitTooOldNotice(version: git.description))
        }
        if snapshot.tools.ghPath == nil {
            let failure = Strings.unavailable(reason: .ghNotInstalled)
            lines.append(failure.message)
            action = failure.action
        }
        if !editors.cursor {
            lines.append(Strings.cursorNotInstalledNotice)
        }
        // Rows restored from the last run while the first refresh is still in flight.
        if isRefreshing, snapshot.repos.contains(where: { $0.isStale || $0.prLoadState == .stale }) {
            lines.append(Strings.staleRowsNotice)
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
    private func emptyState(refreshState: RefreshState) -> EmptyStateVM {
        let addFolder = UserFacingFailure.Action(label: Strings.addFolderActionLabel, kind: .addFolder)

        if case .running = refreshState {
            // §5a offers no action while the first scan runs; `EmptyStateVM.action` is not
            // optional, so the state carries the action it will offer when the scan finishes.
            return EmptyStateVM(
                title: Strings.firstRunTitle,
                message: Strings.firstRunMessage,
                action: addFolder
            )
        }
        return EmptyStateVM(
            title: Strings.emptyStateTitle,
            message: Strings.emptyStateMessage,
            action: addFolder
        )
    }

    // MARK: - Row actions

    /// PLAN.md §3: Cursor → VS Code → Terminal. `UserFacingFailure.Action.Kind` (frozen in packet
    /// 1.1) has no case for opening a folder, so the payload carries the path and `.openURL` is
    /// the closest frozen kind; the label is what the row shows either way.
    private func openAction(path: String) -> UserFacingFailure.Action {
        let label: String
        if editors.cursor {
            label = Strings.openInCursorActionLabel
        } else if editors.vsCode {
            label = Strings.openInVSCodeActionLabel
        } else {
            label = Strings.openInTerminalActionLabel
        }
        return UserFacingFailure.Action(label: label, kind: .openURL, payload: path)
    }

    // MARK: - Small helpers

    private func folderName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}
