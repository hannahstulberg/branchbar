import AppKit
import BranchBarCore
import Foundation
import ServiceManagement

/// The opt-in "Open BranchBar at login" toggle (PLAN.md §3: opt-in, defaults off, `SMAppService`
/// with a LaunchAgent fallback).
///
/// Two findings shape this file. The 0.2 spike proved a quarantined bundle runs **app-translocated**
/// out of `/private/var/folders/…/AppTranslocation/…` even from `/Applications`, so registering
/// anything derived from the running bundle would register a copy macOS throws away
/// (DECISION-LOG, packet 0.2 item 6) — hence `isAvailable` refuses outright there. And the app is
/// ad-hoc signed, not Developer ID, so `SMAppService.register()` is not guaranteed to stick; when
/// it does not, the LaunchAgent path writes a plist naming the one path a handout is installed to.
///
/// Which mechanism is live on a given Mac is a runtime fact, not a build-time one, so `set(_:)`
/// tries `SMAppService` first and reports what it ended up using in `mechanism`.
@MainActor
enum LaunchAtLogin {

    /// What is actually holding the login item right now.
    enum Mechanism: String {
        case serviceManagement
        case launchAgent
        case off
    }

    /// Frozen in PLAN.md §3; also the LaunchAgent's `Label`.
    static let bundleID = "com.hannahstulberg.branchbar"

    /// The two paths a handout is ever installed to, and the only two paths the LaunchAgent will
    /// ever name. Both are fixed literals: neither is derived from `Bundle.main` — see the type's
    /// note on translocation — and the running bundle only ever *selects* between them.
    ///
    /// codex MAJOR 8: `/Applications` used to be the only accepted location, and a standard
    /// non-admin account on a managed Mac cannot write it. Such an account installs into the
    /// per-user `~/Applications`, where the whole feature was refused. macOS treats that folder as
    /// an Applications folder for every purpose that matters here, so it is the second candidate.
    static let systemBundlePath = "/Applications/BranchBar.app"

