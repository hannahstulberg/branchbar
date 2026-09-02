import AppKit
import BranchBarCore
import Foundation
import SwiftUI

/// Why a refresh is running. `RefreshCoordinator` takes flags rather than a reason, so this is the
/// shell's vocabulary and the mapping to those flags lives in one place (`coordinatorArguments`).
enum RefreshReason: String {
    /// Once per process, from `applicationDidFinishLaunching`.
    case launch
    /// Every popover open. The only reason that respects the coordinator's 30 s debounce.
    case popoverOpen
    /// The footer's Refresh button.
    case manual
    /// The footer's Rescan button, and what "Add folder…" runs after adding a root.
    case rescan
    /// The footer's Refresh PRs now button.
    case refreshPRsNow
}

/// The one object the SwiftUI layer talks to: it owns the real `RefreshCoordinator`, turns every
/// `Snapshot` it emits into a `SnapshotVM` through `SnapshotPresenter`, and holds the collapse and
/// hide choices that outlive a launch.
///
/// It derives no path from `Bundle.main.bundlePath`. The 0.2 spike proved a quarantined bundle runs
/// app-translocated out of `/private/var/folders/…/AppTranslocation/…`, so a path taken from the
/// bundle points at a copy that disappears; only the *version string* is read from `Bundle.main`.
@MainActor
final class AppModel: ObservableObject {

    // MARK: - What the views render

    @Published private(set) var vm: SnapshotVM
    @Published private(set) var refreshState: RefreshState = .running(completed: 0, total: 0)
    @Published private(set) var collapsedRepoIDs: Set<RepoID> = []

    /// Repos the user hid. Published because the footer's "Show hidden (N)" carries the count, and
    /// a hide has to move that number the moment it happens.
    @Published private(set) var hiddenRepoIDs: Set<RepoID> = []

    /// Whether hidden repos are being shown anyway, so they can be un-hidden. Session-only and off
    /// at every launch: hiding is meant to shorten the list, and a preference that quietly
    /// un-shortens it on the next launch would defeat the point.
    @Published private(set) var showsHiddenRepos = false

    /// Mirrors `LaunchAtLogin` for SwiftUI. Read once at launch and after every flip rather than
    /// polled: `SMAppService.status` is an XPC round trip and the popover redraws constantly.
    @Published private(set) var launchAtLoginIsOn = false

    /// Beside the toggle: why it is disabled, or what macOS is still waiting for. Nil when the
    /// toggle needs no explaining.
    @Published private(set) var launchAtLoginNotice: String?

    /// Non-nil only in `BRANCHBAR_STATE_FIXTURE` mode; the fixture's own id, which the log line
    /// `rendered state <id>` names.
    let previewStateID: String?

    // MARK: - What produces it

    private var snapshot = Snapshot()
    private var scanResult: ScanResult?
    /// Repos the cache has already seen. A repo absent from it is new, and a new repo starts
    /// collapsed unless it is the most recently active one (docs/UI-CONTRACT.md section 3).
    private var knownRepoIDs: Set<RepoID> = []
    private var editors: EditorAvailability = .all
    private var environment: Environment?
    private var isBootstrapping = false
    private var progressCount = 0

    /// Everything a refresh needs, built once. `git --version` is a process, so this cannot be
    /// assembled in `init`.
    private struct Environment {
        let coordinator: RefreshCoordinator
        let tools: ToolStatus
        let cache: FileCacheStore
    }

    private let cacheURL: URL
    private let appVersion: String

    // MARK: - Live model

    static let shared: AppModel = {
        if let path = ProcessInfo.processInfo.environment["BRANCHBAR_STATE_FIXTURE"],
           !path.isEmpty,
           let previewing = AppModel(previewing: path) {
            return previewing
        }
        return AppModel()
    }()

