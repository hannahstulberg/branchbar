import Foundation
import Testing

@testable import BranchBarCore

// Packet 2.2. `SnapshotPresenter` is the only place a user-facing string is produced, so this file
// is where the wording rules PLAN.md §3 locks become assertions over values rather than screenshot
// reviews. Packet 4.0 recorded one `StateFixture` per row of the §5a state table under
// `Fixtures/states/`; each carries the exact argument list of `present` plus the literal strings
// that state is contracted to show, and `everyStateFixtureRendersItsExpectedStrings` replays all 32.

// MARK: - Walking a rendered SnapshotVM

extension SnapshotVM {
    /// Every string the view models carry, including action labels and payloads, so a fixture
    /// assertion does not have to know which field a given literal landed in.
    var renderedStrings: [String] {
        var out: [String] = [footer.updatedLabel, footer.version]
        out.append(contentsOf: footer.scanRoots)
        out.append(contentsOf: footer.toolNotice?.renderedStrings ?? [])

        if let empty = emptyState {
            out.append(contentsOf: [empty.title, empty.message, empty.action.label, empty.action.payload ?? ""])
            // The empty state carries the not-scanned notice when there is no section to hang it
            // on (codex MAJOR 3).
            out.append(contentsOf: empty.notice?.renderedStrings ?? [])
        }

        for section in sections {
            out.append(section.title)
            out.append(contentsOf: section.prNotice?.renderedStrings ?? [])
            out.append(contentsOf: section.notScannedNotice?.renderedStrings ?? [])
            for row in section.active + section.merged + section.closedUnmerged {
                out.append(contentsOf: row.renderedStrings)
            }
            for row in section.openElsewhere {
                out.append(contentsOf: [row.title, row.prPill.text, row.url, row.accessibilityLabel])
            }
        }
        return out.filter { !$0.isEmpty }
    }

    /// A literal is rendered when some field contains it; notices join several `Strings` members
    /// into one field, so this is a substring match rather than equality.
    func renders(_ literal: String) -> Bool {
        renderedStrings.contains { $0.contains(literal) }
    }
}

extension NoticeVM {
    var renderedStrings: [String] { [text, action?.label ?? "", action?.payload ?? ""] }
}

extension BranchRowVM {
    var renderedStrings: [String] {
        [
            title,
            worktreeMarker ?? "",
            prPill?.text ?? "",
            prURL ?? "",
            pushLabel,
            pushTooltip,
            aheadLabel ?? "",
            primaryAction.label,
            primaryAction.payload ?? "",
            accessibilityLabel,
        ]
    }
}

// MARK: - The recorded state fixtures

/// Fixture filename stems under `Fixtures/states/`, read off disk so a state added to packet 4.0's
/// table is replayed here without editing this file.
let stateFixtureIDs: [String] = {
    let directory = Fixture.directory.appendingPathComponent("states", isDirectory: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(".json".count)) }.sorted()
}()

func loadStateFixture(_ id: String) throws -> StateFixture {
    let url = Fixture.directory
        .appendingPathComponent("states", isDirectory: true)
        .appendingPathComponent("\(id).json")
    return try JSONDecoder().decode(StateFixture.self, from: Data(contentsOf: url))
}

@Suite("Packet 2.2 — SnapshotPresenter renders a Snapshot into a SnapshotVM")
struct SnapshotPresenterTests {

    // MARK: - What the frozen SnapshotVM cannot carry

    /// Literals §5a asks for that the view models frozen in packet 1.1 give no field for. Every one
    /// is a fixed control or heading label that does not vary with the `Snapshot`: a group heading
    /// (the view renders it above the matching non-empty array), the disclosure control (driven by
    /// `RepoSectionVM.isCollapsed`), a secondary row action (`BranchRowVM` holds only
    /// `primaryAction`), a footer menu item, or the menu bar item itself. `ViewModels.swift` says
    /// "the views render these and nothing else", which these contradict; the orchestrator owns the
    /// follow-up. The set is asserted whole below so it cannot quietly grow.
    static let viewOwnedChrome: Set<String> = [
        Strings.menuBarAccessibilityLabel,
        Strings.rescanActionLabel,
        Strings.scanRootsHeading,
        Strings.removeScanRootActionLabel,
        Strings.activeGroupHeading,
        Strings.openElsewhereGroupHeading,
        Strings.openElsewhereGroupNote,
        Strings.closedUnmergedGroupHeading,
        Strings.expandSectionActionLabel,
        Strings.collapseSectionActionLabel,
        Strings.revealInFinderActionLabel,
        Strings.copyPathActionLabel,
        Strings.openPRActionLabel,
        Strings.openInTerminalActionLabel,
        Strings.refreshPRsNowActionLabel,
        Strings.launchAtLoginToggleLabel,
        Strings.quitActionLabel,
        // Packet 4.3 moved the shell's own copy into `Strings` (DECISION-LOG: packet 4.2 parked it
        // in `Sources/BranchBar/ShellStrings.swift` because this list was frozen). Every one is the
        // same kind of thing as the rest: a fixed control label or a sentence about this Mac, with
        // no view-model field and no `Snapshot` that can produce it.
        Strings.hideRepoActionLabel,
        Strings.unhideRepoActionLabel,
        Strings.showHiddenToggleLabel(count: 1),
        Strings.hiddenRepoMarker,
        Strings.launchAtLoginNeedsApproval,
        Strings.launchAtLoginTranslocated,
        Strings.launchAtLoginUnbundled,
        Strings.launchAtLoginNotInApplications,
        Strings.launchAtLoginFailed,
        Strings.ghSignInScriptBanner,
        Strings.filesAndFoldersSettingsURL,
        // F11 moved these two out of `Sources/BranchBar/Views/FooterView.swift`, where a shell
        // packet had parked them because this list was frozen. Same kind of thing as the rest: a
        // fixed control label and the sentence VoiceOver reads for it, with no view-model field
        // and no `Snapshot` that can produce either.
        Strings.cancelRefreshActionLabel,
        Strings.cancelRefreshAccessibilityLabel,
    ]

