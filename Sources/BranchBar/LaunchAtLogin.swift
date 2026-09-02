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

    /// The handout's install path, and the only path the LaunchAgent will ever name. Never derived
    /// from `Bundle.main` — see the type's note on translocation.
    static let installedBundlePath = "/Applications/BranchBar.app"
    static var installedExecutablePath: String { installedBundlePath + "/Contents/MacOS/BranchBar" }

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

    /// Whether the running bundle *is* `/Applications/BranchBar.app`, symlinks and `/private`
    /// prefixes resolved on both sides so `/tmp/…` and `/private/tmp/…` are not two answers.
    static var isRunningFromApplications: Bool {
        resolved(Bundle.main.bundlePath) == resolved(installedBundlePath)
    }

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

    /// The plist BranchBar would have written, rather than any file that happens to sit at that
    /// path (codex MINOR 1). A stale plist from an older install, or one someone dropped there,
    /// names a different `Program` and is not this app's login item.
    static var hasOwnLaunchAgentPlist: Bool {
        guard let data = try? Data(contentsOf: launchAgentURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return false }
        return plist["Label"] as? String == bundleID
            && plist["Program"] as? String == installedExecutablePath
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
        switch serviceStatus {
        case .enabled, .requiresApproval: return true
        default: return false
        }
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

        do {
            try writeLaunchAgent()
        } catch {
            diagnostics.append("writing \(launchAgentURL.path): \(error)")
            throw Failure.bothMechanismsRefused(diagnostics.joined(separator: " · "))
        }

        if isLaunchAgentLoaded {
            Log.info("launch at login: the agent is already loaded; nothing to bootstrap")
            return
        }

        var bootstrap = launchctl(["bootstrap", guiDomain, launchAgentURL.path])
        Log.info(
            "launch at login: launchctl bootstrap exit=\(bootstrap.status) "
                + "(\(errnoDescription(bootstrap.status))) \(bootstrap.output)")

        // REVIEW WR-05: "already loaded" is errno 5 on older releases, 37 on newer ones, and 17
        // where the plist path itself is already known. All three mean the state we wanted.
        if !Self.alreadyLoadedExitCodes.contains(bootstrap.status), bootstrap.status != 0 {
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

        guard bootstrap.status == 0 || Self.alreadyLoadedExitCodes.contains(bootstrap.status) else {
            diagnostics.append(
                "launchctl bootstrap exit \(bootstrap.status) "
                    + "(\(errnoDescription(bootstrap.status))): \(bootstrap.output)")
            throw Failure.bothMechanismsRefused(diagnostics.joined(separator: " · "))
        }
    }

    /// `launchctl error 5|17|37` on macOS 24 prints "Input/output error", "File exists", and
    /// "Operation already in progress"; all three are what a bootstrap of an already-loaded job
    /// reports, depending on the release.
    static let alreadyLoadedExitCodes: Set<Int32> = [5, 17, 37]

    /// The bundle the LaunchAgent would name, checked rather than assumed: `CFBundleIdentifier`
    /// equal to ours and an executable file where the plist's `Program` points.
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
        if hasLaunchAgentPlist {
            let bootout = launchctl(["bootout", "\(guiDomain)/\(bundleID)"])
            Log.info("launch at login: launchctl bootout exit=\(bootout.status) \(bootout.output)")
            // codex MINOR 1: a failed bootout used to be ignored and the plist deleted anyway, so
            // the toggle read off while the job stayed loaded for the session. The plist stays put
            // when the job is still loaded — it is the only record of what to boot out next time —
            // and the failure is reported.
            if bootout.status != 0, isLaunchAgentLoaded {
                throw Failure.couldNotUnload(
                    "launchctl bootout exit \(bootout.status): \(bootout.output)")
            }
            do {
                try FileManager.default.removeItem(at: launchAgentURL)
            } catch {
                Log.info("launch at login: could not remove \(launchAgentURL.path): \(error)")
                throw Failure.couldNotUnload("removing \(launchAgentURL.path): \(error)")
            }
        }
        guard Bundle.main.bundleIdentifier != nil else { return }
        do {
            try SMAppService.mainApp.unregister()
            Log.info(
                "launch at login: SMAppService.unregister() returned, status="
                    + statusDescription(SMAppService.mainApp.status))
        } catch {
            Log.info("launch at login: SMAppService.unregister() threw \(error)")
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
                + "ownPlist=\(hasOwnLaunchAgentPlist) agentLoaded=\(isLaunchAgentLoaded) "
                + "bundleID=\(Bundle.main.bundleIdentifier ?? "—")")
    }
}