    init() {
        previewStateID = nil
        appVersion = Self.version
        cacheURL = FileCacheStore.defaultFileURL(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        editors = Actions.editors
        vm = SnapshotPresenter(editors: editors).present(
            Snapshot(),
            refreshState: .running(completed: 0, total: 0),
            collapsedRepoIDs: [],
            scanResult: nil,
            appVersion: appVersion,
            now: Date())
        restoreFromCache()
        present()
    }

    // MARK: - Fixture model

    /// Renders one `Tests/BranchBarCoreTests/Fixtures/states/<state>.json` with no git, no `gh`,
    /// and no cache, so every §5a state can be looked at (and screenshotted) on any Mac.
    ///
    /// The envelope froze six arguments before editor availability existed, and one state's
    /// condition — Cursor missing — is a property of the Mac rather than of the snapshot, so the
    /// fixture's own id supplies it, exactly as `SnapshotPresenterTests` does.
    init?(previewing fixturePath: String) {
        guard let data = FileManager.default.contents(atPath: fixturePath),
              let fixture = try? JSONDecoder().decode(StateFixtureEnvelope.self, from: data)
        else {
            Log.info("fixture: could not read a state fixture at \(fixturePath)")
            return nil
        }

        previewStateID = fixture.id
        appVersion = fixture.appVersion
        cacheURL = URL(fileURLWithPath: "/dev/null")
        editors = fixture.id == "cursor-not-installed"
            ? EditorAvailability(cursor: false, vsCode: true)
            : .all

        snapshot = fixture.snapshot
        refreshState = fixture.refreshState
        collapsedRepoIDs = Set(fixture.collapsedRepoIDs)
        scanResult = fixture.scanResult

        // No recorded state hides a repo — hiding is a choice a person makes, not a state the app
        // can be found in — so `BRANCHBAR_PREVIEW_HIDDEN` is what lets Gate 4 photograph the footer's
        // "Show hidden (N)" control and the "Hidden" marker. `=shown` hides the fixture's last repo
        // and reveals it; anything else hides it and leaves it hidden. Same shape as 4.1's
        // `BRANCHBAR_APPEARANCE`: fixture mode only, and it changes nothing a real run does.
        var hidden: Set<RepoID> = []
        var showsHidden = false
        if let mode = ProcessInfo.processInfo.environment["BRANCHBAR_PREVIEW_HIDDEN"],
           !mode.isEmpty,
           let last = fixture.snapshot.repos.last {
            hidden = [last.id]
            showsHidden = mode == "shown"
        }
        hiddenRepoIDs = hidden
        showsHiddenRepos = showsHidden

        var visible = fixture.snapshot
        if !showsHidden {
            visible.repos = visible.repos.filter { !hidden.contains($0.id) }
        }
        vm = SnapshotPresenter(editors: editors).present(
            visible,
            refreshState: fixture.refreshState,
            collapsedRepoIDs: Set(fixture.collapsedRepoIDs),
            scanResult: fixture.scanResult,
            appVersion: fixture.appVersion,
            now: fixture.now)

        Log.info("fixture: loaded state \(fixture.id) from \(fixturePath)")
    }

    /// `Tests/BranchBarCoreTests/StringsTests.swift`'s `StateFixture`, decode-side only. It is
    /// restated rather than shared because the test target is not a dependency of the app, and it
    /// is `Decodable` only so nothing here can rewrite a recorded fixture.
    private struct StateFixtureEnvelope: Decodable {
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

    var isPreviewing: Bool { previewStateID != nil }

    // MARK: - Version

    /// `Bundle.main` is authoritative once bundled; the Core constant covers `swift run`, where
    /// there is no Info.plist. A *string* from the bundle is safe; a *path* from it is not.
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? BranchBarCore.version
    }

    // MARK: - Refreshing

    func refresh(reason: RefreshReason) {
        guard !isPreviewing else { return }
        Task { await performRefresh(reason: reason) }
    }

    private func performRefresh(reason: RefreshReason) async {
        guard let environment = await resolvedEnvironment() else { return }

        let expanded = Set(snapshot.repos.map(\.id)).subtracting(collapsedRepoIDs)
        let (force, rescan, bypassPRCache) = Self.coordinatorArguments(for: reason)
        Log.info(
            "refresh: reason=\(reason.rawValue) force=\(force) rescan=\(rescan) "
                + "bypassPRCache=\(bypassPRCache) expanded=\(expanded.count)")

        progressCount = 0
        if case .idle = refreshState {
            refreshState = .running(completed: 0, total: snapshot.repos.count)
            present()
        }

        let final = await environment.coordinator.refresh(
            force: force,
            expandedRepoIDs: expanded,
            tools: environment.tools,
            onProgress: { [weak self] emitted in
                Task { @MainActor in self?.apply(progress: emitted) }
            },
            rescan: rescan,
            bypassPRCache: bypassPRCache)

        reloadScanFromCache()
        refreshState = .idle(lastRefreshedAt: final.refreshedAt)
        snapshot = final
        adoptCollapseDefaults()
        present()
        Log.info(
            "refresh: finished reason=\(reason.rawValue) repos=\(final.repos.count) "
                + "rows=\(final.repos.reduce(0) { $0 + $1.branches.count })")
        logRendered()
    }

    /// PLAN.md §3: the manual Refresh bypasses the 30 s debounce, a popover open does not.
    static func coordinatorArguments(for reason: RefreshReason)
        -> (force: Bool, rescan: Bool, bypassPRCache: Bool)
    {
        switch reason {
        case .popoverOpen: return (false, false, false)
        case .launch, .manual: return (true, false, false)
        case .rescan: return (true, true, false)
        case .refreshPRsNow: return (true, false, true)
        }
    }

    /// One progressive emit. The first emit of a launch is the cached list with every row stale
    /// (PLAN.md §4), which is a restore rather than a repo finishing, so it is not counted.
    private func apply(progress emitted: Snapshot) {
        let isLaunchRestore = !emitted.repos.isEmpty && emitted.repos.allSatisfy(\.isStale)
        if !isLaunchRestore { progressCount += 1 }
        snapshot = emitted
        adoptCollapseDefaults()
        refreshState = .running(
            completed: min(progressCount, emitted.repos.count), total: emitted.repos.count)
        present()
    }

    func cancelRefresh() {
        guard let environment else { return }
        Task { await environment.coordinator.cancel() }
    }

    // MARK: - Row and footer actions

    func toggleCollapse(_ repoID: RepoID) {
        if collapsedRepoIDs.contains(repoID) {
            collapsedRepoIDs.remove(repoID)
            // Expanding is what makes `gh` run for a repo (PLAN.md §3's lazy PR fetching), so the
            // expansion is worth a refresh of its own.
            present()
            refresh(reason: .manual)
        } else {
            collapsedRepoIDs.insert(repoID)
            present()
        }
        persist { $0.collapsedRepoIDs = Array(self.collapsedRepoIDs) }
    }

    /// Per-row Hide. A hidden repo is filtered out before the presenter sees it —
    /// `SnapshotPresenter` renders the repos it is handed and knows nothing about hiding — except
    /// while "Show hidden" is on, which is the only way back to un-hiding one.
    func hide(_ repoID: RepoID) {
        guard !hiddenRepoIDs.contains(repoID) else { return }
        hiddenRepoIDs.insert(repoID)
        persist { $0.hiddenRepoIDs = Array(self.hiddenRepoIDs) }
        Log.info("action: hide repo \(repoID.commonDir) · hidden=\(hiddenRepoIDs.count)")
        present()
    }

    func unhide(_ repoID: RepoID) {
        guard hiddenRepoIDs.contains(repoID) else { return }
        hiddenRepoIDs.remove(repoID)
        persist { $0.hiddenRepoIDs = Array(self.hiddenRepoIDs) }
        Log.info("action: stop hiding repo \(repoID.commonDir) · hidden=\(hiddenRepoIDs.count)")
        // Nothing left to reveal means nothing left for the toggle to do.
        if hiddenRepoIDs.isEmpty { showsHiddenRepos = false }
        present()
    }

    func isHidden(_ repoID: RepoID) -> Bool { hiddenRepoIDs.contains(repoID) }

    /// The footer's "Show hidden (N)". Turning it on puts the hidden repos back in the list with
    /// "Stop hiding this repo" on each one; turning it off shortens the list again.
    func setShowsHiddenRepos(_ shown: Bool) {
        guard showsHiddenRepos != shown else { return }
        showsHiddenRepos = shown
        Log.info("action: show hidden repos \(shown) · hidden=\(hiddenRepoIDs.count)")
        present()
    }

    // MARK: - Launch at login

    /// Reads the current login-item state into the published properties. Called at launch and
    /// after every flip.
    func refreshLaunchAtLoginState() {
        guard !isPreviewing else { return }
        launchAtLoginIsOn = LaunchAtLogin.isEnabled
        if let reason = LaunchAtLogin.unavailableReason {
            launchAtLoginNotice = reason
        } else if LaunchAtLogin.needsApproval {
            launchAtLoginNotice = Strings.launchAtLoginNeedsApproval
        } else {
            launchAtLoginNotice = nil
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isPreviewing else { return }
        do {
            try LaunchAtLogin.set(enabled)
            refreshLaunchAtLoginState()
        } catch {
            let failure = error as? LaunchAtLogin.Failure
            Log.info("action: launch at login \(enabled) failed: \(failure?.diagnostic ?? "\(error)")")
            refreshLaunchAtLoginState()
            // A failure the state read cannot see (the toggle is available, the flip still lost)
            // still owes the user a sentence.
            if launchAtLoginNotice == nil {
                launchAtLoginNotice = failure?.errorDescription ?? Strings.launchAtLoginFailed
            }
        }
    }

    func addFolder(_ url: URL) {
        let path = url.path
        persist { cache in
            if !cache.manuallyAddedRepos.contains(path) { cache.manuallyAddedRepos.append(path) }
            let roots = Array(Set((cache.scan?.policy.extraRoots ?? []) + [path])).sorted()
            cache.scan?.policy.extraRoots = roots
        }
        Log.info("action: added scan root \(path)")
        refresh(reason: .rescan)
    }

    func removeRoot(_ path: String) {
        persist { cache in
            cache.manuallyAddedRepos.removeAll { $0 == path }
            cache.scan?.policy.extraRoots.removeAll { $0 == path }
        }
        Log.info("action: removed scan root \(path)")
        reloadScanFromCache()
        present()
        refresh(reason: .rescan)
    }

    /// Dispatch for `UserFacingFailure.Action`. `Kind` was frozen in packet 1.1 with no
    /// open-in-editor case, so packet 2.2 encoded a row's primary action as `.openURL` carrying an
    /// absolute filesystem path; an absolute path means "open in the available editor" and
    /// anything else is a real URL (DECISION-LOG, packet 2.2).
    func perform(_ action: UserFacingFailure.Action) {
        switch action.kind {
        case .openURL:
            guard let payload = action.payload, !payload.isEmpty else { return }
            if payload.hasPrefix("/") {
                Actions.openInAvailableEditor(path: payload)
            } else {
                Actions.openPR(url: payload)
            }
        case .addFolder:
            if let url = Actions.pickFolder() { addFolder(url) }
        case .grantFolderAccess:
            // Not the same thing as Add folder…: this one is for a folder macOS already refused,
            // where the answer lives in the Privacy pane rather than in a picker.
            Actions.openFilesAndFoldersSettings()
        case .rescan:
            refresh(reason: .rescan)
        case .retryRefresh:
            refresh(reason: .manual)
        case .openTerminalWithGhAuthLogin:
            Actions.openTerminalForSignIn(command: action.payload)
        }
    }

    // MARK: - Presenting

    private func present() {
        var visible = snapshot
        if !showsHiddenRepos {
            visible.repos = visible.repos.filter { !hiddenRepoIDs.contains($0.id) }
        }
        vm = SnapshotPresenter(editors: editors).present(
            visible,
            refreshState: refreshState,
            collapsedRepoIDs: collapsedRepoIDs,
            scanResult: scanResult,
            appVersion: appVersion,
            now: Date())
    }

    /// What the popover is showing, in the words it is showing them in. A `MenuBarExtra` popover
    /// cannot be screenshotted from a script (the 0.2 spike: `screencapture` cannot see a status
    /// item), so the log is how a run proves what it drew on a real Mac.
    private func logRendered() {
        let titles = vm.sections.prefix(3).map(\.title).joined(separator: " | ")
        Log.info("rendered sections: \(titles)")
        for section in vm.sections {
            guard let row = section.active.first else { continue }
            Log.info(
                "rendered row: repo=\(section.title) title=\(row.title) "
                    + "marker=\(row.worktreeMarker ?? "—") pill=\(row.prPill?.text ?? "—") "
                    + "push=\(row.pushLabel) ahead=\(row.aheadLabel ?? "—") "
                    + "action=\(row.primaryAction.label) -> \(row.primaryAction.payload ?? "—") "
                    + "voiceover=\(row.accessibilityLabel)")
            break
        }
        Log.info("rendered footer: \(vm.footer.updatedLabel) · \(vm.footer.version)")
    }

    /// docs/UI-CONTRACT.md section 3: one repo is expanded; with more than one only the most
    /// recently active is, and the rest start collapsed. The user's own choice outranks the default
    /// on every later launch, which is why the default is applied only to a repo the cache has
    /// never held. Repo order is already most-recently-active first, computed once per refresh, so
    /// "the most recent" is index 0 and nothing here re-sorts anything.
    private func adoptCollapseDefaults() {
        let ids = snapshot.repos.map(\.id)
        guard !ids.isEmpty else { return }
        var changed = false
        for (index, id) in ids.enumerated() where !knownRepoIDs.contains(id) {
            knownRepoIDs.insert(id)
            if index > 0, !collapsedRepoIDs.contains(id) {
                collapsedRepoIDs.insert(id)
                changed = true
            }
        }
        if changed { persist { $0.collapsedRepoIDs = Array(self.collapsedRepoIDs) } }
    }

    // MARK: - Cache

    private func restoreFromCache() {
        guard let cache = ((try? FileCacheStore(fileURL: cacheURL).load()) ?? nil) else { return }
        collapsedRepoIDs = Set(cache.collapsedRepoIDs)
        hiddenRepoIDs = Set(cache.hiddenRepoIDs)
        scanResult = cache.scan
        knownRepoIDs = Set((cache.lastSnapshot?.repos ?? []).map(\.id))
        if let last = cache.lastSnapshot {
            // PLAN.md §4's launch step: show the last list, every row marked out of date, before
            // the first refresh has reloaded any of it.
            var restored = last
            restored.repos = restored.repos.map { repo in
                var repo = repo
                repo.isStale = true
                return repo
            }
            snapshot = restored
        } else if let scan = cache.scan, !scan.repos.isEmpty {
            // No snapshot yet, but the scan already knows which repos exist. Seeding placeholder
            // rows here is what lets the collapse defaults — and therefore the expanded set the
            // first refresh fetches PRs for — be decided *before* that refresh runs. Without it the
            // first refresh asks for no repo's PRs and every row draws "PR status loads when
            // expanded" under an expanded repo, which is a sentence that contradicts itself.
            //
            // The order is the one `RefreshCoordinator.stableOrder` computes for repos no previous
            // snapshot held: name ascending, ties broken by path. It is restated rather than called
            // because that method is internal to Core.
            let ordered = scan.repos.sorted { left, right in
                let leftName = (left.path as NSString).lastPathComponent
                let rightName = (right.path as NSString).lastPathComponent
                return leftName == rightName ? left.path < right.path : leftName < rightName
            }
            snapshot.repos = ordered.map {
                Repo(id: $0.id, name: ($0.path as NSString).lastPathComponent, path: $0.path)
            }
        }
        adoptCollapseDefaults()
    }

    private func reloadScanFromCache() {
        guard let cache = ((try? FileCacheStore(fileURL: cacheURL).load()) ?? nil) else { return }
        scanResult = cache.scan
    }

    /// Read-modify-write against the same file the coordinator persists to. The coordinator writes
    /// only at the end of a refresh and this only on a user action, so the window is small; losing
    /// a collapse choice to that race costs one click, and holding a lock across an actor would
    /// cost the popover its responsiveness.
    private func persist(_ mutate: (inout CacheFile) -> Void) {
        guard !isPreviewing else { return }
        let store = FileCacheStore(fileURL: cacheURL)
        var cache = ((try? store.load()) ?? nil) ?? CacheFile()
        mutate(&cache)
        try? store.save(cache)
    }

    // MARK: - Bootstrap

    /// `ToolLocator` finds git and `gh` on the fixed directory list, never on PATH: the GUI app's
    /// PATH is `/usr/bin:/bin:/usr/sbin:/sbin` and Homebrew is not on it (CLAUDE.md).
    private func resolvedEnvironment() async -> Environment? {
        if let environment { return environment }
        guard !isBootstrapping else { return nil }
        isBootstrapping = true
        defer { isBootstrapping = false }

        let runner = ProcessCommandRunner()
        let fileSystem = RealFileSystem()
        let locator = ToolLocator()
        let policy = RefreshPolicy()

        let gitLocation = locator.locate(.git)
        let ghPath = locator.locate(.gh).path
        Log.info(
            "tools: git=\(gitLocation.path ?? "not found") gh=\(ghPath ?? "not found") "
                + "cursor=\(Actions.editors.cursor) vscode=\(Actions.editors.vsCode)")

        guard let gitPath = gitLocation.path else {
            Log.info("tools: git not found; searched \(gitLocation.searched.joined(separator: ", "))")
            return nil
        }

        let gitVersion = try? await runner.run(
            Command(executable: gitPath, arguments: ["--version"], timeout: policy.gitTimeout)
        ).standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)

        let tools = ToolStatus(gitPath: gitPath, gitVersion: gitVersion, ghPath: ghPath)
        let cache = FileCacheStore(fileURL: cacheURL)
        let scanner = RepoScanner(fileSystem: fileSystem, commandRunner: runner, gitExecutable: gitPath)
        let loader = RepoLoader(
            git: GitClient(runner: runner, gitPath: gitPath, timeout: policy.gitTimeout),
            gh: ghPath.map { GHClient(runner: runner, ghPath: $0, policy: policy) },
            reflog: ReflogFileReader(fileSystem: fileSystem),
            policy: policy)
        let coordinator = RefreshCoordinator(
            scanner: scanner,
            loader: loader,
            cache: cache,
            policy: policy,
            scanPolicy: ScanPolicy(homeRoot: fileSystem.homeDirectory()),
            fileSystem: fileSystem)

        let environment = Environment(coordinator: coordinator, tools: tools, cache: cache)
        self.environment = environment
        return environment
    }
}