    static var userBundlePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/BranchBar.app").path
    }

    /// Fixed order, and the order the fallbacks are tried in: the shared folder first.
    static var installCandidateBundlePaths: [String] { [systemBundlePath, userBundlePath] }

    static func executablePath(inBundleAt bundlePath: String) -> String {
        bundlePath + "/Contents/MacOS/BranchBar"
    }

    /// What the running bundle's path is, as far as the login item is concerned.
    ///
    /// codex round 4, MAJOR 5: the three answers used to be two, and the missing one is the
    /// dangerous one. A path that *resolves* to an install candidate is not the same thing as an
    /// install candidate, and the LaunchAgent stores a path rather than an inode.
    enum InstallPathVerdict: Equatable {
        /// The running bundle is a candidate, and no component of that path is a symlink. This is
        /// the only verdict anything is registered under, and the path is the one that was walked.
        case canonical(String)
        /// The running bundle names a candidate whose path this app will not register, with the
        /// component that decided it.
        case refused(path: String, reason: String)
        /// The app is running from somewhere else entirely — a `swift run` build, a copy in
        /// Downloads — which `unavailableReason` refuses ahead of every mechanism.
        case elsewhere(String)
    }

    /// Read once. The bundle a process is running from cannot change while it runs, and the walk
    /// below is `lstat` per component, so memoizing costs nothing but keeps the refusal to one
    /// line in the log rather than one per property read.
    private static var cachedInstallVerdict: InstallPathVerdict?

    static var installPathVerdict: InstallPathVerdict {
        if let cachedInstallVerdict { return cachedInstallVerdict }
        let verdict = deriveInstallPathVerdict()
        cachedInstallVerdict = verdict
        if case .refused(let path, let reason) = verdict {
            Log.info("launch at login: refusing \(path) as an install location, \(reason)")
        }
        return verdict
    }

    private static func deriveInstallPathVerdict() -> InstallPathVerdict {
        let running = Bundle.main.bundlePath
        // Textual equality, deliberately: `resolvingSymlinksInPath` on both sides is exactly what
        // made `~/Applications/BranchBar.app -> ~/Downloads/BranchBar.app` read as "installed in
        // Applications" while the plist stored the link (codex round 4, MAJOR 5).
        guard let candidate = installCandidateBundlePaths.first(where: { $0 == running }) else {
            return .elsewhere(running)
        }
        if let reason = symlinkComponentReason(candidate) {
            return .refused(path: candidate, reason: reason)
        }
        return .canonical(candidate)
    }

    /// Why a path is not one this app will register, or nil when every component of it is a real
    /// directory it looked at with `lstat` (codex round 4, MAJOR 5).
    ///
    /// The walk is per component from the root down, because `O_NOFOLLOW`'s lesson one level up
    /// holds here too: a check on the final component says nothing about the six lookups the
    /// kernel did to reach it. `~/Applications/BranchBar.app` pointing at `~/Downloads` is the
    /// obvious case, and `~/Applications` itself being a link is the one that hides: every
    /// component under it then names a folder someone else can retarget, and retargeting it
    /// changes what runs at the next login.
    ///
    /// `lstat` neither follows a link nor blocks — the two reasons it is the call used here rather
    /// than `FileManager` (ARCHITECTURE.md §8). The last component only has to exist and not be a
    /// link; whether it is the bundle directory or the executable inside it is the caller's
    /// question.
    static func symlinkComponentReason(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return "\(path) is not an absolute path" }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { return "\(path) is the root folder" }

        var walked = ""
        for (index, component) in components.enumerated() {
            guard component != ".", component != ".." else {
                return "\(path) is not a plain path (it contains \(component))"
            }
            walked += "/" + component
            var status = stat()
            guard lstat(walked, &status) == 0 else {
                return "\(walked) could not be read (\(String(cString: strerror(errno))))"
            }
            if status.st_mode & S_IFMT == S_IFLNK {
                return "\(walked) is a symbolic link"
            }
            let isLast = index == components.count - 1
            if !isLast, status.st_mode & S_IFMT != S_IFDIR {
                return "\(walked) is not a folder"
            }
        }
        return nil
    }

    /// Which candidate the running process *is*, or nil when it is neither — or when it names one
    /// through a symlink, which is not the same thing (codex round 4, MAJOR 5). This is the one
    /// place a path is chosen, and it chooses between two literals rather than trusting
    /// `Bundle.main`'s own path: a translocated copy matches neither and is refused ahead of this
    /// by `isTranslocated`.
    static var runningInstallBundlePath: String? {
        guard case .canonical(let path) = installPathVerdict else { return nil }
        return path
    }

    /// The path the LaunchAgent names: the candidate this process is running from, and the shared
    /// folder when it is running from neither (in which case `unavailableReason` has already
    /// refused the toggle and nothing is written).
    static var installedBundlePath: String { runningInstallBundlePath ?? systemBundlePath }
    static var installedExecutablePath: String { executablePath(inBundleAt: installedBundlePath) }

    static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")
    }

    // MARK: - Whether the toggle can be offered at all

    /// Nil when the toggle is usable; otherwise the sentence to put beside a disabled toggle.
    ///
    /// codex MAJOR 14: the path check is here, ahead of both mechanisms, rather than inside the
    /// LaunchAgent branch. `SMAppService.register()` registers whatever bundle is running, so a
    /// copy opened from `~/Downloads` — non-translocated, correct identifier — used to reach
    /// `register()` and pin the login item to a folder the user will empty, while the LaunchAgent
    /// branch it fell back to named `/Applications/BranchBar.app` unconditionally. One toggle
    /// registering two different bundles depending on which branch ran is why this is a
    /// precondition of the toggle rather than a step inside it.
    static var unavailableReason: String? {
        guard Bundle.main.bundleIdentifier != nil else { return Strings.launchAtLoginUnbundled }
        if isTranslocated { return Strings.launchAtLoginTranslocated }
        if !isRunningFromApplications { return Strings.launchAtLoginNotInApplications }
        return nil
    }

    static var isAvailable: Bool { unavailableReason == nil }

    /// The one place `Bundle.main.bundlePath` is read, and it is read only to distrust it.
    static var isTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    /// Whether the running bundle *is* one of the two install candidates, by the path it was
    /// launched from and with no component of that path a symlink.
    static var isRunningFromApplications: Bool { runningInstallBundlePath != nil }

    // MARK: - Current state

    /// `SMAppService.mainApp.status`, or nil where asking is meaningless (no bundle identifier, so
    /// no main app for the framework to look up).
    static var serviceStatus: SMAppService.Status? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return SMAppService.mainApp.status
    }

    // MARK: - One reading of the LaunchAgent, per launch

    /// Everything this file knows about the login item, read once and then remembered until
    /// something here changes it (codex round 3, BLOCKER 2 and MAJOR 5).
    ///
    /// Every property below is derived from one of these rather than from its own read. Before, a
    /// single `logCurrentState()` opened `~/Library/LaunchAgents/com.hannahstulberg.branchbar.plist`
    /// three times and spawned `launchctl print` three more, all during
    /// `applicationDidFinishLaunching` and all with unbounded, path-based, symlink-following reads:
    /// a FIFO at that fixed pathname blocked the app's launch outright, and nothing above a blocked
    /// `open()` can end it.
    struct State {
        /// Something exists at the plist path. Established with `lstat`, which neither follows a
        /// symlink nor blocks on a FIFO, so "there is a file here" and "I read it" stay separate
        /// questions.
        var fileExists: Bool
        /// What `lstat` said it is, for the log: `regular`, `symlink`, `fifo`, and so on.
        var fileType: String
        /// The whole schema check: exactly our three keys, our label, `RunAtLoad`, and a `Program`
        /// naming either install candidate.
        var isOwnPlist: Bool
        /// `Program`, whatever it names.
        var plistProgram: String?
        /// launchd holds *something* under our label.
        var isLoaded: Bool
        /// The live `program =` from `launchctl print`. Nil when nothing is loaded, and also when
        /// something is loaded that has no `Program` of its own (a job carrying only
        /// `ProgramArguments`, or one submitted by another process) — which is precisely the case
        /// that used to read as "BranchBar's login item is on".
        var loadedProgram: String?

        /// The plist on disk is the one *this* build would write: our whole schema, and a
        /// `Program` naming the executable this copy of the app runs from.
        var matchesThisBuild: Bool
        /// The live job is one of ours: its program is an executable inside one of the two install
        /// candidates. Either candidate counts, for the same reason `isOwnLaunchAgentPlist`
        /// accepts either — a job the `/Applications` copy registered is still BranchBar's login
        /// item when the `~/Applications` copy is the one asking.
        var loadedProgramIsOurs: Bool
    }

    /// The read is memoized because it costs a file open and a `launchctl` process, and because
    /// the reviewer's rule is that a launch touches that pathname once. Every path in this file
    /// that changes the login item calls `invalidateState()`, so a flip is still followed by a
    /// fresh read rather than by a remembered answer.
    private static var cachedState: State?

    /// How many times this process has opened the plist path. Logged rather than assumed: "the
    /// launch touches that pathname once" is the invariant codex round 3 BLOCKER 2 asked for, and
    /// a counter in the launch log is what proves it on a real Mac.
    private(set) static var plistReadCount = 0

    static func invalidateState() { cachedState = nil }

    @discardableResult
    static func state(reloading: Bool = false) -> State {
        if !reloading, let cachedState { return cachedState }
        let fresh = readState()
        cachedState = fresh
        return fresh
    }

    /// A plist BranchBar wrote is 300-odd bytes. 64 KB is room for any file a person could
    /// plausibly have put there and a bound on one nobody should.
    static let maximumPlistBytes = 64 * 1024

    private static func readState() -> State {
        plistReadCount += 1
        let path = launchAgentURL.path
        let (exists, type) = fileType(atPath: path)

        var plist: [String: Any]?
        if exists, type == "regular", let data = boundedPlistData(atPath: path) {
            plist = (try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)) as? [String: Any]
        }
        let program = plist?["Program"] as? String
        let isOwnPlist = plist.map(isOwnLaunchAgentPlist) ?? false

        let printed = launchctl(["print", "\(guiDomain)/\(bundleID)"])
        let loadedProgram = printed.status == 0
            ? programPath(inLaunchctlPrint: printed.output)
            : nil
        let ourPrograms = installCandidateBundlePaths.map(executablePath(inBundleAt:))

        return State(
            fileExists: exists,
            fileType: type,
            isOwnPlist: isOwnPlist,
            plistProgram: program,
            isLoaded: printed.status == 0,
            loadedProgram: loadedProgram,
            matchesThisBuild: isOwnPlist && program == installedExecutablePath,
            loadedProgramIsOurs: loadedProgram.map(ourPrograms.contains) ?? false)
    }

    /// What is at a path, without following a symlink and without opening anything. `lstat` cannot
    /// block, so this is the safe half of "is there a file here".
    private static func fileType(atPath path: String) -> (exists: Bool, type: String) {
        var status = stat()
        guard lstat(path, &status) == 0 else { return (false, "absent") }
        switch status.st_mode & S_IFMT {
        case S_IFREG: return (true, "regular")
        case S_IFLNK: return (true, "symlink")
        case S_IFIFO: return (true, "fifo")
        case S_IFDIR: return (true, "directory")
        case S_IFSOCK: return (true, "socket")
        case S_IFCHR, S_IFBLK: return (true, "device")
        default: return (true, "other")
        }
    }

    /// The plist path is read the way every repository-owned file in this app is read: an FD open
    /// that refuses a symlink and cannot block, an `fstat` type check on the descriptor already
    /// opened, and a bounded `pread` (codex round 3, BLOCKER 2). `Data(contentsOf:)` and
    /// `String(contentsOf:)` were both of the things ARCHITECTURE.md §8 warns about — unbounded,
    /// and blocked forever on a FIFO at a fixed, guessable pathname.
    ///
    /// `RealFileSystem.readBoundedRegularFile` is that primitive; using Core's rather than a
    /// second copy here is what keeps the two from drifting.
    private static func boundedPlistData(atPath path: String) -> Data? {
        try? RealFileSystem().readBoundedRegularFile(
            path: path, maxBytes: maximumPlistBytes, tail: false)
    }

    /// The live `program =` line out of `launchctl print gui/<uid>/<label>`.
    ///
    /// Pure, so the grammar can be exercised from the probe without a job being loaded. The key is
    /// matched exactly: `launchctl` also prints `program identifier = …` for a job another process
    /// submitted, and that is not a program path.
    static func programPath(inLaunchctlPrint output: String) -> String? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            guard key == "program" else { continue }
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static var hasLaunchAgentPlist: Bool { state().fileExists }

    /// The complete set of keys BranchBar's own LaunchAgent has. Membership is checked by equality,
    /// not by lookup, which is what makes an extra key a rejection rather than something ignored.
    static let launchAgentPlistKeys: Set<String> = ["Label", "Program", "RunAtLoad"]

    /// The plist BranchBar would have written, rather than any file that happens to sit at that
    /// path (codex MINOR 1). A stale plist from an older install, or one someone dropped there,
    /// names a different `Program` and is not this app's login item.
    ///
    /// codex MAJOR 8: checking `Label` and `Program` was not enough. launchd reads every key it
    /// finds, so a file carrying our label and our program *plus* `KeepAlive` relaunches the app
    /// the user just quit, and one carrying `ProgramArguments` or `EnvironmentVariables` runs our
    /// binary with an argv and an environment we never chose — while the toggle read "on" and the
    /// disable path deleted the file as if it had been ours all along. The whole dictionary is now
    /// the thing that is validated: exactly `Label`, `Program`, and `RunAtLoad`, nothing else.
    static var hasOwnLaunchAgentPlist: Bool { state().isOwnPlist }

    /// Pure half of `hasOwnLaunchAgentPlist`, so the schema rule can be exercised without a file.
    static func isOwnLaunchAgentPlist(_ plist: [String: Any]) -> Bool {
        guard Set(plist.keys) == launchAgentPlistKeys else { return false }
        guard plist["Label"] as? String == bundleID else { return false }
        // Either install location is ours: a plist written by the copy in `/Applications` is still
        // BranchBar's login item when the copy in `~/Applications` is the one asking.
        let ourPrograms = installCandidateBundlePaths.map(executablePath(inBundleAt:))
        guard let program = plist["Program"] as? String, ourPrograms.contains(program) else {
            return false
        }
        guard let runAtLoad = plist["RunAtLoad"] as? Bool, runAtLoad else { return false }
        return true
    }

    /// Whether launchd is holding *anything* under our label right now. `launchctl print` exits 0
    /// for a loaded job and non-zero otherwise, which is the only question a file on disk cannot
    /// answer: a plist can exist while nothing is loaded, and a job can stay loaded for the
    /// session after its plist is gone.
    ///
    /// This says nothing about *what* is loaded — see `isOurLaunchAgentLoaded`.
    static var isLaunchAgentLoaded: Bool { state().isLoaded }

    /// Whether the job launchd is holding under our label is BranchBar (codex round 3, MAJOR 5).
    ///
    /// A successful `launchctl print` used to be the whole check, so a job someone else had loaded
    /// under `com.hannahstulberg.branchbar` — or one of ours from an install that has since been
    /// replaced — made the toggle read "on" while the live job named another program. launchd is
    /// keyed by label, not by file, and the label is a fixed string in a shipped app: the question
    /// the toggle has to answer is what the live job's `program =` says.
    static var isOurLaunchAgentLoaded: Bool { state().loadedProgramIsOurs }

    static var mechanism: Mechanism {
        if hasOwnLaunchAgentPlist, isOurLaunchAgentLoaded { return .launchAgent }
        if serviceStatus == .enabled { return .serviceManagement }
        return .off
    }

    /// The toggle's value. `.requiresApproval` counts as on: BranchBar asked, the registration
    /// exists, and the only thing left is the switch in System Settings — showing the toggle off
    /// there would ask the user to register something that is already registered.
    ///
    /// codex MINOR 1: the fallback's half of this used to be "a file exists at that path", so any
    /// stale or tampered file made the toggle read on. It is now this app's own plist *and* a job
    /// launchd says is loaded — and, since codex round 3 MAJOR 5, a live job whose `program =` is
    /// one of BranchBar's own executables.
    static var isEnabled: Bool {
        if hasOwnLaunchAgentPlist, isOurLaunchAgentLoaded { return true }
        return isRegistered(serviceStatus)
    }

    static var needsApproval: Bool {
        !(hasOwnLaunchAgentPlist && isOurLaunchAgentLoaded) && serviceStatus == .requiresApproval
    }

    // MARK: - Flipping it

    enum Failure: LocalizedError {
        case unavailable(String)
        case notInstalledInApplications
        case bothMechanismsRefused(String)
        /// `launchctl bootout` failed and the job is still loaded, so the login item is still live
        /// (codex MINOR 1). Reported rather than swallowed, and the plist is left where it is.
        case couldNotUnload(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let copy): return copy
            case .notInstalledInApplications: return Strings.launchAtLoginNotInApplications
            case .bothMechanismsRefused, .couldNotUnload: return Strings.launchAtLoginFailed
            }
        }

        /// For the log only. `errorDescription` is what a person reads.
        var diagnostic: String {
            switch self {
            case .unavailable(let copy): return copy
            case .notInstalledInApplications: return "no valid bundle at /Applications/BranchBar.app"
            case .bothMechanismsRefused(let detail): return detail
            case .couldNotUnload(let detail): return detail
            }
        }
    }

    /// Turns the login item on or off, preferring `SMAppService` and falling back to a LaunchAgent
    /// when the framework will not hold the registration. Throws only when neither worked; a
    /// `.requiresApproval` outcome is a success that `needsApproval` then reports.
    static func set(_ enabled: Bool) throws {
        if let reason = unavailableReason {
            Log.info("launch at login: refused, \(reason)")
            throw Failure.unavailable(reason)
        }
        if enabled { try enable() } else { try disable() }
        Log.info(
            "launch at login: now \(isEnabled ? "on" : "off") · mechanism=\(mechanism.rawValue) "
                + "· SMAppService status=\(statusDescription(serviceStatus))")
    }

    private static func enable() throws {
        var diagnostics: [String] = []

        do {
            try SMAppService.mainApp.register()
            let status = SMAppService.mainApp.status
            Log.info("launch at login: SMAppService.register() returned, status=\(statusDescription(status))")
            if status == .enabled || status == .requiresApproval { return }
            diagnostics.append("SMAppService status after register: \(statusDescription(status))")
        } catch {
            Log.info("launch at login: SMAppService.register() threw \(error)")
            diagnostics.append("SMAppService.register(): \(error)")
        }

        // The fallback names an absolute path, so that path has to hold *this* app's bundle —
        // the right identifier and a real executable, not merely a file (codex MAJOR 14).
        guard isInstalledBundleValid else {
            throw Failure.notInstalledInApplications
        }

        // What this build wants loaded, and the value every check below is against.
        let wanted = installedExecutablePath
        var live = state(reloading: true)

        // Nothing to do only when the file on disk is the plist this build would write *and* the
        // job launchd is holding names this build's own executable. Both halves matter now that
        // there are two install locations: a job loaded from the `/Applications` plist is not the
        // job the `~/Applications` copy wants, and `launchctl print` exiting 0 says only that the
        // label is taken (codex round 3, MAJOR 5).
        if live.matchesThisBuild, live.loadedProgram == wanted {
            Log.info(
                "launch at login: the agent is already loaded from the plist this build writes "
                    + "(live program=\(wanted))")
            return
        }

        // codex round 3, MAJOR 5: whenever the disk or the live job differs from what this build
        // wants, the label is booted out *before* the bootstrap. Without this, a foreign job under
        // our label made `bootstrap` fail as already-loaded, the retry's bootout was skipped
        // because something was loaded, and the final check passed on that same foreign job — the
        // toggle read on while the live job named another program.
        if live.isLoaded, live.loadedProgram != wanted {
            let bootout = launchctl(["bootout", "\(guiDomain)/\(bundleID)"])
            Log.info(
                "launch at login: booting out the job already loaded as \(bundleID) "
                    + "(live program=\(live.loadedProgram ?? "none")) before bootstrap, "
                    + "exit=\(bootout.status) \(bootout.output)")
            invalidateState()
        }

        do {
            try writeLaunchAgent()
        } catch {
            diagnostics.append("writing \(launchAgentURL.path): \(error)")
            throw Failure.bothMechanismsRefused(diagnostics.joined(separator: " · "))
        }

        var bootstrap = launchctl(["bootstrap", guiDomain, launchAgentURL.path])
        Log.info(
            "launch at login: launchctl bootstrap exit=\(bootstrap.status) "
                + "(\(errnoDescription(bootstrap.status))) \(bootstrap.output) "
                + "alreadyLoadedCode=\(Self.alreadyLoadedExitCodes.contains(bootstrap.status))")

        // codex MAJOR 8: the exit code is no longer what decides. `launchctl print` is asked
        // instead, because the codes overlap: errno 5, 17, and 37 are what a bootstrap of an
        // already-loaded job reports (REVIEW WR-05) *and* what several unrelated refusals report,
        // so treating them as success meant the toggle could read on with nothing registered.
        live = state(reloading: true)
        if live.loadedProgram != wanted {
            // One retry, through a bootout, rather than deleting the plist: the old code removed
            // the file it had just written while launchd kept the job for the session, so the
            // toggle read off, the app still opened at the next login, and stopped after that.
            let bootout = launchctl(["bootout", "\(guiDomain)/\(bundleID)"])
            Log.info("launch at login: bootout before retry exit=\(bootout.status) \(bootout.output)")
            bootstrap = launchctl(["bootstrap", guiDomain, launchAgentURL.path])
            Log.info(
                "launch at login: launchctl bootstrap retry exit=\(bootstrap.status) "
                    + "(\(errnoDescription(bootstrap.status))) \(bootstrap.output)")
            live = state(reloading: true)
        }

        Log.info(
            "launch at login: verified live program=\(live.loadedProgram ?? "none") "
                + "wanted=\(wanted) loaded=\(live.isLoaded)")
        guard live.loadedProgram == wanted else {
            diagnostics.append(
                "launchctl bootstrap exit \(bootstrap.status) "
                    + "(\(errnoDescription(bootstrap.status))): \(bootstrap.output) · "
                    + "launchctl print \(guiDomain)/\(bundleID) reports program "
                    + "\(live.loadedProgram ?? "none") rather than \(wanted)")
            throw Failure.bothMechanismsRefused(diagnostics.joined(separator: " · "))
        }
    }

    /// `launchctl error 5|17|37` on macOS 24 prints "Input/output error", "File exists", and
    /// "Operation already in progress". A bootstrap of an already-loaded job reports one of them
    /// (REVIEW WR-05), which is why they were once accepted as success; they are logged now and
    /// decide nothing, because `launchctl print` answers the same question without the ambiguity
    /// (codex MAJOR 8).
    static let alreadyLoadedExitCodes: Set<Int32> = [5, 17, 37]

    /// The bundle the LaunchAgent would name, checked rather than assumed: `CFBundleIdentifier`
    /// equal to ours and an executable file where the plist's `Program` points. The path checked is
    /// the one this process resolved itself to, so a Mac holding a copy in both Applications
    /// folders validates the copy the toggle was clicked in.
    static var isInstalledBundleValid: Bool {
        // codex round 4, MAJOR 5: the plist names `installedExecutablePath`, so that whole path —
        // not just the bundle root — is what has to be free of links before it is written down.
        if let reason = symlinkComponentReason(installedExecutablePath) {
            Log.info(
                "launch at login: refusing to register \(installedExecutablePath), \(reason)")
            return false
        }
        guard FileManager.default.isExecutableFile(atPath: installedExecutablePath) else {
            return false
        }
        guard let bundle = Bundle(path: installedBundlePath),
              bundle.bundleIdentifier == bundleID
        else { return false }
        return true
    }

    private static func errnoDescription(_ status: Int32) -> String {
        guard status > 0 else { return "—" }
        return String(cString: strerror(status))
    }

    /// Both mechanisms are torn down, not just the one that is live: a Mac that fell back once can
    /// have a plist on disk *and* a registration, and leaving either behind means the app still
    /// opens at login after the user turned the toggle off.
    private static func disable() throws {
        // codex MAJOR 8: the bootout used to be gated on a plist existing, and a loaded job whose
        // plist was deleted — by an uninstall script, by a previous half-finished disable, by the
        // user — therefore stayed live while the toggle reported off. launchd is keyed by label,
        // not by file, so the question is whether anything is loaded under that label.
        if state(reloading: true).isLoaded {
            let bootout = launchctl(["bootout", "\(guiDomain)/\(bundleID)"])
            Log.info("launch at login: launchctl bootout exit=\(bootout.status) \(bootout.output)")
            invalidateState()
            // codex MINOR 1: a failed bootout used to be ignored and the plist deleted anyway, so
            // the toggle read off while the job stayed loaded for the session. The plist stays put
            // when the job is still loaded — it is the only record of what to boot out next time —
            // and the failure is reported. What is checked is `launchctl print` after the fact,
            // not the bootout's own exit code.
            if state(reloading: true).isLoaded {
                throw Failure.couldNotUnload(
                    "launchctl bootout exit \(bootout.status): \(bootout.output) · the job is "
                        + "still loaded in \(guiDomain)")
            }
        }
        if state().fileExists {
            do {
                try FileManager.default.removeItem(at: launchAgentURL)
                invalidateState()
            } catch {
                invalidateState()
                Log.info("launch at login: could not remove \(launchAgentURL.path): \(error)")
                throw Failure.couldNotUnload("removing \(launchAgentURL.path): \(error)")
            }
        }
        guard Bundle.main.bundleIdentifier != nil else { return }
        // codex MAJOR 8: an `unregister()` that threw used to be logged and swallowed, so a
        // registration the framework refused to drop was reported as a login item turned off. The
        // failure is propagated — but only when the registration is still there afterwards, since
        // `unregister()` throws on an app that was never registered and that is the state asked for.
        do {
            try SMAppService.mainApp.unregister()
            let status = SMAppService.mainApp.status
            Log.info(
                "launch at login: SMAppService.unregister() returned, status="
                    + statusDescription(status))
            if isRegistered(status) {
                throw Failure.couldNotUnload(
                    "SMAppService.unregister() returned but status is \(statusDescription(status))")
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            let status = SMAppService.mainApp.status
            Log.info(
                "launch at login: SMAppService.unregister() threw \(error), status="
                    + statusDescription(status))
            if isRegistered(status) {
                throw Failure.couldNotUnload(
                    "SMAppService.unregister(): \(error) · status is still "
                        + statusDescription(status))
            }
        }
    }

    /// Whether `SMAppService` still holds a registration. `.requiresApproval` counts, for the same
    /// reason `isEnabled` counts it: the registration exists and the app will open at login once
    /// the switch in System Settings is flipped.
    static func isRegistered(_ status: SMAppService.Status?) -> Bool {
        switch status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    // MARK: - The LaunchAgent

    private static var guiDomain: String { "gui/\(getuid())" }

    /// `RunAtLoad` and nothing else: no `KeepAlive`, so quitting BranchBar keeps it quit until the
    /// next login rather than having launchd restart the app the user just closed.
    ///
    /// The dictionary, not the XML, is the definition — and `isOwnLaunchAgentPlist` validates the
    /// same three keys, so what this build writes and what it will later accept are one rule.
    static var launchAgentPlist: [String: Any] {
        ["Label": bundleID, "Program": installedExecutablePath, "RunAtLoad": true]
    }

    /// codex round 3, MINOR 1: the plist was assembled by string interpolation, so a `Program`
    /// path containing `&` or `<` — a managed home directory is a path a person does not choose —
    /// produced XML launchd refuses to parse, and the toggle failed with nothing on screen naming
    /// the reason. `PropertyListSerialization` escapes what it serializes, and the encoder is now
    /// the same one that reads the file back.
    static func launchAgentPlistData() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: launchAgentPlist, format: .xml, options: 0)
    }

    private static func writeLaunchAgent() throws {
        let directory = launchAgentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try launchAgentPlistData().write(to: launchAgentURL, options: [.atomic])
        invalidateState()
        Log.info("launch at login: wrote \(launchAgentURL.path) naming \(installedExecutablePath)")
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "could not run launchctl: \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, text)
    }

    // MARK: - Logging

    /// One log-sized phrase per verdict, the refusal's reason included: "refused" without the
    /// component that decided it is a line a tester cannot act on.
    static func describe(_ verdict: InstallPathVerdict) -> String {
        switch verdict {
        case .canonical(let path): return "canonical(\(path))"
        case .refused(let path, let reason): return "refused(\(path): \(reason))"
        case .elsewhere(let path): return "elsewhere(\(path))"
        }
    }

    static func statusDescription(_ status: SMAppService.Status?) -> String {
        switch status {
        case .none: return "unavailable"
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(String(describing: status)))"
        }
    }

    /// One line for the launch log, so a tester's log says what the login item was without them
    /// having to open System Settings.
    ///
    /// codex round 3, BLOCKER 2: this used to read the plist path three times and spawn
    /// `launchctl print` three times, once per property it interpolated, during
    /// `applicationDidFinishLaunching`. Now it takes one `State` and reads every field off it, so
    /// the fixed pathname is touched once per launch — and once more only after a flip, which
    /// invalidates it.
    static func logCurrentState() {
        let live = state()
        Log.info(
            "launch at login: available=\(isAvailable) enabled=\(isEnabled) "
                + "mechanism=\(mechanism.rawValue) SMAppService status=\(statusDescription(serviceStatus)) "
                + "translocated=\(isTranslocated) inApplications=\(isRunningFromApplications) "
                + "installPath=\(runningInstallBundlePath ?? "—") "
                + "installVerdict=\(describe(installPathVerdict)) "
                + "ownPlist=\(live.isOwnPlist) plistFile=\(live.fileType) "
                + "plistProgram=\(live.plistProgram ?? "—") "
                + "agentLoaded=\(live.isLoaded) liveProgram=\(live.loadedProgram ?? "—") "
                + "liveProgramIsOurs=\(live.loadedProgramIsOurs) "
                + "wantedProgram=\(installedExecutablePath) plistReads=\(plistReadCount) "
                + "bundleID=\(Bundle.main.bundleIdentifier ?? "—")")
    }
}
