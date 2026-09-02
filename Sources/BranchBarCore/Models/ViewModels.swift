import Foundation

// PLAN.md §5 view-models. Produced in Core by `SnapshotPresenter` (packet 2.2) from
// `Strings.swift` (packet 4.0) so every string a user reads is unit-testable and the SwiftUI
// layer holds no copy. The views render these and nothing else.

public struct SnapshotVM: Hashable, Codable, Sendable {
    public var sections: [RepoSectionVM]
    public var footer: FooterVM
    /// Non-nil only when there are no sections to show (`emptyScanRendersActionableEmptyState`).
    public var emptyState: EmptyStateVM?

    public init(sections: [RepoSectionVM] = [], footer: FooterVM, emptyState: EmptyStateVM? = nil) {
        self.sections = sections
        self.footer = footer
        self.emptyState = emptyState
    }
}

/// One repo. Group order is fixed by PLAN.md §5a item 3: Branches and worktrees → Open PRs not
/// on this Mac → Merged → Closed without merging.
public struct RepoSectionVM: Hashable, Codable, Sendable {
    public var id: RepoID
    public var title: String
    /// The repo's own folder, so a section-level menu (open in an editor, Show in Finder, Copy
    /// path) names it instead of guessing it off whichever row happens to be first. Optional and
    /// defaulted so a `RepoSectionVM` recorded before the field existed still decodes.
    public var path: String?
    public var isCollapsed: Bool
    public var active: [BranchRowVM]
    public var openElsewhere: [PRRowVM]
    public var merged: [BranchRowVM]
    public var closedUnmerged: [BranchRowVM]
    /// "PR status loads when expanded", "PR status not checked yet", or a `PRAvailability` reason.
    public var prNotice: NoticeVM?
    /// TCC-denied folders plus the skipped-categories summary.
    public var notScannedNotice: NoticeVM?
    /// The repo's validated GitHub host, from `Repo.githubSlug?.host`, so `Actions.openPR` can
    /// refuse a link that points anywhere else (codex MINOR 3). Optional and defaulted so a
    /// `RepoSectionVM` recorded before the field existed still decodes, and nil for a repo with no
    /// GitHub remote — which is also a repo with no PR link to open.
    public var host: String?

    public init(
        id: RepoID,
        title: String,
        path: String? = nil,
        isCollapsed: Bool = false,
        active: [BranchRowVM] = [],
        openElsewhere: [PRRowVM] = [],
        merged: [BranchRowVM] = [],
        closedUnmerged: [BranchRowVM] = [],
        prNotice: NoticeVM? = nil,
        notScannedNotice: NoticeVM? = nil,
        host: String? = nil
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.isCollapsed = isCollapsed
        self.active = active
        self.openElsewhere = openElsewhere
        self.merged = merged
        self.closedUnmerged = closedUnmerged
        self.prNotice = prNotice
        self.notScannedNotice = notScannedNotice
        self.host = host
    }
}

/// One branch row. PLAN.md §5a item 3: worktree marker leading, branch name primary,
/// PR pill secondary, push line and ahead count tertiary.
public struct BranchRowVM: Hashable, Codable, Sendable {
    public var title: String
    /// "Worktree at commit abc1234 (no branch)" and friends; empty when there is no worktree.
    public var worktreeMarker: String?
    public var prPill: PRPillVM?
    /// The matched PR's web address, so the row's menu can offer "Open PR" without the shell
    /// having to hold a `PRInfo`. Nil when no PR matched this branch. Optional and defaulted so a
    /// `BranchRowVM` recorded before the field existed still decodes.
    public var prURL: String?
    /// "Pushed from this Mac 2 days ago" or "Last push unknown · newest commit dated 2 days ago".
    public var pushLabel: String
    public var pushTooltip: String
    /// "2 ahead of last-known origin"; nil when there is no upstream or nothing ahead.
    public var aheadLabel: String?
    public var primaryAction: UserFacingFailure.Action
    public var accessibilityLabel: String

    public init(
        title: String,
        worktreeMarker: String? = nil,
        prPill: PRPillVM? = nil,
        prURL: String? = nil,
        pushLabel: String,
        pushTooltip: String,
        aheadLabel: String? = nil,
        primaryAction: UserFacingFailure.Action,
        accessibilityLabel: String
    ) {
        self.title = title
        self.worktreeMarker = worktreeMarker
        self.prPill = prPill
        self.prURL = prURL
        self.pushLabel = pushLabel
        self.pushTooltip = pushTooltip
        self.aheadLabel = aheadLabel
        self.primaryAction = primaryAction
        self.accessibilityLabel = accessibilityLabel
    }
}

/// Text plus the status the token table colors it by. PLAN.md §5a item 4: ten `PRStatus` colors
/// in light and dark. No emoji as status (§5a accessibility).
public struct PRPillVM: Hashable, Codable, Sendable {
    public var text: String
    public var status: PRStatus

    public init(text: String, status: PRStatus) {
        self.text = text
        self.status = status
    }
}

/// A PR with no matching local branch. PLAN.md §3: state and link only, no branch actions.
public struct PRRowVM: Hashable, Codable, Sendable {
    public var title: String
    public var prPill: PRPillVM
    public var url: String
    public var accessibilityLabel: String

    public init(title: String, prPill: PRPillVM, url: String, accessibilityLabel: String) {
        self.title = title
        self.prPill = prPill
        self.url = url
        self.accessibilityLabel = accessibilityLabel
    }
}

public struct NoticeVM: Hashable, Codable, Sendable {
    public var text: String
    public var action: UserFacingFailure.Action?

    public init(text: String, action: UserFacingFailure.Action? = nil) {
        self.text = text
        self.action = action
    }
}

public struct FooterVM: Hashable, Codable, Sendable {
    /// "Updated 12 s ago".
    public var updatedLabel: String
    public var version: String
    /// git older than 2.39, `gh` missing, or a per-host auth failure.
    public var toolNotice: NoticeVM?
    /// Scan roots listed and removable (PLAN.md §3).
    public var scanRoots: [String]

    public init(updatedLabel: String, version: String, toolNotice: NoticeVM? = nil, scanRoots: [String] = []) {
        self.updatedLabel = updatedLabel
        self.version = version
        self.toolNotice = toolNotice
        self.scanRoots = scanRoots
    }
}

/// Zero repos. PLAN.md §5a item 1: primary action Add folder…, and the copy names Drive/Dropbox
/// and deep folders as the reason a repo might be missing.
public struct EmptyStateVM: Hashable, Codable, Sendable {
    public var title: String
    public var message: String
    public var action: UserFacingFailure.Action
    /// The TCC-denied folders and the skipped-categories summary, when the scan hit one and found
    /// no repo at all. `RepoSectionVM.notScannedNotice` was the only slot that notice had, and with
    /// zero repos there is no section to hang it on — which is exactly the case where every repo
    /// sits in a denied folder, so the user saw the generic "No repos found" and no way to fix it
    /// (codex MAJOR 3). Optional and defaulted so an `EmptyStateVM` recorded before the field
    /// existed still decodes.
    public var notice: NoticeVM?

    public init(
        title: String,
        message: String,
        action: UserFacingFailure.Action,
        notice: NoticeVM? = nil
    ) {
        self.title = title
        self.message = message
        self.action = action
        self.notice = notice
    }
}