    /// Literals a fixture contracts that its own recorded `Snapshot` cannot produce. These are not
    /// chrome: the presenter would render them from the right data, and the data is not in the file.
    static let fixtureDataGaps: [String: Set<String>] = [
        // `("relative", …)` is in the state table so `relative` is reachable for
        // `everyStringsEntryIsReachableFromSomeState`; a never-pushed branch has no row slot for a
        // bare age (the only relative strings on a row live inside `pushed` / `pushUnknown`).
        "single-branch-no-pr-never-pushed": [Strings.relative(UIClock.ago(2 * UIClock.day), now: UIClock.now)],
        // The state table names four `RepoError.Stage` literals; the recorded snapshot carries two
        // errors, stages `.branches` and `.worktrees`.
        "repo-failed": [Strings.repoRemotesFailed, Strings.repoPushHistoryFailed],
    ]

    /// The `StateFixture` envelope froze six arguments and predates editor availability, which is a
    /// property of the Mac rather than of the snapshot. One state's condition lives outside the
    /// envelope, and its own id names it.
    static func presenter(forState id: String) -> SnapshotPresenter {
        id == "cursor-not-installed"
            ? SnapshotPresenter(editors: EditorAvailability(cursor: false, vsCode: true))
            : SnapshotPresenter()
    }

    // MARK: - The 32 recorded states

    @Test("everyStateFixtureRendersItsExpectedStrings", arguments: stateFixtureIDs)
    func everyStateFixtureRendersItsExpectedStrings(id: String) throws {
        let fixture = try loadStateFixture(id)
        #expect(fixture.id == id, "\(id).json carries the id \(fixture.id)")

        let vm = Self.presenter(forState: id).present(
            fixture.snapshot,
            refreshState: fixture.refreshState,
            collapsedRepoIDs: Set(fixture.collapsedRepoIDs),
            scanResult: fixture.scanResult,
            appVersion: fixture.appVersion,
            now: fixture.now
        )

        let exempt = Self.viewOwnedChrome.union(Self.fixtureDataGaps[id] ?? [])
        for expected in fixture.expectedStrings where !exempt.contains(expected) {
            #expect(vm.renders(expected), "\(id) does not render \"\(expected)\"")
        }

        // A state that renders nothing at all is a state the presenter forgot.
        #expect(!vm.renderedStrings.isEmpty, "\(id) rendered no strings")
    }

    /// Both exemption sets are frozen here so a presenter that stops rendering something cannot be
    /// made green by widening them.
    @Test("everyFixtureStringIsRenderedOrOnAFrozenExemptionList")
    func everyFixtureStringIsRenderedOrOnAFrozenExemptionList() throws {
        // 28 until F11 added the Cancel button's label and its accessibility label.
        #expect(Self.viewOwnedChrome.count == 30)
        #expect(Self.fixtureDataGaps.keys.sorted() == ["repo-failed", "single-branch-no-pr-never-pushed"])
        // 32 + 2 until the codex pre-ship review, which added one state per finding that named a
        // state the contract had no row for: `zero-repos-documents-denied` (MAJOR 3),
        // `origin-not-fetched` (MAJOR 7), and `behind-only` (MAJOR 5). The fix wave added
        // `git-not-found` (REVIEW CR-04).
        // codex round 2 added four: `gh-forbidden` and `gh-command-failed` (MAJOR 7),
        // `non-origin-upstream` and `untracked-remote-branch` (MAJOR 5). `stale-rows-idle` is the
        // idle half of the stale-row warning.
        // F11 added `non-origin-in-sync` and `non-origin-upstream-missing`: the two other things a
        // fork-tracking row can say, both of which named origin before codex round 2's MAJOR 5.
        #expect(
            stateFixtureIDs.count == 45,
            "packet 4.0 recorded 32, packet 4.3 added 2, the codex fixes added 3, CR-04 added 1, codex round 2 added 5, F11 added 2; found \(stateFixtureIDs.count)")

