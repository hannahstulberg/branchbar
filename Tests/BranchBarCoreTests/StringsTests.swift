import Foundation
import Testing

@testable import BranchBarCore

// Packet 4.0. PLAN.md §5a freezes the UI contract before any SwiftUI exists: every state a user
// can land in, the literal string each one shows, and one action per failure. This file is the
// executable half of that contract. `docs/UI-CONTRACT.md` is the readable half and
// `scripts/doc-strings.sh` regenerates its string table from `Strings.swift`, so the two cannot
// drift.
//
// The state table below is the single source: the reachability test, the vocabulary sweep, the
// UI-CONTRACT.md coverage check, and the per-state fixtures under `Fixtures/states/` are all
// derived from it. Adding a state means adding one row.

// MARK: - Fixed clock

/// Every relative string here is computed against one frozen instant so the recorded fixtures are
/// byte-stable. A UI contract is a contract, not a snapshot of the day it was written.
enum UIClock {
    static let now = Date(timeIntervalSince1970: 1_788_609_600)
    static let minute: TimeInterval = 60
    static let hour: TimeInterval = 3_600
    static let day: TimeInterval = 86_400
    static func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
}

let uiAppVersion = "0.9.0"

// MARK: - The fixture envelope

/// Exactly the argument list of `SnapshotPresenter.present` plus the literal strings the state is
/// contracted to show. Packet 2.2 decodes one of these, calls `present`, and asserts every
/// `expectedStrings` entry appears in the rendered `SnapshotVM`; Gate 4 renders the same file to a
/// screenshot. Encoded with the real `JSONEncoder`, so a change to a frozen type breaks here first.
struct StateFixture: Hashable, Codable {
    var id: String
    var title: String
    var planReference: String
    var snapshot: Snapshot
    var refreshState: RefreshState
    var collapsedRepoIDs: [RepoID]
    var scanResult: ScanResult?
    var appVersion: String
    var now: Date
    var expectedStrings: [String]
}

/// One row of the state table: what the user is looking at, which `Strings` members produce it,
/// and the fixture that reproduces it.
struct UIState {
    /// Fixture filename stem and the id used in `docs/UI-CONTRACT.md`.
    var id: String
    var title: String
    var planReference: String
    /// `(member base name, the literal it renders in this state)`.
    var entries: [(String, String)]
    var snapshot: Snapshot
    var refreshState: RefreshState
    var collapsedRepoIDs: [RepoID] = []
    var scanResult: ScanResult? = nil

    var members: [String] { entries.map(\.0) }
    var strings: [String] { entries.map(\.1) }

    var fixture: StateFixture {
        StateFixture(
            id: id,
            title: title,
            planReference: planReference,
            snapshot: snapshot,
            refreshState: refreshState,
            collapsedRepoIDs: collapsedRepoIDs,
            scanResult: scanResult,
            appVersion: uiAppVersion,
            now: UIClock.now,
            expectedStrings: strings
        )
    }
}

// MARK: - Builders

enum UIFixtures {
    static let tipSHA = "1111111111111111111111111111111111111111"
    static let otherSHA = "2222222222222222222222222222222222222222"
    static let home = "/Users/tester"

    static func id(_ name: String) -> RepoID { RepoID(commonDir: "\(home)/\(name)/.git") }

    static func branch(
        _ name: String,
        tipSHA: String = UIFixtures.tipSHA,
        committerDate: Date = UIClock.ago(2 * UIClock.day),
        upstream: Upstream? = nil,
        worktreePath: String? = nil,
        isCheckedOutInPrimary: Bool = true,
        pr: PRInfo? = nil,
        prStatus: PRStatus = .notChecked,
        push: PushInfo = PushInfo(),
        group: BranchGroup = .active
    ) -> Branch {
        Branch(
            name: name,
            tipSHA: tipSHA,
            committerDate: committerDate,
            upstream: upstream,
            worktreePath: worktreePath,
            isCheckedOutInPrimary: isCheckedOutInPrimary,
            pr: pr,
            prStatus: prStatus,
            push: push,
            group: group
        )
    }

    static func pr(
        _ number: Int,
        state: String = "OPEN",
        isDraft: Bool = false,
        reviewDecision: String = "",
        mergedAt: Date? = nil,
        baseRefName: String = "main",
        headRefName: String,
        headRefOid: String = UIFixtures.tipSHA,
        owner: String = "tester"
    ) -> PRInfo {
        PRInfo(
            number: number,
            url: "https://github.com/tester/demo/pull/\(number)",
            state: state,
            isDraft: isDraft,
            reviewDecision: reviewDecision,
            mergedAt: mergedAt,
            updatedAt: UIClock.ago(UIClock.hour),
            baseRefName: baseRefName,
            headRefName: headRefName,
            headRefOid: headRefOid,
            headRepositoryOwnerLogin: owner
        )
    }

    static func repo(
        _ name: String = "demo",
        remoteURL: String? = "git@github.com:tester/demo.git",
        worktrees: [Worktree] = [],
        branches: [Branch] = [],
        openPRsNotOnThisMac: [PRInfo] = [],
        prAvailability: PRAvailability = .available,
        prLoadState: PRLoadState = .loaded,
        errors: [RepoError] = [],
        isStale: Bool = false
    ) -> Repo {
        let path = "\(home)/\(name)"
        return Repo(
            id: id(name),
            name: name,
            path: path,
            remoteURL: remoteURL,
            githubSlug: remoteURL.flatMap(GitHubSlug.init(remoteURL:)),
            worktrees: worktrees.isEmpty
                ? [Worktree(path: path, headSHA: tipSHA, branch: "refs/heads/main", isPrimary: true)]
                : worktrees,
            branches: branches,
            openPRsNotOnThisMac: openPRsNotOnThisMac,
            prAvailability: prAvailability,
            prFetchedAt: UIClock.ago(5 * UIClock.minute),
            prLoadState: prLoadState,
            lastRefreshed: UIClock.ago(12),
            errors: errors,
            isStale: isStale,
            lastActivity: UIClock.ago(2 * UIClock.day)
        )
    }

    static func snapshot(
        _ repos: [Repo],
        refreshedAt: Date? = UIClock.ago(12),
        tools: ToolStatus = ToolStatus(
            gitPath: "/usr/bin/git",
            gitVersion: "git version 2.39.5 (Apple Git-154)",
            ghPath: "/opt/homebrew/bin/gh",
            ghAuthByHost: ["github.com": true]
        )
    ) -> Snapshot {
        Snapshot(repos: repos, refreshedAt: refreshedAt, tools: tools)
    }

