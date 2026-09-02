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

    /// Opens a pull request in the browser. `host` is the repo's own validated GitHub host, carried
    /// on `RepoSectionVM.host`, and the URL has to match it.
    ///
    /// codex MINOR 3 / REVIEW WR-04: the address comes from `gh pr list --json url` today, but it
    /// is also serialized into `cache.json`, so a tampered cache could hand this an `http://` link
    /// to a local service, a link carrying credentials in its user-info, or a link to a host that
    /// has nothing to do with the repo the row belongs to. Three checks answer those three shapes,
    /// and `nil` host — a row whose repo has no validated slug — is refused rather than waved
    /// through, because a PR row only exists when a slug does.
    static func openPR(url: String, host: String?) {
        guard let parsed = URL(string: url), parsed.scheme?.lowercased() == "https" else {
            Log.info("action: open PR refused, not an https address: \(url)")
            return
        }
        guard parsed.user == nil, parsed.password == nil else {
            Log.info("action: open PR refused, the address carries credentials")
            return
        }
        guard let linkHost = parsed.host?.lowercased(), GitHubSlug.isValidHostname(linkHost) else {
            Log.info("action: open PR refused, the address has no hostname: \(url)")
            return
        }
        guard let host, host.lowercased() == linkHost else {
            Log.info(
                "action: open PR refused, \(linkHost) is not this repo's host (\(host ?? "none"))")
            return
        }
        Log.info("action: open PR \(url)")
        NSWorkspace.shared.open(parsed)
    }

    /// The one web address BranchBar opens that belongs to no repo: `Strings.installGitHubCLIURL`,
    /// carried by the `gh-not-installed` notice's action. It is a constant this app built, not
    /// anything the cache or a remote can reach, so it is pinned to https rather than to a host.
    static func openWebPage(url: String) {
        guard let parsed = URL(string: url),
              parsed.scheme?.lowercased() == "https",
              parsed.user == nil,
              parsed.password == nil,
              parsed.host != nil
        else {
            Log.info("action: open page refused, not a plain https address: \(url)")
            return
        }
        Log.info("action: open page \(url)")
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
    /// handler for `.command` still has the line to paste. It is rebuilt from the validated
    /// hostname rather than copied from the payload, so nothing but a hostname can reach it.
    ///
    /// codex BLOCKER 1: the payload is `Strings.ghAuthLoginCommand(host:)`, and until the fix the
    /// whole string was written into zsh source. Nothing here writes a caller's string into a
    /// script any more — `SignInScript.render` is fixed text, and the only value that travels is
    /// the hostname, which is validated here, written to a data file, and validated again in zsh.
    static func openTerminalForSignIn(command: String?) {
        guard let host = signInHostname(from: command) else {
            Log.info("action: sign-in refused, no valid hostname in the action payload")
            openInTerminal(path: FileManager.default.homeDirectoryForCurrentUser.path)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Strings.ghAuthLoginCommand(host: host), forType: .string)

        guard let script = writeSignInScript(host: host) else {
            Log.info("action: sign-in script could not be written; opening Terminal at home instead")
            openInTerminal(path: FileManager.default.homeDirectoryForCurrentUser.path)
            return
        }

        Log.info("action: open -a Terminal \(script.path) (signs in to \(host))")
        run("/usr/bin/open", ["-a", "Terminal", script.path])
    }

    /// The hostname out of `gh auth login --hostname <host>`, and only when it really is one.
    ///
    /// The payload rides on `UserFacingFailure.Action`, which is serialized, so it is treated as
    /// untrusted text even though `SnapshotPresenter` builds it from a slug this run parsed.
    static func signInHostname(from command: String?) -> String? {
        guard let command else { return nil }
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let flag = words.firstIndex(of: "--hostname"), words.indices.contains(flag + 1) else {
            return nil
        }
        let host = words[flag + 1].lowercased()
        return GitHubSlug.isValidHostname(host) ? host : nil
    }

    /// Writes the fixed script plus the one-line hostname file it reads, and returns the script.
    ///
    /// The two files are siblings because `open` cannot pass an argument to the document it opens:
    /// a `.command` file is handed to Terminal as a document, so the hostname cannot ride as argv
    /// and has to be somewhere the script can find itself. `${0:A:h}` is that somewhere.
    static func writeSignInScript(host: String) -> URL? {
        guard GitHubSlug.isValidHostname(host) else {
            Log.info("action: refusing to write a sign-in script for \(host)")
            return nil
        }
        guard let ghPath = ToolLocator().locate(.gh).path else {
            Log.info("action: no gh on this Mac, so there is no sign-in script to write")
            return nil
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BranchBar", isDirectory: true)
        let url = directory.appendingPathComponent(SignInScript.scriptFileName)
        let hostURL = directory.appendingPathComponent(SignInScript.hostFileName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (host + "\n").write(to: hostURL, atomically: true, encoding: .utf8)
            try SignInScript.render(ghPath: ghPath).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: hostURL.path)
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
