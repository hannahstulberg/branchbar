import AppKit
import BranchBarCore
import Foundation

/// Everything the shell does to the world outside the popover. PLAN.md §3 names the four row
/// actions (open in an editor, open the PR, show in Finder, copy the path) plus the folder picker
/// that is the TCC rescue; packet 4.2 added the `gh` sign-in Terminal action and the Privacy pane.
///
/// Launch at login is its own file (`LaunchAtLogin.swift`) because it owns persistent state on the
/// Mac and everything here is fire-and-forget.
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

    /// What `openInAvailableEditor` will actually do, in the words §5a froze for it. The chain is
    /// resolved in Core, by the same member `SnapshotPresenter` puts on a branch row's primary
    /// action, so a repo-header menu offering the same thing cannot name it differently.
    static var openInAvailableEditorLabel: String {
        Strings.openInAvailableEditorLabel(editors)
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

    /// The `gh auth login` setup action: PLAN.md §3's answer for a Mac where `gh` is installed but
    /// not signed in.
    ///
    /// Two routes were on the table and this one is the route that needs no grant. An AppleScript
    /// `tell application "Terminal" to do script …` is an Apple Event to another app, so the first
    /// use raises the Automation consent dialog ("BranchBar wants to control Terminal"), and on a
    /// managed Mac that prompt can be denied by policy — the handout would then have a button that
    /// silently does nothing. Writing an executable `.command` file and handing it to `open -a
    /// Terminal` is an ordinary document open: Terminal runs the script in a new window with no
    /// consent dialog and no Accessibility or Automation entry.
    ///
    /// The command is also left on the clipboard, so a user whose Terminal is not the default
    /// handler for `.command` still has the line to paste.
    static func openTerminalForSignIn(command: String?) {
        guard let command, !command.isEmpty else {
            openInTerminal(path: FileManager.default.homeDirectoryForCurrentUser.path)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)

        guard let script = writeSignInScript(command: command) else {
            Log.info("action: sign-in script could not be written; opening Terminal at home instead")
            openInTerminal(path: FileManager.default.homeDirectoryForCurrentUser.path)
            return
        }

        Log.info("action: open -a Terminal \(script.path) (runs: \(command))")
        run("/usr/bin/open", ["-a", "Terminal", script.path])
    }

    /// The script Terminal runs. It echoes the command before running it so the window says what
    /// is about to happen, and it does not `exit`, so a failure stays on screen to be read.
    static func writeSignInScript(command: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BranchBar", isDirectory: true)
        let url = directory.appendingPathComponent("gh-sign-in.command")
        let body = """
            #!/bin/zsh
            echo "\(Strings.ghSignInScriptBanner)"
            echo
            echo "$ \(command)"
            \(command)

            """
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        } catch {
            Log.info("action: could not write the sign-in script at \(url.path): \(error)")
            return nil
        }
    }

    // MARK: - Folder access

    /// The `grantFolderAccess` action: macOS's own Files and Folders list, where a folder BranchBar
    /// was refused can be turned back on.
    ///
    /// This is the pane, not the prompt — macOS gives no API for re-raising a TCC prompt the user
    /// already answered. "Add folder…" is the other half of the rescue and the one that actually
    /// grants a new folder, which is why the footer offers both.
    static func openFilesAndFoldersSettings() {
        guard let url = URL(string: Strings.filesAndFoldersSettingsURL) else { return }
        Log.info("action: open System Settings → Privacy & Security → Files and Folders")
        NSWorkspace.shared.open(url)
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