    static func scanResult(
        repoCount: Int = 1,
        unreadable: [String] = [],
        depthCut: Int = 0,
        hidden: Int = 0,
        extraRoots: [String] = []
    ) -> ScanResult {
        let policy = ScanPolicy(homeRoot: home, extraRoots: extraRoots)
        let repos = (0..<repoCount).map { DiscoveredRepo(path: "\(home)/demo\($0)", id: id("demo\($0)")) }
        return ScanResult(
            policy: policy,
            scannedAt: UIClock.ago(UIClock.minute),
            repos: repos,
            candidatesExamined: 1_204,
            unreadableDirectories: unreadable,
            depthCutDirectories: depthCut,
            skippedHiddenDirectories: hidden
        )
    }
}

// MARK: - The state table

/// Every state PLAN.md §5a item 1 names, plus every state implied by a case of a type packet 1.1
/// froze: ten `PRStatus` cases, six `PRUnavailableReason` cases, three `PushInfo.Source` cases,
/// six `RepoError.Stage` cases, six `UserFacingFailure.Action.Kind` cases.
enum UIStates {

    static let all: [UIState] = [
        firstRunScanning,
        zeroRepos,
        notScannedFolders,
        ghNotInstalled,
        ghNotAuthenticated,
        rateLimited,
        noGitHubRemote,
        noRemote,
        prListTimeout,
        singleBranchNoPRNeverPushed,
        prNotLoaded,
        prNotChecked,
        repoFailed,
        deadlineExceeded,
        staleRowsAtLaunch,
        gitTooOld,
        cursorNotInstalled,
        lastPushUnknown,
        originMovedSince,
        prDraft,
        prOpen,
        prChangesRequested,
        prApproved,
        mergedGroup,
        closedUnmergedGroup,
        openPRsNotOnThisMac,
        upstreamMissing,
        aheadOfLastKnownOrigin,
        inSync,
        detachedWorktree,
        worktreeCheckout,
        refreshRunning,
        hiddenRepo,
        launchAtLoginNeedsApproval,
    ]

    // 1
    static let firstRunScanning = UIState(
        id: "first-run-scanning",
        title: "First run, still looking for repos",
        planReference: "§5a item 1: first run while scanning",
        entries: [
            ("menuBarAccessibilityLabel", Strings.menuBarAccessibilityLabel),
            ("firstRunTitle", Strings.firstRunTitle),
            ("firstRunMessage", Strings.firstRunMessage),
            ("updated", Strings.updated(at: nil, now: UIClock.now)),
            ("versionLabel", Strings.versionLabel(uiAppVersion)),
        ],
        snapshot: UIFixtures.snapshot([], refreshedAt: nil),
        refreshState: .running(completed: 0, total: 0)
    )

