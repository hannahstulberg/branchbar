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

    /// Which candidate the running process *is*, or nil when it is neither. This is the one place a
    /// path is chosen, and it chooses between two literals rather than trusting `Bundle.main`'s own
    /// path: a translocated copy matches neither and is refused ahead of this by `isTranslocated`.
    static var runningInstallBundlePath: String? {
        let running = resolved(Bundle.main.bundlePath)
        return installCandidateBundlePaths.first { resolved($0) == running }
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

    /// Whether the running bundle *is* one of the two install candidates, symlinks and `/private`
    /// prefixes resolved on both sides so `/tmp/…` and `/private/tmp/…` are not two answers.
    static var isRunningFromApplications: Bool { runningInstallBundlePath != nil }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - Current state

    /// `SMAppService.mainApp.status`, or nil where asking is meaningless (no bundle identifier, so
    /// no main app for the framework to look up).
    static var serviceStatus: SMAppService.Status? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return SMAppService.mainApp.status
    }

    static var hasLaunchAgentPlist: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

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
    static var hasOwnLaunchAgentPlist: Bool {
        guard let data = try? Data(contentsOf: launchAgentURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return false }
        return isOwnLaunchAgentPlist(plist)
    }

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

    /// Whether launchd is actually holding the job right now. `launchctl print` exits 0 for a
    /// loaded job and non-zero otherwise, which is the only question a file on disk cannot answer:
    /// a plist can exist while nothing is loaded, and a job can stay loaded for the session after
    /// its plist is gone.
    static var isLaunchAgentLoaded: Bool {
        launchctl(["print", "\(guiDomain)/\(bundleID)"]).status == 0
    }

    static var mechanism: Mechanism {
        if hasOwnLaunchAgentPlist, isLaunchAgentLoaded { return .launchAgent }
        if serviceStatus == .enabled { return .serviceManagement }
        return .off
    }

    /// The toggle's value. `.requiresApproval` counts as on: BranchBar asked, the registration
    /// exists, and the only thing left is the switch in System Settings — showing the toggle off
    /// there would ask the user to register something that is already registered.
    ///
    /// codex MINOR 1: the fallback's half of this used to be "a file exists at that path", so any
    /// stale or tampered file made the toggle read on. It is now this app's own plist *and* a job
    /// launchd says is loaded.
    static var isEnabled: Bool {
        if hasOwnLaunchAgentPlist, isLaunchAgentLoaded { return true }
        return isRegistered(serviceStatus)
    }

    static var needsApproval: Bool {
        !(hasOwnLaunchAgentPlist && isLaunchAgentLoaded) && serviceStatus == .requiresApproval
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

        // Nothing to do only when the file on disk is byte-for-byte the plist this build would
        // write *and* launchd is holding it. Comparing the text rather than asking
        // `hasOwnLaunchAgentPlist` matters now that there are two install locations: a job loaded
        // from the `/Applications` plist is not the job the `~/Applications` copy wants.
        let alreadyCorrect = (try? String(contentsOf: launchAgentURL, encoding: .utf8))
            == launchAgentPlistXML
        if alreadyCorrect, isLaunchAgentLoaded {
            Log.info("launch at login: the agent is already loaded from the plist this build writes")
            return
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
        if !isLaunchAgentLoaded {
            // One retry, through a bootout, rather than deleting the plist: the old code removed
            // the file it had just written while launchd kept the job for the session, so the
            // toggle read off, the app still opened at the next login, and stopped after that.
            let bootout = launchctl(["bootout", "\(guiDomain)/\(bundleID)"])
            Log.info("launch at login: bootout before retry exit=\(bootout.status) \(bootout.output)")
            bootstrap = launchctl(["bootstrap", guiDomain, launchAgentURL.path])
            Log.info(
                "launch at login: launchctl bootstrap retry exit=\(bootstrap.status) "
                    + "(\(errnoDescription(bootstrap.status))) \(bootstrap.output)")
        }

        let verification = launchctl(["print", "\(guiDomain)/\(bundleID)"])
        Log.info("launch at login: launchctl print exit=\(verification.status) (the loaded check)")
        guard verification.status == 0 else {
            diagnostics.append(
                "launchctl bootstrap exit \(bootstrap.status) "
                    + "(\(errnoDescription(bootstrap.status))): \(bootstrap.output) · "
                    + "launchctl print \(guiDomain)/\(bundleID) exit \(verification.status), "
                    + "so nothing is loaded")
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
        if isLaunchAgentLoaded {
            let bootout = launchctl(["bootout", "\(guiDomain)/\(bundleID)"])
            Log.info("launch at login: launchctl bootout exit=\(bootout.status) \(bootout.output)")
            // codex MINOR 1: a failed bootout used to be ignored and the plist deleted anyway, so
            // the toggle read off while the job stayed loaded for the session. The plist stays put
            // when the job is still loaded — it is the only record of what to boot out next time —
            // and the failure is reported. What is checked is `launchctl print` after the fact,
            // not the bootout's own exit code.
            if isLaunchAgentLoaded {
                throw Failure.couldNotUnload(
                    "launchctl bootout exit \(bootout.status): \(bootout.output) · the job is "
                        + "still loaded in \(guiDomain)")
            }
        }
        if hasLaunchAgentPlist {
            do {
                try FileManager.default.removeItem(at: launchAgentURL)
            } catch {
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
    static var launchAgentPlistXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(bundleID)</string>
        \t<key>Program</key>
        \t<string>\(installedExecutablePath)</string>
        \t<key>RunAtLoad</key>
        \t<true/>
        </dict>
        </plist>

        """
    }

    private static func writeLaunchAgent() throws {
        let directory = launchAgentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try launchAgentPlistXML.write(to: launchAgentURL, atomically: true, encoding: .utf8)
        Log.info("launch at login: wrote \(launchAgentURL.path)")
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
    static func logCurrentState() {
        Log.info(
            "launch at login: available=\(isAvailable) enabled=\(isEnabled) "
                + "mechanism=\(mechanism.rawValue) SMAppService status=\(statusDescription(serviceStatus)) "
                + "translocated=\(isTranslocated) inApplications=\(isRunningFromApplications) "
                + "installPath=\(runningInstallBundlePath ?? "—") "
                + "ownPlist=\(hasOwnLaunchAgentPlist) agentLoaded=\(isLaunchAgentLoaded) "
                + "bundleID=\(Bundle.main.bundleIdentifier ?? "—")")
    }
}