        // Nothing is exempted that no fixture actually asks for.
        var contracted: Set<String> = []
        for id in stateFixtureIDs {
            contracted.formUnion(try loadStateFixture(id).expectedStrings)
        }
        let unused = Self.viewOwnedChrome.subtracting(contracted).sorted()
        #expect(unused.isEmpty, "exempted strings no state contracts: \(unused)")
    }

    // MARK: - Push wording (PLAN.md §3)

    @Test("pushedLabelWordsDifferForYouPushedVsTipCommitDate")
    func pushedLabelWordsDifferForYouPushedVsTipCommitDate() throws {
        let observed = try Self.onlyRow(of: Self.singleBranchSnapshot(push: PushInfo(
            observedPushAt: UIClock.ago(2 * UIClock.day),
            observedPushOID: UIFixtures.tipSHA,
            source: .reflogObserved,
            hasUpstream: true,
            aheadOfLastKnownRemote: 0
        )))
        let fallback = try Self.onlyRow(of: Self.singleBranchSnapshot(push: PushInfo(
            source: .tipCommitDate,
            hasUpstream: true,
            aheadOfLastKnownRemote: 0
        )))

        #expect(observed.pushLabel == "Pushed from this Mac 2 days ago")
        #expect(observed.pushLabel != fallback.pushLabel)
        #expect(fallback.pushLabel.contains("Last push unknown"))
        #expect(!fallback.pushLabel.contains("from this Mac"))
        #expect(!observed.pushLabel.lowercased().contains("you pushed"))
        #expect(observed.pushTooltip == Strings.pushedTooltip)
        #expect(fallback.pushTooltip == Strings.pushUnknownTooltip)
    }

    /// The invariant the name states — no upstream never renders as a count — is unchanged. The
    /// label it renders instead is not: "Never pushed" was a claim the absence of tracking never
    /// proved, since `git push origin <branch>` without `-u` pushes and configures nothing
    /// (codex MAJOR 6).
    @Test("noUpstreamRendersNeverPushedNotZeroCommits")
    func noUpstreamRendersNeverPushedNotZeroCommits() throws {
        let row = try Self.onlyRow(of: Self.singleBranchSnapshot(upstream: nil, push: PushInfo(source: .none)))

        #expect(row.pushLabel == Strings.noTrackedRemoteBranch)
        #expect(row.pushLabel != "Never pushed")
        #expect(row.aheadLabel?.contains(Strings.noUpstream) == true)
        #expect(row.pushTooltip == Strings.noTrackedRemoteBranchTooltip)
        for forbidden in ["0 ahead", "0 commits", "In sync"] {
            #expect(!(row.aheadLabel ?? "").contains(forbidden), "untracked row claims \"\(forbidden)\"")
            #expect(!row.pushLabel.contains(forbidden))
        }
        // The tooltip says what BranchBar did, never what the branch did.
        #expect(!row.pushTooltip.contains("nothing has gone out"))

        // A branch with no upstream whose `origin/<branch>` reflog did hold a push says so.
        let observed = try Self.onlyRow(of: Self.singleBranchSnapshot(
            upstream: nil,
            push: PushInfo(
                observedPushAt: UIClock.ago(2 * UIClock.day),
                observedPushOID: UIFixtures.tipSHA,
                source: .reflogObserved,
                hasUpstream: false)))
        #expect(observed.pushLabel == "Pushed from this Mac 2 days ago")
        #expect(observed.aheadLabel?.contains(Strings.noUpstream) == true,
                "it still tracks nothing, and the tertiary line still says so")
    }

    /// codex MAJOR 5. `behind` is parsed and never shown, but "In sync with last-known origin" is
    /// a claim about both directions: a branch that is 0 ahead and 20 behind is not in sync with
    /// anything. The row states the half BranchBar is willing to say, and the number stays out.
    @Test("behindOnlyBranchIsNotCalledInSync")
    func behindOnlyBranchIsNotCalledInSync() throws {
        let behind = try Self.onlyRow(of: Self.singleBranchSnapshot(
            upstream: Upstream(ref: "origin/feature", remote: "origin", ahead: 0, behind: 20),
            push: PushInfo(
                observedPushAt: UIClock.ago(9 * UIClock.day),
                observedPushOID: UIFixtures.tipSHA,
                source: .reflogObserved,
                hasUpstream: true,
                aheadOfLastKnownRemote: 0)))

        let label = try #require(behind.aheadLabel)
        #expect(label == Strings.noLocalCommitsAhead())
        #expect(!label.contains(Strings.inSync))
        #expect(!label.contains("20"), "PLAN.md §3 still forbids showing the behind count")
        #expect(!label.lowercased().contains("behind"))

        // Both counts zero is still "In sync", which is the only case that claim is true.
        let synced = try Self.onlyRow(of: Self.singleBranchSnapshot(
            upstream: Upstream(ref: "origin/feature", remote: "origin", ahead: 0, behind: 0),
            push: PushInfo(
                observedPushAt: UIClock.ago(2 * UIClock.day),
                observedPushOID: UIFixtures.tipSHA,
                source: .reflogObserved,
                hasUpstream: true,
                aheadOfLastKnownRemote: 0)))
        #expect(synced.aheadLabel == Strings.inSync)
    }

    /// codex MAJOR 3. The Not-scanned notice used to ride the first repo section, and with every
    /// repo inside a denied Documents folder there is no first section — so the one user who
    /// needs "Allow access…" got the generic empty state instead.
    @Test("tccDenialWithZeroReposRendersTheNotScannedNoticeInTheEmptyState")
    func tccDenialWithZeroReposRendersTheNotScannedNoticeInTheEmptyState() throws {
        let scanResult = UIFixtures.scanResult(repoCount: 0, unreadable: ["/Users/tester/Documents"])
        let vm = SnapshotPresenter().present(
            UIFixtures.snapshot([]),
            refreshState: .idle(lastRefreshedAt: UIClock.ago(12)),
            collapsedRepoIDs: [],
            scanResult: scanResult,
            appVersion: uiAppVersion,
            now: UIClock.now
        )

        #expect(vm.sections.isEmpty, "the case only arises when there is no section to carry it")
        let empty = try #require(vm.emptyState)
        let notice = try #require(empty.notice, "the denial reached the user nowhere at all")
        #expect(notice.text.contains(Strings.notScanned(folders: ["Documents"])))
        #expect(notice.text.contains(Strings.skippedCategoriesSummary))
        #expect(notice.action?.label == Strings.grantFolderAccessActionLabel)
        #expect(notice.action?.kind == .grantFolderAccess)
        // The empty state keeps its own primary action.
        #expect(empty.action.kind == .addFolder)

        // A scan that read everything raises no notice, so the ordinary empty state is unchanged.
        let clean = SnapshotPresenter().present(
            UIFixtures.snapshot([]),
            refreshState: .idle(lastRefreshedAt: UIClock.ago(12)),
            collapsedRepoIDs: [],
            scanResult: UIFixtures.scanResult(repoCount: 0),
            appVersion: uiAppVersion,
            now: UIClock.now
        )
        #expect(clean.emptyState?.notice == nil)

        // And it reaches the user while the first scan is still running, too.
        let scanning = SnapshotPresenter().present(
            UIFixtures.snapshot([], refreshedAt: nil),
            refreshState: .running(completed: 0, total: 0),
            collapsedRepoIDs: [],
            scanResult: scanResult,
            appVersion: uiAppVersion,
            now: UIClock.now
        )
        #expect(scanning.emptyState?.notice?.action?.kind == .grantFolderAccess)
    }

    @Test("aheadCountLabelledRelativeToLastKnownRemoteNotAbsolute")
    func aheadCountLabelledRelativeToLastKnownRemoteNotAbsolute() throws {
        let row = try Self.onlyRow(of: Self.singleBranchSnapshot(
            upstream: Upstream(ref: "origin/feature", remote: "origin", ahead: 2, behind: 7),
            push: PushInfo(
                observedPushAt: UIClock.ago(UIClock.day),
                observedPushOID: UIFixtures.otherSHA,
                source: .reflogObserved,
                hasUpstream: true,
                aheadOfLastKnownRemote: 2,
                remoteRefObservedAt: UIClock.ago(3 * UIClock.hour)
            )
        ))

        let ahead = try #require(row.aheadLabel)
        #expect(ahead.contains(Strings.ahead(2)))
        #expect(ahead.contains("last-known origin"))
        // `behind` is parsed and never presented (PLAN.md §3).
        #expect(!ahead.contains("7"))
        #expect(!ahead.lowercased().contains("behind"))
        // The tooltip carries the anchor, so "2 ahead" is never read as an absolute commit count.
        #expect(row.pushTooltip.contains(Strings.aheadTooltip(
            remoteObservedAt: UIClock.ago(3 * UIClock.hour),
            now: UIClock.now
        )))
    }

    /// codex round 2, MAJOR 5. The reflog of `origin/feature` is read precisely because that ref
    /// exists, so a row whose push line came from it may not also say there is no matching branch
    /// on origin. The two sentences contradict each other on the same row.
    @Test("untrackedBranchWithExistingRemoteRefDoesNotClaimNoMatchingBranch")
    func untrackedBranchWithExistingRemoteRefDoesNotClaimNoMatchingBranch() throws {
        // `git push origin feature` without `-u`: no tracking configuration, and `origin/feature`
        // is right there in the remote-tracking ref list.
        let repo = RepoAssembler.assemble(RepoAssembler.Inputs(
            id: UIFixtures.id("demo"),
            path: "\(UIFixtures.home)/demo",
            remoteURL: "https://github.com/tester/demo.git",
            branchRefs: [ParsedBranchRef(
                refName: "refs/heads/feature",
                objectName: UIFixtures.tipSHA,
                committerDate: UIClock.ago(2 * UIClock.day),
                upstreamShort: "",
                upstreamRemoteName: "",
                track: "",
                isHead: true)],
            remoteRefs: [ParsedRemoteRef(
                refName: "refs/remotes/origin/feature",
                objectName: UIFixtures.tipSHA,
                committerDate: UIClock.ago(3 * UIClock.day))],
            pushObservations: ["feature": ReflogObservation(
                pushedAt: UIClock.ago(2 * UIClock.day), newOID: UIFixtures.tipSHA)],
            prLoadState: .loaded))

        let branch = try #require(repo.branches.first)
        #expect(branch.upstream == nil, "the branch tracks nothing")
        #expect(branch.push.source == .reflogObserved, "and its push line came from origin/feature")

        let row = try Self.onlyRow(of: UIFixtures.snapshot([repo]))
        let ahead = try #require(row.aheadLabel)
        #expect(!ahead.contains(Strings.noUpstream),
                "origin holds the very branch this line says it does not: \(ahead)")
        #expect(ahead.contains("origin"), "the line still names what it is talking about: \(ahead)")
    }

    /// codex round 2, MAJOR 5. A branch tracking `fork/feature` was compared against `fork`, and
    /// then told the user about `origin`. Every wording that names a remote names the one the
    /// comparison actually used.
    @Test("nonOriginUpstreamWordingNamesTheRemote")
    func nonOriginUpstreamWordingNamesTheRemote() throws {
        let row = try Self.onlyRow(of: Self.singleBranchSnapshot(
            upstream: Upstream(ref: "fork/feature", remote: "fork", ahead: 2),
            push: PushInfo(
                observedPushAt: UIClock.ago(UIClock.day),
                observedPushOID: UIFixtures.otherSHA,
                originMovedSince: true,
                source: .reflogObserved,
                hasUpstream: true,
                aheadOfLastKnownRemote: 2,
                remoteRefObservedAt: UIClock.ago(3 * UIClock.hour))))

        let ahead = try #require(row.aheadLabel)
        #expect(ahead.contains("2 ahead of last-known fork"))
        #expect(!ahead.contains("origin"), "the comparison was never against origin: \(ahead)")
        #expect(row.pushLabel.contains("(fork has moved since)"))
        #expect(!row.pushLabel.contains("origin"))
        #expect(!row.pushTooltip.contains("last-known origin"))

        // origin keeps its wording verbatim, which is what PLAN.md §3 locked.
        let onOrigin = try Self.onlyRow(of: Self.singleBranchSnapshot(
            upstream: Upstream(ref: "origin/feature", remote: "origin", ahead: 2),
            push: PushInfo(
                observedPushAt: UIClock.ago(UIClock.day),
                observedPushOID: UIFixtures.otherSHA,
                originMovedSince: true,
                source: .reflogObserved,
                hasUpstream: true,
                aheadOfLastKnownRemote: 2,
                remoteRefObservedAt: UIClock.ago(3 * UIClock.hour))))
        #expect(onOrigin.aheadLabel?.contains("2 ahead of last-known origin") == true)
        #expect(onOrigin.pushLabel.contains("(origin has moved since)"))
    }

    // MARK: - Group copy (PLAN.md §3: the app deletes nothing)

    @Test("mergedCopyNamesBaseRefAndMakesNoDeletionClaim")
    func mergedCopyNamesBaseRefAndMakesNoDeletionClaim() throws {
        let pr = UIFixtures.pr(
            105,
            state: "MERGED",
            mergedAt: UIClock.ago(UIClock.day),
            baseRefName: "release/2026-09",
            headRefName: "status-line-fix"
        )
        let snapshot = UIFixtures.snapshot([
            UIFixtures.repo(branches: [
                UIFixtures.branch(
                    "status-line-fix",
                    upstream: Upstream(ref: "origin/status-line-fix", remote: "origin"),
                    pr: pr,
                    prStatus: .merged,
                    push: PushInfo(source: .reflogObserved, hasUpstream: true, aheadOfLastKnownRemote: 0),
                    group: .merged
                )
            ])
        ])

        let vm = SnapshotPresenter().present(
            snapshot,
            refreshState: .idle(lastRefreshedAt: UIClock.ago(12)),
            collapsedRepoIDs: [],
            scanResult: nil,
            appVersion: uiAppVersion,
            now: UIClock.now
        )
        let section = try #require(vm.sections.first)

        #expect(section.active.isEmpty, "a merged branch belongs to the merged group only")
        let row = try #require(section.merged.first)
        let copy = try #require(row.aheadLabel)
        #expect(copy.contains("PR merged into release/2026-09"))
        #expect(row.prPill?.status == .merged)
        for forbidden in ["safe to delete", "delete", "clean up", "remove"] {
            #expect(
                !copy.lowercased().contains(forbidden),
                "merged copy makes a deletion claim: \(copy)"
            )
        }
        // Was "No later local commits found." until codex MAJOR 8. GitHub documents `headRefOid`
        // as the PR's **current** head, not a snapshot of what was merged: if the head branch
        // advanced after the merge and the same later commit exists locally, the equality still
        // holds and the old sentence claimed there was no later work when there was.
        #expect(copy.contains(Strings.mergedGroupCopy(base: "release/2026-09")))
        #expect(copy.hasSuffix("Local tip matches GitHub's current PR head."))
        #expect(!copy.contains("No later local commits found"))
    }

    @Test("upstreamGoneCopySaysLastKnownOriginNotDeletedOnGitHub")
    func upstreamGoneCopySaysLastKnownOriginNotDeletedOnGitHub() throws {
        let row = try Self.onlyRow(of: Self.singleBranchSnapshot(
            upstream: Upstream(ref: "origin/merged-last-week", remote: "origin", isGone: true),
            push: PushInfo(
                observedPushAt: UIClock.ago(8 * UIClock.day),
                observedPushOID: UIFixtures.tipSHA,
                source: .reflogObserved,
                hasUpstream: true,
                upstreamGone: true
            )
        ))

        let copy = try #require(row.aheadLabel)
        #expect(copy.contains(Strings.upstreamMissing))
        #expect(copy.contains("last-known origin"))
        for forbidden in ["deleted on GitHub", "deleted", "GitHub"] {
            #expect(!copy.contains(forbidden), "upstream-gone copy asserts what GitHub holds: \(copy)")
        }
    }

    // MARK: - Notices

    /// The presenter half of `unavailableReasonCopyNamesOneActionPerReason`: the reason reaches the
    /// section as a notice that carries the one action, not as a bare pill.
    @Test("unavailableReasonCopyNamesOneActionPerReason")
    func unavailableReasonCopyNamesOneActionPerReason() throws {
        for reason in PRUnavailableReason.allReasonsForContractTesting {
            let snapshot = UIFixtures.snapshot([
                UIFixtures.repo(
                    branches: [UIFixtures.branch("main", prStatus: .unavailable)],
                    prAvailability: .unavailable(reason, detail: "diagnostic that is never rendered"),
                    prLoadState: .notLoaded
                )
            ])
            let vm = SnapshotPresenter().present(
                snapshot,
                refreshState: .idle(lastRefreshedAt: UIClock.ago(12)),
                collapsedRepoIDs: [],
                scanResult: nil,
                appVersion: uiAppVersion,
                now: UIClock.now
            )
            let notice = try #require(vm.sections.first?.prNotice, "\(reason) produced no notice")
            let failure = Strings.unavailable(reason: reason, detail: "diagnostic that is never rendered")

            #expect(notice.text.contains(failure.title))
            #expect(notice.text.contains(failure.message))
            #expect(notice.action?.label == failure.action?.label)
            #expect(notice.action?.kind == failure.action?.kind)
            #expect(notice.action?.payload == failure.action?.payload)
            // PLAN.md §5: `detail` is logged, never rendered — with the one exception codex round
            // 2 MAJOR 7 created. `commandFailed` is the reason that names no cause and no cure, so
            // the first stderr line is the only thing it has to tell the user; every other reason
            // still renders none of it.
            if reason != .commandFailed {
                #expect(!notice.text.contains("diagnostic that is never rendered"))
            }
            #expect(vm.sections.first?.active.first?.prPill?.text == Strings.prUnavailable)
        }
    }

    @Test("notLoadedShowsNoticeNotPills")
    func notLoadedShowsNoticeNotPills() throws {
        let repo = UIFixtures.repo(
            branches: [UIFixtures.branch("main", prStatus: .notLoaded)],
            prLoadState: .notLoaded
        )
        let vm = SnapshotPresenter().present(
            UIFixtures.snapshot([repo]),
            refreshState: .idle(lastRefreshedAt: UIClock.ago(12)),
            collapsedRepoIDs: [repo.id],
            scanResult: nil,
            appVersion: uiAppVersion,
            now: UIClock.now
        )
        let section = try #require(vm.sections.first)

        #expect(section.prNotice?.text.contains(Strings.prNotLoaded) == true)
        #expect(section.active.allSatisfy { $0.prPill == nil })
        // PLAN.md §3: a collapsed repo is never rendered as "No PR".
        #expect(!vm.renders(Strings.prNone))
    }

    @Test("collapsedRepoHidesRowsButKeepsTitle")
    func collapsedRepoHidesRowsButKeepsTitle() throws {
        let repo = UIFixtures.repo(
            "demo",
            branches: [
                UIFixtures.branch("main", prStatus: .notLoaded),
                UIFixtures.branch("side", prStatus: .notLoaded, group: .merged),
            ],
            openPRsNotOnThisMac: [UIFixtures.pr(9, headRefName: "elsewhere")]
        )
        let presenter = SnapshotPresenter()
        let expanded = presenter.present(
            UIFixtures.snapshot([repo]),
            refreshState: .idle(lastRefreshedAt: UIClock.ago(12)),
            collapsedRepoIDs: [],
            scanResult: nil,
            appVersion: uiAppVersion,
            now: UIClock.now
        )
        let collapsed = presenter.present(
            UIFixtures.snapshot([repo]),
            refreshState: .idle(lastRefreshedAt: UIClock.ago(12)),
            collapsedRepoIDs: [repo.id],
            scanResult: nil,
            appVersion: uiAppVersion,
            now: UIClock.now
        )

        let open = try #require(expanded.sections.first)
        let shut = try #require(collapsed.sections.first)

        #expect(open.isCollapsed == false)
        #expect(open.active.count == 1)
        #expect(open.merged.count == 1)
        #expect(open.openElsewhere.count == 1)

        #expect(shut.isCollapsed)
        #expect(shut.title == "demo")
        #expect(shut.title == open.title)
        #expect(shut.active.isEmpty)
        #expect(shut.merged.isEmpty)
        #expect(shut.closedUnmerged.isEmpty)
        #expect(shut.openElsewhere.isEmpty)
    }

    // MARK: - Empty state and ordering

    @Test("emptyScanRendersActionableEmptyState")
    func emptyScanRendersActionableEmptyState() throws {
        let presenter = SnapshotPresenter()

        let scanning = presenter.present(
            UIFixtures.snapshot([], refreshedAt: nil),
            refreshState: .running(completed: 0, total: 0),
            collapsedRepoIDs: [],
            scanResult: nil,
            appVersion: uiAppVersion,
            now: UIClock.now
        )
        let scanningState = try #require(scanning.emptyState, "first run rendered no empty state")
        #expect(scanningState.title == Strings.firstRunTitle)
        #expect(scanningState.message == Strings.firstRunMessage)
        #expect(scanning.sections.isEmpty)
        #expect(scanning.footer.updatedLabel == Strings.updated(at: nil, now: UIClock.now))

        let finished = presenter.present(
            UIFixtures.snapshot([]),
            refreshState: .idle(lastRefreshedAt: UIClock.ago(12)),
            collapsedRepoIDs: [],
            scanResult: UIFixtures.scanResult(repoCount: 0),
            appVersion: uiAppVersion,
            now: UIClock.now
        )
        let empty = try #require(finished.emptyState, "zero repos rendered no empty state")
        #expect(empty.title == Strings.emptyStateTitle)
        #expect(empty.message == Strings.emptyStateMessage)
        // §5a item 1: the empty state is actionable — the primary action is Add folder….
        #expect(empty.action.label == Strings.addFolderActionLabel)
        #expect(empty.action.kind == .addFolder)
        #expect(empty.message.contains("Dropbox"))

        // A snapshot with repos has no empty state at all.
        let populated = presenter.present(
            UIFixtures.snapshot([UIFixtures.repo(branches: [UIFixtures.branch("main", prStatus: .none)])]),
            refreshState: .idle(lastRefreshedAt: UIClock.ago(12)),
            collapsedRepoIDs: [],
            scanResult: UIFixtures.scanResult(),
            appVersion: uiAppVersion,
            now: UIClock.now
        )
        #expect(populated.emptyState == nil)
    }

    /// REVIEW CR-04: no git on the Mac used to render "Looking for repos…" forever, because the
    /// only thing the presenter did with `RefreshState` was ask whether it was `.running`. The
    /// failure now names itself in both slots that can carry it: the empty state when the list is
    /// empty, and the footer's tool notice when a cached list is on screen. Neither may fall back
    /// to "No repos found", which is not the reason, or to "Add folder…", which is a dead end.
    @Test("failedRefreshRendersItsReasonNotNoReposFound")
    func failedRefreshRendersItsReasonNotNoReposFound() throws {
        let failure = Strings.gitNotFound(diagnostic: "searched /usr/bin/git")
        let presenter = SnapshotPresenter()

        let empty = presenter.present(
            UIFixtures.snapshot([], refreshedAt: nil, tools: ToolStatus(ghPath: "/opt/homebrew/bin/gh")),
            refreshState: .failed(failure),
            collapsedRepoIDs: [],
            scanResult: nil,
            appVersion: uiAppVersion,
            now: UIClock.now
        )
        let state = try #require(empty.emptyState, "a failed refresh rendered no empty state")
        #expect(state.title == Strings.gitNotFoundTitle)
        #expect(state.message == Strings.gitNotFoundMessage)
        #expect(state.action.label == Strings.refreshActionLabel)
        #expect(state.action.kind == .retryRefresh)
        #expect(state.title != Strings.emptyStateTitle)
        #expect(state.title != Strings.firstRunTitle)
        // The diagnostic is logged, never rendered (PLAN.md §5).
        #expect(!empty.renders("searched /usr/bin/git"))

        // With a cached list on screen there is no empty state, so the footer carries it instead.
        let cached = presenter.present(
            UIFixtures.snapshot(
                [UIFixtures.repo(branches: [UIFixtures.branch("main", prStatus: .none)])],
                tools: ToolStatus(ghPath: "/opt/homebrew/bin/gh")),
            refreshState: .failed(failure),
            collapsedRepoIDs: [],
            scanResult: nil,
            appVersion: uiAppVersion,
            now: UIClock.now
        )
        #expect(cached.emptyState == nil)
        let notice = try #require(cached.footer.toolNotice, "a failed refresh rendered no footer notice")
        #expect(notice.text.contains(Strings.gitNotFoundTitle))
        #expect(notice.text.contains(Strings.gitNotFoundMessage))
        #expect(notice.action?.kind == .retryRefresh)
        // The footer is not claiming a refresh is under way, so its buttons stay live.
        #expect(cached.footer.updatedLabel == Strings.updated(at: UIClock.ago(12), now: UIClock.now))
    }

    /// PLAN.md §5a item 3: repo order is computed once per refresh, before any repo finishes. The
    /// presenter renders `Snapshot.repos` in the order it was handed
    /// (`rowOrderIsStableAcrossProgressiveEmits`).
    @Test("presenterNeverReordersSections")
    func presenterNeverReordersSections() throws {
        // Deliberately hostile to every sort key: names descending, oldest activity first.
        let repos = [
            UIFixtures.repo("zebra", branches: [UIFixtures.branch("main", prStatus: .none)]),
            UIFixtures.repo("mango", branches: [UIFixtures.branch("main", prStatus: .none)]),
            UIFixtures.repo("apple", branches: [UIFixtures.branch("main", prStatus: .none)]),
        ]
        let vm = SnapshotPresenter().present(
            UIFixtures.snapshot(repos),
            refreshState: .idle(lastRefreshedAt: UIClock.ago(12)),
            collapsedRepoIDs: [],
            scanResult: nil,
            appVersion: uiAppVersion,
            now: UIClock.now
        )

        #expect(vm.sections.map(\.title) == ["zebra", "mango", "apple"])
        #expect(vm.sections.map(\.id) == repos.map(\.id))
    }

    // MARK: - Rows

    @Test("everyBranchRowHasAnAccessibilityLabel")
    func everyBranchRowHasAnAccessibilityLabel() throws {
        var checked = 0
        for id in stateFixtureIDs {
            let fixture = try loadStateFixture(id)
            let vm = Self.presenter(forState: id).present(
                fixture.snapshot,
                refreshState: fixture.refreshState,
                collapsedRepoIDs: Set(fixture.collapsedRepoIDs),
                scanResult: fixture.scanResult,
                appVersion: fixture.appVersion,
                now: fixture.now
            )
            for section in vm.sections {
                for row in section.active + section.merged + section.closedUnmerged {
                    #expect(!row.accessibilityLabel.isEmpty, "\(id): row \"\(row.title)\" has no spoken label")
                    #expect(!row.title.isEmpty, "\(id): a row has no title")
                    checked += 1
                }
                for row in section.openElsewhere {
                    #expect(!row.accessibilityLabel.isEmpty, "\(id): PR row \"\(row.title)\" has no spoken label")
                    checked += 1
                }
            }
        }
        #expect(checked > 20, "only \(checked) rows were checked across 32 states")

        // §5a: the label is a sentence built by Strings, and a no-branch worktree still gets one.
        let detached = try Self.rows(ofState: "detached-worktree")
        let noBranch = try #require(
            detached.first { $0.worktreeMarker?.contains("no branch") == true },
            "the detached worktree rendered no row of its own"
        )
        #expect(noBranch.accessibilityLabel == Strings.detachedWorktree(shortSHA: "abc1234"))
        #expect(noBranch.prPill == nil, "a worktree with no branch has no PR to show")
    }

    /// Packet 4.3. The shell used to derive both of these itself — the PR address it did not have
    /// at all, and the repo folder it read off whichever row happened to be first, which is a
    /// different folder for a branch checked out in a worktree. Both are facts the presenter
    /// already holds, so both are fields now.
    @Test("rowsCarryTheirPRAddressAndSectionsCarryTheirFolder")
    func rowsCarryTheirPRAddressAndSectionsCarryTheirFolder() throws {
        let repo = UIFixtures.repo(
            "demo",
            worktrees: [
                Worktree(
                    path: "/Users/tester/demo",
                    headSHA: UIFixtures.tipSHA,
                    branch: "refs/heads/main",
                    isPrimary: true),
                Worktree(
                    path: "/Users/tester/demo-agents-2",
                    headSHA: UIFixtures.otherSHA,
                    branch: "refs/heads/agent-task-2"),
            ],
            branches: [
                UIFixtures.branch(
                    "agent-task-2",
                    tipSHA: UIFixtures.otherSHA,
                    worktreePath: "/Users/tester/demo-agents-2",
                    isCheckedOutInPrimary: false,
                    pr: UIFixtures.pr(102, headRefName: "agent-task-2", headRefOid: UIFixtures.otherSHA),
                    prStatus: .open),
                UIFixtures.branch("no-pr-here", prStatus: .none),
                UIFixtures.branch(
                    "status-line-fix",
                    pr: UIFixtures.pr(105, state: "MERGED", mergedAt: UIClock.ago(UIClock.day),
                                      headRefName: "status-line-fix"),
                    prStatus: .merged,
                    group: .merged),
            ]
        )
        let vm = SnapshotPresenter().present(
            UIFixtures.snapshot([repo]),
            refreshState: .idle(lastRefreshedAt: UIClock.ago(12)),
            collapsedRepoIDs: [],
            scanResult: nil,
            appVersion: uiAppVersion,
            now: UIClock.now
        )
        let section = try #require(vm.sections.first)

        // The repo's own folder, not the first row's — that row opens a worktree elsewhere.
        #expect(section.path == "/Users/tester/demo")
        #expect(section.active.first?.primaryAction.payload == "/Users/tester/demo-agents-2")

        let withPR = try #require(section.active.first { $0.title == "agent-task-2" })
        #expect(withPR.prURL == "https://github.com/tester/demo/pull/102")
        // A branch GitHub answered about with no PR has no address to offer.
        #expect(section.active.first { $0.title == "no-pr-here" }?.prURL == nil)
        // A merged row keeps its PR: that page is what says what happened to the branch.
        #expect(section.merged.first?.prURL == "https://github.com/tester/demo/pull/105")

        // A worktree with no branch has no PR either, and its row is titled by its folder.
        let detached = try Self.rows(ofState: "detached-worktree")
        #expect(detached.allSatisfy { $0.prURL == nil })

        // Every recorded state names its repo's folder, so the header menu is never empty.
        for id in stateFixtureIDs {
            let fixture = try loadStateFixture(id)
            let replayed = Self.presenter(forState: id).present(
                fixture.snapshot,
                refreshState: fixture.refreshState,
                collapsedRepoIDs: Set(fixture.collapsedRepoIDs),
                scanResult: fixture.scanResult,
                appVersion: fixture.appVersion,
                now: fixture.now
            )
            for replayedSection in replayed.sections {
                #expect(
                    replayedSection.path?.hasPrefix("/") == true,
                    "\(id): section \(replayedSection.title) has no folder")
            }
        }
    }

    @Test("editorFallbackChoosesCursorThenVSCodeThenTerminal")
    func editorFallbackChoosesCursorThenVSCodeThenTerminal() throws {
        let snapshot = Self.singleBranchSnapshot(push: PushInfo(source: .none))

        func label(_ editors: EditorAvailability) throws -> String {
            let vm = SnapshotPresenter(editors: editors).present(
                snapshot,
                refreshState: .idle(lastRefreshedAt: UIClock.ago(12)),
                collapsedRepoIDs: [],
                scanResult: nil,
                appVersion: uiAppVersion,
                now: UIClock.now
            )
            return try #require(vm.sections.first?.active.first?.primaryAction.label)
        }

        #expect(try label(EditorAvailability(cursor: true, vsCode: true)) == Strings.openInCursorActionLabel)
        #expect(try label(EditorAvailability(cursor: true, vsCode: false)) == Strings.openInCursorActionLabel)
        #expect(try label(EditorAvailability(cursor: false, vsCode: true)) == Strings.openInVSCodeActionLabel)
        #expect(try label(EditorAvailability(cursor: false, vsCode: false)) == Strings.openInTerminalActionLabel)
        #expect(EditorAvailability.all == EditorAvailability(cursor: true, vsCode: true))

        // §5a item 1: when Cursor is missing the footer says where rows open instead.
        let withoutCursor = SnapshotPresenter(editors: EditorAvailability(cursor: false, vsCode: true)).present(
            snapshot,
            refreshState: .idle(lastRefreshedAt: UIClock.ago(12)),
            collapsedRepoIDs: [],
            scanResult: nil,
            appVersion: uiAppVersion,
            now: UIClock.now
        )
        #expect(withoutCursor.footer.toolNotice?.text.contains(Strings.cursorNotInstalledNotice) == true)
        #expect(
            SnapshotPresenter().present(
                snapshot,
                refreshState: .idle(lastRefreshedAt: UIClock.ago(12)),
                collapsedRepoIDs: [],
                scanResult: nil,
                appVersion: uiAppVersion,
                now: UIClock.now
            ).footer.toolNotice == nil,
            "an installed Cursor still raised the fallback notice"
        )
    }

    // MARK: - Builders

    static func singleBranchSnapshot(
        upstream: Upstream? = Upstream(ref: "origin/feature", remote: "origin"),
        push: PushInfo
    ) -> Snapshot {
        UIFixtures.snapshot([
            UIFixtures.repo(branches: [
                UIFixtures.branch("feature", upstream: upstream, prStatus: .none, push: push)
            ])
        ])
    }

    static func onlyRow(of snapshot: Snapshot) throws -> BranchRowVM {
        let vm = SnapshotPresenter().present(
            snapshot,
            refreshState: .idle(lastRefreshedAt: UIClock.ago(12)),
            collapsedRepoIDs: [],
            scanResult: nil,
            appVersion: uiAppVersion,
            now: UIClock.now
        )
        let section = try #require(vm.sections.first, "the snapshot rendered no section")
        return try #require(
            (section.active + section.merged + section.closedUnmerged).first,
            "the section rendered no row"
        )
    }

    static func rows(ofState id: String) throws -> [BranchRowVM] {
        let fixture = try loadStateFixture(id)
        let vm = presenter(forState: id).present(
            fixture.snapshot,
            refreshState: fixture.refreshState,
            collapsedRepoIDs: Set(fixture.collapsedRepoIDs),
            scanResult: fixture.scanResult,
            appVersion: fixture.appVersion,
            now: fixture.now
        )
        return vm.sections.flatMap { $0.active + $0.merged + $0.closedUnmerged }
    }
}
