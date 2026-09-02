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
    static var unavailableReason: String? {
        guard Bundle.main.bundleIdentifier != nil else { return ShellStrings.launchAtLoginUnbundled }
        if isTranslocated { return ShellStrings.launchAtLoginTranslocated }
        return nil
    }

    static var isAvailable: Bool { unavailableReason == nil }

    /// The one place `Bundle.main.bundlePath` is read, and it is read only to distrust it.
    static var isTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
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

    static var mechanism: Mechanism {
        if hasLaunchAgentPlist { return .launchAgent }
        if serviceStatus == .enabled { return .serviceManagement }
        return .off
    }

    /// The toggle's value. `.requiresApproval` counts as on: BranchBar asked, the registration
    /// exists, and the only thing left is the switch in System Settings — showing the toggle off
    /// there would ask the user to register something that is already registered.
    static var isEnabled: Bool {
        if hasLaunchAgentPlist { return true }
        switch serviceStatus {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    static var needsApproval: Bool {
        !hasLaunchAgentPlist && serviceStatus == .requiresApproval
    }

    // MARK: - Flipping it

    enum Failure: LocalizedError {
        case unavailable(String)
        case notInstalledInApplications
        case bothMechanismsRefused(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let copy): return copy
            case .notInstalledInApplications: return ShellStrings.launchAtLoginNotInApplications
            case .bothMechanismsRefused: return ShellStrings.launchAtLoginFailed
            }
        }

        /// For the log only. `errorDescription` is what a person reads.
        var diagnostic: String {
            switch self {
            case .unavailable(let copy): return copy
            case .notInstalledInApplications: return "no bundle at /Applications/BranchBar.app"
            case .bothMechanismsRefused(let detail): return detail
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
        if enabled { try enable() } else { disable() }
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

        // The fallback names an absolute path, so that path has to hold a bundle.
        guard FileManager.default.fileExists(atPath: installedExecutablePath) else {
            throw Failure.notInstalledInApplications
        }

        do {
            try writeLaunchAgent()
        } catch {
            diagnostics.append("writing \(launchAgentURL.path): \(error)")
            throw Failure.bothMechanismsRefused(diagnostics.joined(separator: " · "))
        }

        let bootstrap = launchctl(["bootstrap", guiDomain, launchAgentURL.path])
        Log.info("launch at login: launchctl bootstrap exit=\(bootstrap.status) \(bootstrap.output)")
        // Exit 17 is EEXIST — the agent is already loaded, which is the state we wanted.
        guard bootstrap.status == 0 || bootstrap.status == 17 else {
            try? FileManager.default.removeItem(at: launchAgentURL)
            diagnostics.append("launchctl bootstrap exit \(bootstrap.status): \(bootstrap.output)")
            throw Failure.bothMechanismsRefused(diagnostics.joined(separator: " · "))
        }
    }

    /// Both mechanisms are torn down, not just the one that is live: a Mac that fell back once can
    /// have a plist on disk *and* a registration, and leaving either behind means the app still
    /// opens at login after the user turned the toggle off.
    private static func disable() {
        if hasLaunchAgentPlist {
            let bootout = launchctl(["bootout", "\(guiDomain)/\(bundleID)"])
            Log.info("launch at login: launchctl bootout exit=\(bootout.status) \(bootout.output)")
            do {
                try FileManager.default.removeItem(at: launchAgentURL)
            } catch {
                Log.info("launch at login: could not remove \(launchAgentURL.path): \(error)")
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
                + "translocated=\(isTranslocated) bundleID=\(Bundle.main.bundleIdentifier ?? "—")")
    }
}
