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
    ///
    /// Returns whether anything was launched, so the `BRANCHBAR_ACTION_CHECK` probe can assert the
    /// refusal a non-directory earns rather than infer it from the absence of a window.
    @discardableResult
    static func openInAvailableEditor(path: String) -> Bool {
        if editors.cursor {
            return openInCursor(path: path)
        } else if editors.vsCode {
            return openInVSCode(path: path)
        } else {
            return openInTerminal(path: path)
        }
    }

    /// What `openInAvailableEditor` will actually do, in the words §5a froze for it. The chain is
    /// resolved in Core, by the same member `SnapshotPresenter` puts on a branch row's primary
    /// action, so a repo-header menu offering the same thing cannot name it differently.
    static var openInAvailableEditorLabel: String {
        Strings.openInAvailableEditorLabel(editors)
    }

    @discardableResult
    static func openInCursor(path: String) -> Bool { open(application: "Cursor", path: path) }
    @discardableResult
    static func openInVSCode(path: String) -> Bool { open(application: "Visual Studio Code", path: path) }
    @discardableResult
    static func openInTerminal(path: String) -> Bool { open(application: "Terminal", path: path) }

    /// `open -a <App> <path>`, exactly as §3 froze it. `/usr/bin/open` is used rather than
    /// `NSWorkspace.open(_:withApplicationAt:…)` so the invocation in the log is the one a tester
    /// can paste into a shell to reproduce what the row did.
    ///
    /// codex round 3, BLOCKER 1: the path is checked here, at click time, and only a real
    /// directory is ever handed over. A row's payload is a worktree path a repository or
    /// `cache.json` supplied, and the last step of the chain is Terminal, which *executes* a
    /// `.command` document — so a payload of `/tmp/payload.command` used to be a click away from
    /// running. The one `open -a Terminal` that is deliberately given a file is the sign-in
    /// script, which this app wrote itself moments earlier into a 0700 directory of its own; it
    /// calls `run` directly and never comes through here.
    @discardableResult
    private static func open(application: String, path: String) -> Bool {
        guard ActionPaths.allows(path, action: "open -a \"\(application)\"") else { return false }
        Log.info("action: open -a \"\(application)\" \(path)")
        run("/usr/bin/open", ["-a", application, path])
        return true
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

    /// codex round 3, BLOCKER 1: the same directory check as the editor chain. Finder selecting a
    /// document is not execution, but the path reaching it came from the same untrusted place, and
    /// a row that refuses to open a payload while still revealing it says the payload was fine.
    @discardableResult
    static func revealInFinder(path: String) -> Bool {
        guard ActionPaths.allows(path, action: "show in Finder") else { return false }
        Log.info("action: show in Finder \(path)")
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        return true
    }

    /// The clipboard is the one row action whose result a person pastes into a shell, so a path
    /// this app would refuse to open is a path it does not hand out either (codex round 3,
    /// BLOCKER 1). A refusal leaves the clipboard exactly as it was.
    @discardableResult
    static func copyPath(_ path: String) -> Bool {
        guard ActionPaths.allows(path, action: "copy path") else { return false }
        Log.info("action: copy path \(path)")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        return true
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

        // The one path handed to Terminal that is deliberately a file rather than a folder, and
        // the reason `open(application:path:)`'s directory check is on that member rather than on
        // `run`: this `.command` was written by `writeSignInScript` moments ago, inside a 0700
        // directory this app created under its own temporary folder, with fixed text
        // (`SignInScript.render`) and a hostname that was validated twice. Nothing a repository or
        // the cache owns can reach it.
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

    // MARK: - Where a sign-in click writes

    /// The folder the per-click sign-in directories live in.
    static var signInParentDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BranchBar", isDirectory: true)
    }

    /// Every directory this app is allowed to delete under `signInParentDirectory` starts with it.
    static let signInDirectoryPrefix = "sign-in-"

    /// How long a sign-in directory is kept before the next launch removes it. A `gh auth login`
    /// that a person has not finished within an hour is a Terminal window they abandoned.
    ///
    /// `nonisolated` because it is a default argument of `pruneSignInDirectories`, and a default
    /// argument is evaluated at the call site rather than inside the main-actor member.
    nonisolated static let signInDirectoryLifetime: TimeInterval = 3600

    /// Writes the fixed script plus the one-line hostname file it reads, and returns the script.
    ///
    /// The two files are siblings because `open` cannot pass an argument to the document it opens:
    /// a `.command` file is handed to Terminal as a document, so the hostname cannot ride as argv
    /// and has to be somewhere the script can find itself. `${0:A:h}` is that somewhere.
    ///
    /// codex MINOR 1: both files used to have fixed names in one shared directory, so the pair was
    /// mutable state two clicks raced over. Clicking sign-in for `github.com` and then for
    /// `ghe.example.com` before Terminal had launched rewrote `gh-sign-in.host` under the first
    /// script, and the first window authenticated the second host — the script reads the file at
    /// run time, not at write time. Each click now gets its own `sign-in-<uuid>` directory, created
    /// mode 0700 so nothing outside this account can read or replace either file, and the script it
    /// hands Terminal can only ever find the hostname written beside it.
    static func writeSignInScript(host: String) -> URL? {
        guard GitHubSlug.isValidHostname(host) else {
            Log.info("action: refusing to write a sign-in script for \(host)")
            return nil
        }
        guard let ghPath = ToolLocator().locate(.gh).path else {
            Log.info("action: no gh on this Mac, so there is no sign-in script to write")
            return nil
        }

        let directory = signInParentDirectory
            .appendingPathComponent(
                signInDirectoryPrefix + UUID().uuidString.lowercased(), isDirectory: true)
        let url = directory.appendingPathComponent(SignInScript.scriptFileName)
        let hostURL = directory.appendingPathComponent(SignInScript.hostFileName)
        do {
            try FileManager.default.createDirectory(
                at: signInParentDirectory, withIntermediateDirectories: true)
            // The mode is set at creation rather than after it: a directory that is 0755 for even
            // an instant is a directory another account could have opened in that instant.
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try (host + "\n").write(to: hostURL, atomically: true, encoding: .utf8)
            try SignInScript.render(ghPath: ghPath).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: hostURL.path)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: url.path)
            Log.info("action: wrote a sign-in script for \(host) in \(directory.path)")
            return url
        } catch {
            Log.info("action: could not write the sign-in script at \(url.path): \(error)")
            return nil
        }
    }

    /// Removes sign-in directories older than an hour, plus the two fixed-name files older builds
    /// left in the shared folder. Called once per launch (`AppDelegate`), never during a refresh:
    /// a directory is only ever removed while nothing this process wrote is pointing at it.
    ///
    /// Only names beginning with `sign-in-` are touched, so a folder someone else put in the app's
    /// temporary directory is left where it is.
    @discardableResult
    static func pruneSignInDirectories(
        olderThan lifetime: TimeInterval = signInDirectoryLifetime, now: Date = Date()
    ) -> Int {
        let manager = FileManager.default
        let parent = signInParentDirectory
        var removed = 0

        // The fixed pair the racing version wrote. They belong to no click any more.
        for legacy in [SignInScript.scriptFileName, SignInScript.hostFileName] {
            let url = parent.appendingPathComponent(legacy)
            guard manager.fileExists(atPath: url.path) else { continue }
            if (try? manager.removeItem(at: url)) != nil { removed += 1 }
        }

        guard let entries = try? manager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return removed }

        for entry in entries where entry.lastPathComponent.hasPrefix(signInDirectoryPrefix) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) > lifetime else { continue }
            do {
                try manager.removeItem(at: entry)
                removed += 1
            } catch {
                Log.info("action: could not remove \(entry.path): \(error)")
            }
        }
        if removed > 0 {
            Log.info("action: removed \(removed) stale sign-in file(s) under \(parent.path)")
        }
        return removed
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