    // 2
    static let zeroRepos = UIState(
        id: "zero-repos",
        title: "Zero repos found",
        planReference: "§5a item 1: zero repos, primary action Add folder…",
        entries: [
            ("emptyStateTitle", Strings.emptyStateTitle),
            ("emptyStateMessage", Strings.emptyStateMessage),
            ("addFolderActionLabel", Strings.addFolderActionLabel),
            ("rescanActionLabel", Strings.rescanActionLabel),
        ],
        snapshot: UIFixtures.snapshot([]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12)),
        scanResult: UIFixtures.scanResult(repoCount: 0)
    )

    // 3
    static let notScannedFolders = UIState(
        id: "not-scanned-folders",
        title: "Folders BranchBar could not read, plus what it skipped on purpose",
        planReference: "§5a item 1: Not-scanned folders row and the skipped-categories summary",
        entries: [
            ("notScanned", Strings.notScanned(folders: ["Documents", "Desktop"])),
            ("grantFolderAccessActionLabel", Strings.grantFolderAccessActionLabel),
            ("skippedCategoriesSummary", Strings.skippedCategoriesSummary),
            ("scanRootsHeading", Strings.scanRootsHeading),
            ("removeScanRootActionLabel", Strings.removeScanRootActionLabel),
            ("filesAndFoldersSettingsURL", Strings.filesAndFoldersSettingsURL),
        ],
        snapshot: UIFixtures.snapshot([UIFixtures.repo(branches: [UIFixtures.branch("main")])]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12)),
        scanResult: UIFixtures.scanResult(
            unreadable: ["/Users/tester/Documents", "/Users/tester/Desktop"],
            depthCut: 37,
            hidden: 412,
            extraRoots: ["/Users/tester/Library/CloudStorage/Dropbox"]
        )
    )

    // 4
    static let ghNotInstalled = UIState(
        id: "gh-not-installed",
        title: "GitHub CLI is not on this Mac",
        planReference: "§5a item 1: gh not installed; PRUnavailableReason.ghNotInstalled",
        entries: [
            ("ghNotInstalledTitle", Strings.ghNotInstalledTitle),
            ("ghNotInstalledMessage", Strings.ghNotInstalledMessage),
            ("installGitHubCLIActionLabel", Strings.installGitHubCLIActionLabel),
            ("installGitHubCLIURL", Strings.installGitHubCLIURL),
            ("unavailable", Strings.unavailable(reason: .ghNotInstalled).message),
            ("prUnavailable", Strings.prUnavailable),
            ("prPill", Strings.prPill(for: .unavailable)),
        ],
        snapshot: UIFixtures.snapshot(
            [
                UIFixtures.repo(
                    branches: [UIFixtures.branch("main", prStatus: .unavailable)],
                    prAvailability: .unavailable(.ghNotInstalled, detail: nil),
                    prLoadState: .notLoaded
                )
            ],
            tools: ToolStatus(gitPath: "/usr/bin/git", gitVersion: "git version 2.39.5 (Apple Git-154)")
        ),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 5
    static let ghNotAuthenticated = UIState(
        id: "gh-not-authenticated",
        title: "GitHub CLI is installed but not signed in to this host",
        planReference: "§5a item 1: gh not signed in, per host, with the Open-Terminal setup action",
        entries: [
            ("ghNotAuthenticatedTitle", Strings.ghNotAuthenticatedTitle(host: "github.com")),
            ("ghNotAuthenticatedMessage", Strings.ghNotAuthenticatedMessage(host: "github.com")),
            ("openTerminalActionLabel", Strings.openTerminalActionLabel),
            ("ghAuthLoginCommand", Strings.ghAuthLoginCommand(host: "github.com")),
            ("ghSignInScriptBanner", Strings.ghSignInScriptBanner),
        ],
        snapshot: UIFixtures.snapshot(
            [
                UIFixtures.repo(
                    branches: [UIFixtures.branch("main", prStatus: .unavailable)],
                    prAvailability: .unavailable(.ghNotAuthenticated(host: "github.com"), detail: nil),
                    prLoadState: .notLoaded
                )
            ],
            tools: ToolStatus(
                gitPath: "/usr/bin/git",
                gitVersion: "git version 2.39.5 (Apple Git-154)",
                ghPath: "/opt/homebrew/bin/gh",
                ghAuthByHost: ["github.com": false]
            )
        ),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 6
    static let rateLimited = UIState(
        id: "rate-limited",
        title: "GitHub is rate limiting BranchBar",
        planReference: "§5a item 1: rate limited; PRUnavailableReason.rateLimited",
        entries: [
            ("rateLimitedTitle", Strings.rateLimitedTitle),
            ("rateLimitedMessage", Strings.rateLimitedMessage),
            ("refreshActionLabel", Strings.refreshActionLabel),
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(
                branches: [UIFixtures.branch("main", prStatus: .unavailable)],
                prAvailability: .unavailable(.rateLimited, detail: nil),
                prLoadState: .notLoaded
            )
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 7
    static let noGitHubRemote = UIState(
        id: "no-github-remote",
        title: "Origin is not a GitHub address",
        planReference: "§5a item 1: no GitHub remote; PRUnavailableReason.notGitHubRemote",
        entries: [
            ("notGitHubRemoteTitle", Strings.notGitHubRemoteTitle),
            ("notGitHubRemoteMessage", Strings.notGitHubRemoteMessage),
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(
                "internal-tools",
                remoteURL: "git@git.example.internal:team/internal-tools.git",
                branches: [UIFixtures.branch("main", prStatus: .unavailable)],
                prAvailability: .unavailable(.notGitHubRemote, detail: nil),
                prLoadState: .notLoaded
            )
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 8
    static let noRemote = UIState(
        id: "no-remote",
        title: "Repo has no origin at all",
        planReference: "PRUnavailableReason.noRemote",
        entries: [
            ("noRemoteTitle", Strings.noRemoteTitle),
            ("noRemoteMessage", Strings.noRemoteMessage),
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(
                "scratch",
                remoteURL: nil,
                branches: [UIFixtures.branch("main", prStatus: .unavailable)],
                prAvailability: .unavailable(.noRemote, detail: nil),
                prLoadState: .notLoaded
            )
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 9
    static let prListTimeout = UIState(
        id: "pr-list-timeout",
        title: "The PR lookup did not answer in time",
        planReference: "§5a item 1: gh pr list timeout; PRUnavailableReason.commandFailed",
        entries: [
            ("commandFailedTitle", Strings.commandFailedTitle),
            ("commandFailedMessage", Strings.commandFailedMessage),
            ("repoPRStatusFailed", Strings.repoPRStatusFailed),
            ("repoErrorNotice", Strings.repoErrorNotice(stage: .github)),
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(
                branches: [UIFixtures.branch("main", prStatus: .unavailable)],
                prAvailability: .unavailable(.commandFailed, detail: "timed out after 25 s"),
                prLoadState: .notLoaded,
                errors: [RepoError(stage: .github, message: "timed out after 25 s")]
            )
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 10 — the modal NYT case
    static let singleBranchNoPRNeverPushed = UIState(
        id: "single-branch-no-pr-never-pushed",
        title: "One branch, no PR, never pushed",
        planReference: "§5a item 1: one branch, no PR, never pushed (the modal NYT case)",
        entries: [
            ("activeGroupHeading", Strings.activeGroupHeading),
            ("checkedOutMarker", Strings.checkedOutMarker),
            ("prNone", Strings.prNone),
            ("neverPushed", Strings.neverPushed),
            ("neverPushedTooltip", Strings.neverPushedTooltip),
            ("noUpstream", Strings.noUpstream),
            ("relative", Strings.relative(UIClock.ago(2 * UIClock.day), now: UIClock.now)),
            (
                "branchRowAccessibilityLabel",
                Strings.branchRowAccessibilityLabel(
                    branchName: "notes-cleanup",
                    prPill: Strings.prNone,
                    pushLabel: Strings.neverPushed
                )
            ),
            ("openInCursorActionLabel", Strings.openInCursorActionLabel),
            ("revealInFinderActionLabel", Strings.revealInFinderActionLabel),
            ("copyPathActionLabel", Strings.copyPathActionLabel),
            ("refreshPRsNowActionLabel", Strings.refreshPRsNowActionLabel),
            ("launchAtLoginToggleLabel", Strings.launchAtLoginToggleLabel),
            ("quitActionLabel", Strings.quitActionLabel),
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(branches: [
                UIFixtures.branch("notes-cleanup", prStatus: .none, push: PushInfo(source: .none))
            ])
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 11
    static let prNotLoaded = UIState(
        id: "pr-not-loaded",
        title: "Collapsed repo, PR status not fetched",
        planReference: "§5a item 1: PR status not loaded (collapsed repo); PRStatus.notLoaded",
        entries: [
            ("prNotLoaded", Strings.prNotLoaded),
            ("expandSectionActionLabel", Strings.expandSectionActionLabel),
            ("collapseSectionActionLabel", Strings.collapseSectionActionLabel),
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(
                branches: [UIFixtures.branch("main", prStatus: .notLoaded)],
                prLoadState: .notLoaded
            )
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12)),
        collapsedRepoIDs: [UIFixtures.id("demo")]
    )

    // 12
    static let prNotChecked = UIState(
        id: "pr-not-checked",
        title: "The per-head lookup never ran for this branch",
        planReference: "§5a item 1: PR status not checked (cap or deadline); PRStatus.notChecked",
        entries: [
            ("prNotChecked", Strings.prNotChecked)
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(branches: [UIFixtures.branch("spike-21", prStatus: .notChecked)])
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 13
    static let repoFailed = UIState(
        id: "repo-failed",
        title: "One repo failed while the others populated",
        planReference: "§5a item 1: one repo failed; RepoError.Stage",
        entries: [
            ("repoBranchesFailed", Strings.repoBranchesFailed),
            ("repoWorktreesFailed", Strings.repoWorktreesFailed),
            ("repoRemotesFailed", Strings.repoRemotesFailed),
            ("repoPushHistoryFailed", Strings.repoPushHistoryFailed),
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo("healthy", branches: [UIFixtures.branch("main", prStatus: .none)]),
            UIFixtures.repo(
                "broken",
                branches: [],
                errors: [
                    RepoError(stage: .branches, message: "git exited 128"),
                    RepoError(stage: .worktrees, message: "git exited 128"),
                ]
            ),
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 14
    static let deadlineExceeded = UIState(
        id: "deadline-exceeded",
        title: "The 45-second deadline cut the refresh short",
        planReference: "§5a item 1: deadline exceeded; RepoError.Stage.deadlineExceeded",
        entries: [
            ("deadlineExceededNotice", Strings.deadlineExceededNotice),
            ("repoDeadlineExceeded", Strings.repoDeadlineExceeded),
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(
                "monorepo",
                branches: [UIFixtures.branch("main", prStatus: .notChecked)],
                errors: [RepoError(stage: .deadlineExceeded, message: "45 s")],
                isStale: true
            )
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 15
    static let staleRowsAtLaunch = UIState(
        id: "stale-rows-at-launch",
        title: "Rows restored from the last run while the first refresh runs",
        planReference: "§5a item 1: stale rows at launch",
        entries: [
            ("staleRowsNotice", Strings.staleRowsNotice)
        ],
        snapshot: UIFixtures.snapshot(
            [
                UIFixtures.repo(
                    branches: [UIFixtures.branch("main", prStatus: .notLoaded)],
                    prLoadState: .stale,
                    isStale: true
                )
            ],
            refreshedAt: UIClock.ago(3 * UIClock.hour)
        ),
        refreshState: .running(completed: 0, total: 1)
    )

    // 16
    static let gitTooOld = UIState(
        id: "git-too-old",
        title: "git on this Mac is older than 2.39",
        planReference: "§5a item 1: git older than 2.39",
        entries: [
            ("gitTooOldNotice", Strings.gitTooOldNotice(version: "2.30.1"))
        ],
        snapshot: UIFixtures.snapshot(
            [UIFixtures.repo(branches: [UIFixtures.branch("main", prStatus: .none)])],
            tools: ToolStatus(
                gitPath: "/usr/bin/git",
                gitVersion: "git version 2.30.1 (Apple Git-130)",
                ghPath: "/opt/homebrew/bin/gh",
                ghAuthByHost: ["github.com": true]
            )
        ),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 17
    static let cursorNotInstalled = UIState(
        id: "cursor-not-installed",
        title: "Cursor is not installed, so rows open elsewhere",
        planReference: "§5a item 1: Cursor not installed",
        entries: [
            ("cursorNotInstalledNotice", Strings.cursorNotInstalledNotice),
            ("openInVSCodeActionLabel", Strings.openInVSCodeActionLabel),
            ("openInTerminalActionLabel", Strings.openInTerminalActionLabel),
            (
                "openInAvailableEditorLabel",
                Strings.openInAvailableEditorLabel(EditorAvailability(cursor: false, vsCode: true))
            ),
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(branches: [UIFixtures.branch("main", prStatus: .none)])
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 18
    static let lastPushUnknown = UIState(
        id: "last-push-unknown",
        title: "No push was ever observed from this Mac",
        planReference: "§5a item 1: last push unknown; PushInfo.Source.tipCommitDate",
        entries: [
            ("pushUnknown", Strings.pushUnknown(tipCommitDate: UIClock.ago(2 * UIClock.day), now: UIClock.now)),
            ("pushUnknownTooltip", Strings.pushUnknownTooltip),
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(branches: [
                UIFixtures.branch(
                    "imported-from-laptop",
                    upstream: Upstream(ref: "origin/imported-from-laptop", remote: "origin"),
                    prStatus: .none,
                    push: PushInfo(
                        source: .tipCommitDate,
                        hasUpstream: true,
                        aheadOfLastKnownRemote: 0,
                        remoteRefObservedAt: UIClock.ago(2 * UIClock.day)
                    )
                )
            ])
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 19
    static let originMovedSince = UIState(
        id: "origin-moved-since",
        title: "The observed push is no longer the tip of last-known origin",
        planReference: "§5a item 1: origin moved since the observed push; PushInfo.Source.reflogObserved",
        entries: [
            (
                "pushed",
                Strings.pushed(reflogAt: UIClock.ago(2 * UIClock.day), now: UIClock.now, originMovedSince: true)
            ),
            ("originMovedSince", Strings.originMovedSince),
            ("pushedTooltip", Strings.pushedTooltip),
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(branches: [
                UIFixtures.branch(
                    "shared-draft",
                    upstream: Upstream(ref: "origin/shared-draft", remote: "origin"),
                    prStatus: .open,
                    push: PushInfo(
                        observedPushAt: UIClock.ago(2 * UIClock.day),
                        observedPushOID: UIFixtures.otherSHA,
                        originMovedSince: true,
                        source: .reflogObserved,
                        hasUpstream: true,
                        aheadOfLastKnownRemote: 0,
                        remoteRefObservedAt: UIClock.ago(UIClock.hour)
                    )
                )
            ])
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 20
    static let prDraft = UIState(
        id: "pr-draft",
        title: "Branch with a draft PR",
        planReference: "PRStatus.draft",
        entries: [
            ("prDraft", Strings.prDraft)
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(branches: [
                UIFixtures.branch(
                    "onboarding-copy",
                    upstream: Upstream(ref: "origin/onboarding-copy", remote: "origin"),
                    pr: UIFixtures.pr(101, isDraft: true, headRefName: "onboarding-copy"),
                    prStatus: .draft,
                    push: PushInfo(
                        observedPushAt: UIClock.ago(3 * UIClock.hour),
                        observedPushOID: UIFixtures.tipSHA,
                        source: .reflogObserved,
                        hasUpstream: true,
                        aheadOfLastKnownRemote: 0
                    )
                )
            ])
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 21
    static let prOpen = UIState(
        id: "pr-open",
        title: "Branch with an open PR",
        planReference: "PRStatus.open",
        entries: [
            ("prOpen", Strings.prOpen),
            ("openPRActionLabel", Strings.openPRActionLabel),
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(branches: [
                UIFixtures.branch(
                    "search-filters",
                    upstream: Upstream(ref: "origin/search-filters", remote: "origin"),
                    pr: UIFixtures.pr(102, headRefName: "search-filters"),
                    prStatus: .open,
                    push: PushInfo(
                        observedPushAt: UIClock.ago(2 * UIClock.day),
                        observedPushOID: UIFixtures.tipSHA,
                        source: .reflogObserved,
                        hasUpstream: true,
                        aheadOfLastKnownRemote: 0
                    )
                )
            ])
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 22
    static let prChangesRequested = UIState(
        id: "pr-changes-requested",
        title: "Branch whose PR has changes requested",
        planReference: "PRStatus.changesRequested",
        entries: [
            ("prChangesRequested", Strings.prChangesRequested)
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(branches: [
                UIFixtures.branch(
                    "nav-redesign",
                    upstream: Upstream(ref: "origin/nav-redesign", remote: "origin"),
                    pr: UIFixtures.pr(
                        103,
                        reviewDecision: "CHANGES_REQUESTED",
                        headRefName: "nav-redesign"
                    ),
                    prStatus: .changesRequested,
                    push: PushInfo(
                        observedPushAt: UIClock.ago(6 * UIClock.hour),
                        observedPushOID: UIFixtures.tipSHA,
                        source: .reflogObserved,
                        hasUpstream: true,
                        aheadOfLastKnownRemote: 0
                    )
                )
            ])
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 23
    static let prApproved = UIState(
        id: "pr-approved",
        title: "Branch whose PR is approved",
        planReference: "PRStatus.approved",
        entries: [
            ("prApproved", Strings.prApproved)
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(branches: [
                UIFixtures.branch(
                    "weekly-digest",
                    upstream: Upstream(ref: "origin/weekly-digest", remote: "origin"),
                    pr: UIFixtures.pr(104, reviewDecision: "APPROVED", headRefName: "weekly-digest"),
                    prStatus: .approved,
                    push: PushInfo(
                        observedPushAt: UIClock.ago(UIClock.hour),
                        observedPushOID: UIFixtures.tipSHA,
                        source: .reflogObserved,
                        hasUpstream: true,
                        aheadOfLastKnownRemote: 0
                    )
                )
            ])
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 24
    static let mergedGroup = UIState(
        id: "merged-group",
        title: "Merged PR with no later local commits",
        planReference: "§3 Merged group; PRStatus.merged",
        entries: [
            ("mergedGroupHeading", Strings.mergedGroupHeading),
            ("prMerged", Strings.prMerged),
            ("mergedDetail", Strings.mergedDetail(baseRefName: "main")),
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(branches: [
                UIFixtures.branch(
                    "status-line-fix",
                    upstream: Upstream(ref: "origin/status-line-fix", remote: "origin"),
                    pr: UIFixtures.pr(
                        105,
                        state: "MERGED",
                        mergedAt: UIClock.ago(UIClock.day),
                        headRefName: "status-line-fix"
                    ),
                    prStatus: .merged,
                    push: PushInfo(
                        observedPushAt: UIClock.ago(UIClock.day),
                        observedPushOID: UIFixtures.tipSHA,
                        source: .reflogObserved,
                        hasUpstream: true,
                        aheadOfLastKnownRemote: 0
                    ),
                    group: .merged
                )
            ])
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 25
    static let closedUnmergedGroup = UIState(
        id: "closed-unmerged-group",
        title: "PR closed without merging",
        planReference: "§3 Closed without merging group; PRStatus.closed",
        entries: [
            ("closedUnmergedGroupHeading", Strings.closedUnmergedGroupHeading),
            ("prClosed", Strings.prClosed),
            ("closedUnmergedDetail", Strings.closedUnmergedDetail),
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(branches: [
                UIFixtures.branch(
                    "abandoned-experiment",
                    upstream: Upstream(ref: "origin/abandoned-experiment", remote: "origin"),
                    pr: UIFixtures.pr(106, state: "CLOSED", headRefName: "abandoned-experiment"),
                    prStatus: .closed,
                    push: PushInfo(
                        observedPushAt: UIClock.ago(9 * UIClock.day),
                        observedPushOID: UIFixtures.tipSHA,
                        source: .reflogObserved,
                        hasUpstream: true,
                        aheadOfLastKnownRemote: 0
                    ),
                    group: .closedUnmerged
                )
            ])
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 26
    static let openPRsNotOnThisMac = UIState(
        id: "open-prs-not-on-this-mac",
        title: "Your open PR whose branch is not on this Mac",
        planReference: "§3 and §5a item 3: Open PRs not on this Mac group",
        entries: [
            ("openElsewhereGroupHeading", Strings.openElsewhereGroupHeading),
            ("openElsewhereGroupNote", Strings.openElsewhereGroupNote),
            ("prRowTitle", Strings.prRowTitle(number: 128, branchName: "hotfix-from-laptop")),
            (
                "prRowAccessibilityLabel",
                Strings.prRowAccessibilityLabel(
                    number: 128,
                    branchName: "hotfix-from-laptop",
                    prPill: Strings.prOpen
                )
            ),
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(
                branches: [UIFixtures.branch("main", prStatus: .none)],
                openPRsNotOnThisMac: [
                    UIFixtures.pr(128, headRefName: "hotfix-from-laptop", headRefOid: UIFixtures.otherSHA)
                ]
            )
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 27
    static let upstreamMissing = UIState(
        id: "upstream-missing",
        title: "The branch this one tracked is gone from last-known origin",
        planReference: "§3 vocabulary: upstream gone",
        entries: [
            ("upstreamMissing", Strings.upstreamMissing)
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(branches: [
                UIFixtures.branch(
                    "merged-last-week",
                    upstream: Upstream(ref: "origin/merged-last-week", remote: "origin", isGone: true),
                    prStatus: .merged,
                    push: PushInfo(
                        observedPushAt: UIClock.ago(8 * UIClock.day),
                        observedPushOID: UIFixtures.tipSHA,
                        source: .reflogObserved,
                        hasUpstream: true,
                        upstreamGone: true
                    ),
                    group: .merged
                )
            ])
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 28
    static let aheadOfLastKnownOrigin = UIState(
        id: "ahead-of-last-known-origin",
        title: "Local commits that last-known origin has not seen",
        planReference: "§3: ahead renders as \"2 ahead of last-known origin\"",
        entries: [
            ("ahead", Strings.ahead(2)),
            ("aheadTooltip", Strings.aheadTooltip(remoteObservedAt: UIClock.ago(3 * UIClock.hour), now: UIClock.now)),
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(branches: [
                UIFixtures.branch(
                    "worktree-docs",
                    upstream: Upstream(ref: "origin/worktree-docs", remote: "origin", ahead: 2, behind: 1),
                    prStatus: .open,
                    push: PushInfo(
                        observedPushAt: UIClock.ago(UIClock.day),
                        observedPushOID: UIFixtures.otherSHA,
                        source: .reflogObserved,
                        hasUpstream: true,
                        aheadOfLastKnownRemote: 2,
                        remoteRefObservedAt: UIClock.ago(3 * UIClock.hour)
                    )
                )
            ])
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 29
    static let inSync = UIState(
        id: "in-sync",
        title: "Nothing local that last-known origin does not have",
        planReference: "§3: \"In sync\" vs \"no upstream\" decided by upstream:short",
        entries: [
            ("inSync", Strings.inSync)
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(branches: [
                UIFixtures.branch(
                    "main",
                    upstream: Upstream(ref: "origin/main", remote: "origin"),
                    prStatus: .none,
                    push: PushInfo(
                        observedPushAt: UIClock.ago(2 * UIClock.day),
                        observedPushOID: UIFixtures.tipSHA,
                        source: .reflogObserved,
                        hasUpstream: true,
                        aheadOfLastKnownRemote: 0,
                        remoteRefObservedAt: UIClock.ago(2 * UIClock.day)
                    )
                )
            ])
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 30
    static let detachedWorktree = UIState(
        id: "detached-worktree",
        title: "A worktree sitting on a commit with no branch",
        planReference: "§3 vocabulary: \"Worktree at commit abc1234 (no branch)\"",
        entries: [
            ("detachedWorktree", Strings.detachedWorktree(shortSHA: "abc1234"))
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(
                worktrees: [
                    Worktree(
                        path: "/Users/tester/demo",
                        headSHA: UIFixtures.tipSHA,
                        branch: "refs/heads/main",
                        isPrimary: true
                    ),
                    Worktree(path: "/Users/tester/demo-review", headSHA: "abc1234def", branch: nil),
                ],
                branches: [UIFixtures.branch("main", prStatus: .none)]
            )
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 31
    static let worktreeCheckout = UIState(
        id: "worktree-checkout",
        title: "A branch checked out in its own worktree folder",
        planReference: "§5a item 3: worktree marker leading",
        entries: [
            ("worktreeMarker", Strings.worktreeMarker(folderName: "demo-agents-2"))
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(
                worktrees: [
                    Worktree(
                        path: "/Users/tester/demo",
                        headSHA: UIFixtures.tipSHA,
                        branch: "refs/heads/main",
                        isPrimary: true
                    ),
                    Worktree(
                        path: "/Users/tester/demo-agents-2",
                        headSHA: UIFixtures.otherSHA,
                        branch: "refs/heads/agent-task-2"
                    ),
                ],
                branches: [
                    UIFixtures.branch("main", prStatus: .none),
                    UIFixtures.branch(
                        "agent-task-2",
                        tipSHA: UIFixtures.otherSHA,
                        worktreePath: "/Users/tester/demo-agents-2",
                        isCheckedOutInPrimary: false,
                        prStatus: .notChecked
                    ),
                ]
            )
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 32
    static let refreshRunning = UIState(
        id: "refresh-running",
        title: "A refresh is in flight",
        planReference: "§5 RefreshState.running(completed, total)",
        entries: [
            ("refreshRunning", Strings.refreshRunning(completed: 3, total: 12))
        ],
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(branches: [UIFixtures.branch("main", prStatus: .none)])
        ]),
        refreshState: .running(completed: 3, total: 12)
    )

    // 33
    static let hiddenRepo = UIState(
        id: "hidden-repo",
        title: "A repo the user hid, and the footer control that brings it back",
        planReference: "§8 packet 4.2: per-row Hide, the Show hidden (N) toggle, the Hidden marker",
        entries: [
            ("hideRepoActionLabel", Strings.hideRepoActionLabel),
            ("unhideRepoActionLabel", Strings.unhideRepoActionLabel),
            ("showHiddenToggleLabel", Strings.showHiddenToggleLabel(count: 1)),
            ("hiddenRepoMarker", Strings.hiddenRepoMarker),
        ],
        // Two repos so the second can be the hidden one. Hiding is a choice a person makes rather
        // than a state a `Snapshot` can be found in, so which repo is hidden — and whether "Show
        // hidden" is on — lives outside the frozen envelope: the shell's `BRANCHBAR_PREVIEW_HIDDEN`
        // hides this fixture's last repo, and `=shown` is the on half of the toggle.
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo("demo", branches: [UIFixtures.branch("main", prStatus: .none)]),
            UIFixtures.repo("archived-experiment", branches: [
                UIFixtures.branch("main", prStatus: .none)
            ]),
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )

    // 34
    static let launchAtLoginNeedsApproval = UIState(
        id: "launch-at-login-needs-approval",
        title: "The login-item toggle was flipped and macOS has not allowed it yet",
        planReference: "§3, §5b: launch at login through SMAppService with a LaunchAgent fallback",
        entries: [
            ("launchAtLoginNeedsApproval", Strings.launchAtLoginNeedsApproval),
            ("launchAtLoginTranslocated", Strings.launchAtLoginTranslocated),
            ("launchAtLoginUnbundled", Strings.launchAtLoginUnbundled),
            ("launchAtLoginNotInApplications", Strings.launchAtLoginNotInApplications),
            ("launchAtLoginFailed", Strings.launchAtLoginFailed),
        ],
        // The five outcomes are facts about this Mac — where the bundle sits, what `SMAppService`
        // answered — not about the `Snapshot`, so the fixture carries an ordinary populated list
        // and the sentence beside the toggle is what the state is named for.
        snapshot: UIFixtures.snapshot([
            UIFixtures.repo(branches: [UIFixtures.branch("main", prStatus: .none)])
        ]),
        refreshState: .idle(lastRefreshedAt: UIClock.ago(12))
    )
}

// MARK: - Tests

@Suite("Packet 4.0 — the UI string contract")
struct StringsTests {

    /// Every reason a repo's PR status can be unavailable gives the user something to do about it.
    /// PLAN.md §5a item 1 and §7's `unavailableReasonCopyNamesOneActionPerReason`.
    @Test("unavailableReasonCopyNamesOneActionPerReason")
    func unavailableReasonCopyNamesOneActionPerReason() {
        for reason in PRUnavailableReason.allReasonsForContractTesting {
            let failure = Strings.unavailable(reason: reason)
            #expect(!failure.title.isEmpty, "\(reason) has no title")
            #expect(!failure.message.isEmpty, "\(reason) has no message")
            let label = failure.action?.label ?? ""
            #expect(failure.action != nil, "\(reason) offers the user no action")
            #expect(label.isEmpty == false, "\(reason) has an action with no label")
        }

        // The two reasons a user can actually fix get the specific action, not a generic Refresh.
        #expect(Strings.unavailable(reason: .ghNotInstalled).action?.kind == .openURL)
        #expect(
            Strings.unavailable(reason: .ghNotAuthenticated(host: "github.com")).action?.kind
                == .openTerminalWithGhAuthLogin
        )
        #expect(
            Strings.unavailable(reason: .ghNotAuthenticated(host: "github.nytimes.com")).action?.payload
                == "gh auth login --hostname github.nytimes.com"
        )
    }

    /// A string nothing renders is a string nobody reviewed. The state table above maps every state
    /// to the members it uses; this reads the declarations straight out of `Strings.swift` so a new
    /// `public static` that no state claims fails here. PLAN.md §7
    /// `everyStringsEntryIsReachableFromSomeState`.
    @Test("everyStringsEntryIsReachableFromSomeState")
    func everyStringsEntryIsReachableFromSomeState() throws {
        let declared = try StringsSource.declaredMembers()
        #expect(!declared.isEmpty, "no public members parsed out of Strings.swift")

        var reached: Set<String> = []
        for state in UIStates.all { reached.formUnion(state.members) }

        let unreachable = declared.filter { !reached.contains($0) }.sorted()
        #expect(
            unreachable.isEmpty,
            "Strings members no state in the table renders: \(unreachable)"
        )

        let unknown = reached.filter { !declared.contains($0) }.sorted()
        #expect(unknown.isEmpty, "state table names members Strings.swift does not declare: \(unknown)")
    }

    /// PLAN.md §3: the fallback is a different fact, not a quieter push claim. It may not say the
    /// branch was pushed, and it may not imply GitHub was consulted. §7
    /// `fallbackLabelDoesNotClaimGitHubObservedTheBranch`.
    @Test("fallbackLabelDoesNotClaimGitHubObservedTheBranch")
    func fallbackLabelDoesNotClaimGitHubObservedTheBranch() {
        let label = Strings.pushUnknown(tipCommitDate: UIClock.ago(2 * UIClock.day), now: UIClock.now)

        #expect(label == "Last push unknown · newest commit dated 2 days ago")
        for forbidden in ["github", "seen", "pushed"] {
            #expect(
                !label.lowercased().contains(forbidden),
                "the fallback label must not contain \"\(forbidden)\": \(label)"
            )
        }
    }

    /// The observed-push label and the fallback describe two different facts, so they may not read
    /// alike. PLAN.md §3 also forbids "You pushed": the reflog records what this clone observed and
    /// says nothing about the person or the other machines.
    @Test("pushedLabelWordsDifferForYouPushedVsTipCommitDate")
    func pushedLabelWordsDifferForYouPushedVsTipCommitDate() {
        let instant = UIClock.ago(2 * UIClock.day)
        let observed = Strings.pushed(reflogAt: instant, now: UIClock.now)
        let fallback = Strings.pushUnknown(tipCommitDate: instant, now: UIClock.now)

        #expect(observed == "Pushed from this Mac 2 days ago")
        #expect(observed != fallback)
        #expect(observed.contains("from this Mac"))
        #expect(!observed.lowercased().contains("you pushed"))
        #expect(fallback.hasPrefix("Last push unknown"))
        #expect(!fallback.contains("from this Mac"))

        let moved = Strings.pushed(reflogAt: instant, now: UIClock.now, originMovedSince: true)
        #expect(moved == "Pushed from this Mac 2 days ago (origin has moved since)")
        #expect(moved.hasSuffix(Strings.originMovedSince))
    }

    /// A blank pill is a row that says nothing. All ten `PRStatus` cases, including the three that
    /// exist only to keep BranchBar honest (`none`, `notLoaded`, `notChecked`).
    @Test("prPillTextNeverEmptyForAnyStatus")
    func prPillTextNeverEmptyForAnyStatus() {
        var seen: Set<String> = []
        for status in PRStatus.allCases {
            let text = Strings.prPill(for: status)
            #expect(!text.isEmpty, "\(status) has no pill text")
            #expect(seen.insert(text).inserted, "\(status) reuses the pill text \"\(text)\"")
        }
        #expect(PRStatus.allCases.count == 10)
        #expect(Strings.prPill(for: .notLoaded) == "PR status loads when expanded")
        #expect(Strings.prPill(for: .notChecked) == "PR status not checked yet")
    }

    /// Relative time is arithmetic on the two dates handed in, never `Date()` and never a locale.
    /// Tests own the clock, so the fixtures under `Fixtures/states/` stay byte-stable.
    @Test("relativeTimeIsDeterministicGivenNow")
    func relativeTimeIsDeterministicGivenNow() {
        let now = UIClock.now

        #expect(Strings.relative(now, now: now) == "just now")
        #expect(Strings.relative(now.addingTimeInterval(-12), now: now) == "12 s ago")
        #expect(Strings.relative(now.addingTimeInterval(-60), now: now) == "1 minute ago")
        #expect(Strings.relative(now.addingTimeInterval(-2 * 60), now: now) == "2 minutes ago")
        #expect(Strings.relative(now.addingTimeInterval(-UIClock.hour), now: now) == "1 hour ago")
        #expect(Strings.relative(now.addingTimeInterval(-3 * UIClock.hour), now: now) == "3 hours ago")
        #expect(Strings.relative(now.addingTimeInterval(-UIClock.day), now: now) == "1 day ago")
        #expect(Strings.relative(now.addingTimeInterval(-2 * UIClock.day), now: now) == "2 days ago")
        #expect(Strings.relative(now.addingTimeInterval(-9 * UIClock.day), now: now) == "1 week ago")
        #expect(Strings.relative(now.addingTimeInterval(-60 * UIClock.day), now: now) == "2 months ago")
        #expect(Strings.relative(now.addingTimeInterval(-800 * UIClock.day), now: now) == "2 years ago")

        // A clock that has not moved gives the same answer every time it is asked.
        let sample = now.addingTimeInterval(-2 * UIClock.day)
        #expect(Strings.relative(sample, now: now) == Strings.relative(sample, now: now))
        // Moving `now` moves the answer; nothing here reads the system clock.
        #expect(Strings.relative(sample, now: now.addingTimeInterval(5 * UIClock.day)) == "1 week ago")
        // A date in the future is not a negative age.
        #expect(Strings.relative(now.addingTimeInterval(60), now: now) == "just now")

        #expect(Strings.updated(at: now.addingTimeInterval(-12), now: now) == "Updated 12 s ago")
        #expect(Strings.updated(at: nil, now: now) == "Not updated yet")
    }

    /// PLAN.md §3: "Vocabulary — workshop words only (repo, branch, worktree, PR, push)." The words
    /// below are the ones the NYT session never teaches, so a PM would have to guess at them.
    ///
    /// One exception, and only one: "Upstream missing from last-known origin" is locked verbatim by
    /// PLAN.md §3, which chose it over "deleted on GitHub" because the app never fetches. The
    /// exception set is asserted to be exactly that string so it cannot quietly grow.
    @Test("noEngineeringVocabularyInUserStrings")
    func noEngineeringVocabularyInUserStrings() {
        let bannedWords = ["detached", "HEAD", "upstream", "ref", "SHA", "reflog", "stderr"]
        let bannedPhrases = ["exit code"]

        let lockedExceptions = [Strings.upstreamMissing]
        #expect(lockedExceptions == ["Upstream missing from last-known origin"])

        var corpus: [String] = []
        for state in UIStates.all { corpus.append(contentsOf: state.strings) }
        // Every arm of every exhaustive switch, whether or not a state row happens to name it.
        corpus.append(contentsOf: PRStatus.allCases.map(Strings.prPill(for:)))
        corpus.append(contentsOf: RepoError.Stage.allCases.map { Strings.repoErrorNotice(stage: $0) })
        for reason in PRUnavailableReason.allReasonsForContractTesting {
            let failure = Strings.unavailable(reason: reason)
            corpus.append(contentsOf: [failure.title, failure.message, failure.action?.label ?? ""])
        }

        var offenders: [String] = []
        for original in corpus {
            var text = original
            for exception in lockedExceptions { text = text.replacingOccurrences(of: exception, with: " ") }
            for word in bannedWords where Self.containsWord(word, in: text) {
                offenders.append("\"\(original)\" uses \"\(word)\"")
            }
            for phrase in bannedPhrases where text.range(of: phrase, options: .caseInsensitive) != nil {
                offenders.append("\"\(original)\" uses \"\(phrase)\"")
            }
        }

        #expect(offenders.isEmpty, "engineering vocabulary in user-facing copy: \(offenders)")

        // The words the workshop does teach stay allowed; this pins the intent of the rule.
        for allowed in ["worktree", "branch", "PR", "repo", "push"] {
            #expect(!bannedWords.contains(allowed))
        }
    }

    /// PLAN.md §5a is a document Hannah reads at Gate 4.0. A state with no row in it is a state
    /// nobody signed off on.
    @Test("uiContractHasARowForEveryState")
    func uiContractHasARowForEveryState() throws {
        let contract = RepoRoot.url.appendingPathComponent("docs/UI-CONTRACT.md")
        let text = try String(contentsOf: contract, encoding: .utf8)

        let missing = UIStates.all.map(\.id).filter { !text.contains("`\($0)`") }
        #expect(missing.isEmpty, "docs/UI-CONTRACT.md has no state-table row for: \(missing)")

        for member in try StringsSource.declaredMembers() {
            #expect(
                text.contains("`\(member)`"),
                "docs/UI-CONTRACT.md string table is missing `\(member)`; run `make doc-strings`"
            )
        }
    }

    /// One `StateFixture` per state row, encoded with the real `JSONEncoder` so a change to a frozen
    /// type breaks here rather than at Gate 4. Rewrites a file only when its bytes change, so the
    /// test is idempotent and a clean tree stays clean.
    @Test("stateFixturesAreRecordedForEveryState")
    func stateFixturesAreRecordedForEveryState() throws {
        let directory = Fixture.directory.appendingPathComponent("states", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let decoder = JSONDecoder()

        var ids: Set<String> = []
        for state in UIStates.all {
            #expect(ids.insert(state.id).inserted, "duplicate state id \(state.id)")

            let fixture = state.fixture
            let data = try encoder.encode(fixture)
            let url = directory.appendingPathComponent("\(state.id).json")

            if FileManager.default.contents(atPath: url.path) != data {
                try data.write(to: url, options: .atomic)
            }

            let reloaded = try decoder.decode(StateFixture.self, from: try Data(contentsOf: url))
            #expect(reloaded == fixture, "\(state.id).json does not round-trip")
            #expect(!reloaded.expectedStrings.isEmpty, "\(state.id) contracts no strings")
        }

        #expect(ids.count == UIStates.all.count)
    }

    /// Case-insensitive whole-word match, so "Refresh" is not read as "ref" and "ahead" is not read
    /// as "HEAD".
    static func containsWord(_ word: String, in text: String) -> Bool {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}

// MARK: - Reading Strings.swift off disk

/// `Strings` is an enum of statics, so there is no runtime mirror of its members. The reachability
/// and documentation tests read the declarations out of the source file, the same way `GuardTests`
/// reads imports.
enum StringsSource {
    static let url = RepoRoot.url.appendingPathComponent("Sources/BranchBarCore/Strings.swift")

    /// Base names of every `public static let` / `var` / `func` in `Strings.swift`.
    static func declaredMembers() throws -> Set<String> {
        let source = try String(contentsOf: url, encoding: .utf8)
        let pattern = #"^\s*public static (?:let|var|func)\s+([A-Za-z_][A-Za-z0-9_]*)"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return Set(
            regex.matches(in: source, range: range).compactMap { match in
                Range(match.range(at: 1), in: source).map { String(source[$0]) }
            }
        )
    }
}

/// `PRUnavailableReason` carries an associated value, so it cannot be `CaseIterable`. This list is
/// the exhaustive stand-in; the `switch` in `Strings.unavailable(reason:)` is what actually keeps
/// the compiler honest about new cases.
extension PRUnavailableReason {
    static let allReasonsForContractTesting: [PRUnavailableReason] = [
        .ghNotInstalled,
        .ghNotAuthenticated(host: "github.com"),
        .noRemote,
        .notGitHubRemote,
        .rateLimited,
        .commandFailed,
    ]
}
