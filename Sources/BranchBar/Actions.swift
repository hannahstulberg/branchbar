import AppKit
import BranchBarCore
import Foundation

/// Everything the shell does to the world outside the popover. PLAN.md §3 names the four row
/// actions (open in an editor, open the PR, show in Finder, copy the path) plus the folder picker
/// that is the TCC rescue; packet 4.2 adds per-row Hide and launch at login on top of these.
///
/// `SMAppService` is deliberately absent: it belongs to packet 4.2 and the footer toggle here is
/// a disabled placeholder that says so.
@MainActor
enum Actions {

    // MARK: - Which editors this Mac has

    /// Cursor ships under a ToDesktop identifier, not a `com.cursor.*` one.
    static let cursorBundleID = "com.todesktop.230313mzl4w4u92"
    static let vsCodeBundleID = "com.microsoft.VSCode"

    /// Asked once per launch: `urlForApplication` hits Launch Services, and an installed editor
    /// does not appear or vanish while the popover is open.
    static let editors: EditorAvailability = EditorAvailability(
        cursor: isInstalled(bundleID: cursorBundleID),
        vsCode: isInstalled(bundleID: vsCodeBundleID)
    )

    static func isInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    // MARK: - Opening a folder

    /// PLAN.md §3's fallback chain: Cursor → VS Code → Terminal. Terminal is always present, which
    /// is why the chain ends there and there is no fourth step.
    static func openInAvailableEditor(path: String) {
        if editors.cursor {
            openInCursor(path: path)
        } else if editors.vsCode {
            openInVSCode(path: path)
        } else {
            openInTerminal(path: path)
        }
    }

    static func openInCursor(path: String) { open(application: "Cursor", path: path) }
    static func openInVSCode(path: String) { open(application: "Visual Studio Code", path: path) }
    static func openInTerminal(path: String) { open(application: "Terminal", path: path) }

    /// `open -a <App> <path>`, exactly as §3 froze it. `/usr/bin/open` is used rather than
    /// `NSWorkspace.open(_:withApplicationAt:…)` so the invocation in the log is the one a tester
    /// can paste into a shell to reproduce what the row did.
    private static func open(application: String, path: String) {
        Log.info("action: open -a \"\(application)\" \(path)")
        run("/usr/bin/open", ["-a", application, path])
    }

    // MARK: - The other row actions

    static func openPR(url: String) {
        guard let parsed = URL(string: url), parsed.scheme == "http" || parsed.scheme == "https" else {
            Log.info("action: open PR refused, not an http(s) address: \(url)")
            return
        }
        Log.info("action: open PR \(url)")
        NSWorkspace.shared.open(parsed)
    }

    static func revealInFinder(path: String) {
        Log.info("action: show in Finder \(path)")
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func copyPath(_ path: String) {
        Log.info("action: copy path \(path)")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    /// The `gh auth login` setup action. Packet 4.2 owns driving Terminal to run the command; 4.1
    /// gets the user to the prompt with the line on the clipboard, which needs no scripting grant.
    static func openTerminalForSignIn(command: String?) {
        if let command {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(command, forType: .string)
            Log.info("action: copied sign-in command to the clipboard: \(command)")
        }
        openInTerminal(path: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    // MARK: - Add folder…

    /// The TCC rescue (PLAN.md §8 moved it into this packet for exactly that reason): the user
    /// picking a folder is what grants BranchBar the right to read it.
    static func pickFolder() -> URL? {
        Log.info("action: add folder (opening panel)")

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = Strings.addFolderActionLabel
        panel.message = Strings.emptyStateMessage

        // An accessory app is never frontmost, so the panel would open behind everything.
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else {
            Log.info("action: add folder cancelled")
            return nil
        }
        Log.info("action: add folder \(url.path)")
        return url
    }

    // MARK: - Quit

    static func quit() {
        Log.info("action: quit")
        NSApp.terminate(nil)
    }

    // MARK: - Process

    /// Fire and forget: nothing in the popover waits on an editor launching.
    private static func run(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            Log.info("action failed: \(executable) \(arguments.joined(separator: " ")): \(error)")
        }
    }
}
