import AppKit
import BranchBarCore
import SwiftUI

// MARK: - App delegate

/// Menu-bar-only agent app. `LSUIElement` in Info.plist keeps it out of the Dock when launched
/// from a bundle; `setActivationPolicy(.accessory)` covers the un-bundled case (`swift run`) and is
/// harmless when the plist already said so.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Fixture mode's window. Held so it is not deallocated the moment it is ordered front.
    private var fixtureWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.info(
            "launched v\(AppModel.version) · macOS "
                + "\(ProcessInfo.processInfo.operatingSystemVersionString) · \(Self.chip)")

        let model = AppModel.shared

        // Gate 4 wants one screenshot per state in light *and* dark, and a script cannot flip the
        // system setting for it. In fixture mode only, `BRANCHBAR_APPEARANCE=light|dark` pins this
        // app's own appearance; unset, it follows the Mac like every other app.
        if model.previewStateID != nil,
           let name = ProcessInfo.processInfo.environment["BRANCHBAR_APPEARANCE"] {
            switch name {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: Log.info("appearance: ignoring BRANCHBAR_APPEARANCE=\(name)")
            }
        }

        if let state = model.previewStateID {
            // `BRANCHBAR_STATE_FIXTURE` renders one recorded §5a state with no git, no `gh`, and no
            // cache. The window exists so the state can be laid out and screenshotted without
            // clicking a status item — the 0.2 spike proved `screencapture` cannot see one.
            showFixtureWindow(for: model, state: state)
            return
        }

        // codex MINOR 1: a sign-in click writes a `sign-in-<uuid>` directory under the app's
        // temporary folder and nothing deletes it when Terminal is done, so launch is where the old
        // ones go. Before the first refresh, because it touches only files this app wrote.
        Actions.pruneSignInDirectories()

        // Read once, here, rather than per popover open: `SMAppService.status` is an XPC round trip
        // and the footer redraws on every progressive emit. Every later read follows a flip.
        LaunchAtLogin.logCurrentState()
        model.refreshLaunchAtLoginState()

        let environment = ProcessInfo.processInfo.environment
        if let mode = environment["BRANCHBAR_LAUNCH_AT_LOGIN"], !mode.isEmpty {
            runLaunchAtLoginCheck(mode)
            return
        }
        if let path = environment["BRANCHBAR_ACTION_CHECK"], !path.isEmpty {
            // F10: the footer's Cancel is the first caller `AppModel.cancelRefresh()` has ever
            // had, and a popover button cannot be clicked from a script without an Accessibility
            // grant (0.2 spike item 4). This value runs the click instead of a folder's actions.
            if path == Self.cancelRefreshCheck {
                runCancelRefreshCheck(model)
            } else {
                runActionCheck(on: path)
            }
            return
        }

        model.refresh(reason: .launch)
    }

    // MARK: - Gate 4 harnesses

    /// Runs the row and setup actions against one folder and logs what each one did, then quits.
    ///
    /// It exists because the popover cannot be driven from a script without an Accessibility grant
    /// (0.2 spike item 4), and Gate 4 asks for every action exercised on a real worktree. These are
    /// the same `Actions` entry points the menu items call — the harness replaces the click, not the
    /// code under it. Two actions are deliberately absent: "Add folder…" runs a modal `NSOpenPanel`
    /// that only a person can answer, and the login-item toggle has its own mode below.
    private func runActionCheck(on path: String) {
        Log.info("action check: starting on \(path)")

        Actions.openInAvailableEditor(path: path)
        Actions.revealInFinder(path: path)

        Actions.copyPath(path)
        let pasted = NSPasteboard.general.string(forType: .string) ?? "—"
        Log.info("action check: clipboard now holds \(pasted) · matches=\(pasted == path)")

        let command = Strings.ghAuthLoginCommand(host: "github.com")
        if let script = Actions.writeSignInScript(host: "github.com") {
            let body = (try? String(contentsOf: script, encoding: .utf8)) ?? ""
            Log.info(
                "action check: sign-in script at \(script.path) executable="
                    + "\(FileManager.default.isExecutableFile(atPath: script.path)) "
                    + "carries-no-host=\(!body.contains("github.com")) "
                    + "carries-guard=\(body.contains(SignInScript.hostnamePattern))")
        }
        // codex BLOCKER 1: the two shapes that used to become shell source. Both must log a refusal
        // and neither may write a script.
        Log.info(
            "action check: hostile sign-in payloads refused="
                + "\(Actions.signInHostname(from: "gh auth login --hostname github.com;id") == nil) "
                + "\(Actions.signInHostname(from: "gh auth login --hostname $(touch /tmp/pwned)") == nil)")
        checkSignInDirectoriesAreUnique()
        Actions.openTerminalForSignIn(command: command)

        checkNonDirectoryPathsAreRefused()

        Actions.openPR(url: "https://github.com/hannahstulberg/branchbar", host: "github.com")
        Actions.openPR(url: "http://github.com/hannahstulberg/branchbar", host: "github.com")
        Actions.openPR(url: "file:///etc/passwd", host: "github.com")
        Actions.openPR(url: "https://evil.example.com/o/n/pull/1", host: "github.com")
        Actions.openPR(url: "https://user:pw@github.com/o/n/pull/1", host: "github.com")
        Actions.openPR(url: "https://github.com/o/n/pull/1", host: nil)
        Actions.openFilesAndFoldersSettings()

        Log.info("action check: done")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
    }

    /// codex round 3, BLOCKER 1: the shape that used to be a click away from executing.
    ///
    /// A row's path comes from `git worktree list --porcelain` or from `cache.json`, and neither
    /// is trusted: a crafted worktree record, or a tampered cache, can name `/tmp/payload.command`
    /// as a branch's folder. On a Mac with neither Cursor nor VS Code the editor chain ends at
    /// `open -a Terminal <path>`, and Terminal *runs* a `.command` document. Three targets are
    /// built here — a regular `.command` file, a FIFO, and a symlink pointing at a real directory
    /// — and every row action must refuse all three while still accepting the real folder the
    /// probe was given. The clipboard is read back afterwards because a refusal that still
    /// overwrote it would have handed the path out anyway.
    private func checkNonDirectoryPathsAreRefused() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BranchBar-action-check-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)) != nil
        else {
            Log.info("action check: could not build the non-directory targets")
            return
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let command = directory.appendingPathComponent("payload.command", isDirectory: false)
        try? "#!/bin/zsh\necho payload\n".write(to: command, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: command.path)

        let fifo = directory.appendingPathComponent("payload.fifo", isDirectory: false)
        let madeFIFO = mkfifo(fifo.path, 0o600) == 0

        let link = directory.appendingPathComponent("payload.link", isDirectory: false)
        let madeLink = (try? FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: directory)) != nil

        let sentinel = "action-check-clipboard-sentinel"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sentinel, forType: .string)

        var targets: [(String, String)] = [("command-file", command.path)]
        if madeFIFO { targets.append(("fifo", fifo.path)) }
        if madeLink { targets.append(("symlink-to-directory", link.path)) }
        targets.append(
            ("missing", directory.appendingPathComponent("absent", isDirectory: true).path))

        var verdicts: [String] = []
        for target in targets {
            let editor = Actions.openInAvailableEditor(path: target.1)
            let finder = Actions.revealInFinder(path: target.1)
            let copied = Actions.copyPath(target.1)
            verdicts.append(
                "\(target.0): refusedEditor=\(!editor) refusedFinder=\(!finder) "
                    + "refusedCopy=\(!copied)")
        }
        // The editor chain ends at Terminal only on a Mac with neither Cursor nor VS Code, and this
        // one may have both, so the step that would have executed the file is asked directly.
        let terminal = Actions.openInTerminal(path: command.path)
        let clipboard = NSPasteboard.general.string(forType: .string) ?? "—"
        Log.info("action check: open -a Terminal on a .command file refused=\(!terminal)")
        Log.info("action check: non-directory targets " + verdicts.joined(separator: " · "))
        Log.info(
            "action check: clipboard survived the refusals=\(clipboard == sentinel) · "
                + "a real folder still passes=\(ActionPaths.isDirectory(directory.path))")
    }

    /// The `BRANCHBAR_ACTION_CHECK` value that runs the cancel probe rather than a folder's
    /// actions. A literal no path can be: an action check is given an absolute path.
    static let cancelRefreshCheck = "cancel-refresh"

    /// Starts a real refresh, presses the footer's Cancel as soon as one is actually in flight,
    /// and waits for the model to publish the cancellation before quitting.
    ///
    /// The evidence is the `refresh: cancelled …` line `AppModel.performRefresh` writes: it names
    /// the reason, how many rows were marked stale, Core's own outcome, the "Updated" label that
    /// was kept, and that the PR warm-up and any queued rescan were suppressed. A probe that
    /// quit on a timer could print none of that.
    private func runCancelRefreshCheck(_ model: AppModel) {
        Log.info("action check: cancel-refresh starting a refresh")
        model.refresh(reason: .manual)
        pressCancelOnceRunning(model, attemptsLeft: 120)
    }

    /// Polls rather than sleeping a fixed interval: the preflight runs `git --version` before the
    /// coordinator sees anything, and cancelling in that window cancels nothing.
    private func pressCancelOnceRunning(_ model: AppModel, attemptsLeft: Int) {
        guard attemptsLeft > 0 else {
            Log.info("action check: cancel-refresh saw no repo finish before the wait ran out; quitting")
            NSApp.terminate(nil)
            return
        }
        // Progress as well as a running refresh: cancelling in the first 250 ms proves the button
        // is wired but nothing about what a cancel costs. Waiting for `.running(completed > 0)`
        // means the run being stopped has already reloaded repos, so the log line reports both the
        // rows it kept and the ones it marked stale. A cached list on screen is not evidence —
        // those rows belong to the previous run.
        guard model.isRefreshRunning, Self.completedRepos(model.refreshState) > 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.pressCancelOnceRunning(model, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        Log.info("action check: cancel-refresh pressing Cancel")
        model.cancelRefresh()
        waitForCancelledRefresh(model, attemptsLeft: 240)
    }

    /// How many repos the running refresh has reloaded, or 0 when it is not running.
    private static func completedRepos(_ state: RefreshState) -> Int {
        if case .running(let completed, _) = state { return completed }
        return 0
    }

    private func waitForCancelledRefresh(_ model: AppModel, attemptsLeft: Int) {
        guard attemptsLeft > 0 else {
            Log.info("action check: cancel-refresh never returned; quitting")
            NSApp.terminate(nil)
            return
        }
        guard !model.isRefreshRunning else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.waitForCancelledRefresh(model, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        // One more turn so the `refresh: cancelled …` line is on disk before the process goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            Log.info("action check: cancel-refresh done")
            NSApp.terminate(nil)
        }
    }

    /// codex MINOR 1: two sign-in clicks in a row used to share one directory and one
    /// `gh-sign-in.host`, so the second click's hostname was what the first Terminal window
    /// authenticated. Two clicks are made here and the three facts that fix it are logged: the
    /// directories differ, each script's own sibling holds its own host, and the directory is 0700.
    private func checkSignInDirectoriesAreUnique() {
        guard let first = Actions.writeSignInScript(host: "github.com"),
              let second = Actions.writeSignInScript(host: "ghe.example.com")
        else {
            Log.info("action check: no gh on this Mac, so the sign-in directories were not written")
            return
        }
        func host(beside script: URL) -> String {
            let sibling = script.deletingLastPathComponent()
                .appendingPathComponent(SignInScript.hostFileName)
            return ((try? String(contentsOf: sibling, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let directory = first.deletingLastPathComponent()
        let mode = (try? FileManager.default.attributesOfItem(atPath: directory.path))
            .flatMap { $0[.posixPermissions] as? NSNumber }
            .map { String($0.intValue, radix: 8) } ?? "—"
        Log.info(
            "action check: sign-in directories unique="
                + "\(first.deletingLastPathComponent() != second.deletingLastPathComponent()) "
                + "firstHost=\(host(beside: first)) secondHost=\(host(beside: second)) "
                + "mode=\(mode)")
    }

    /// `status`, `on`, or `off` for the login item, so the toggle's two mechanisms can be exercised
    /// and read back from `/Applications` without clicking a checkbox in a popover.
    private func runLaunchAtLoginCheck(_ mode: String) {
        switch mode {
        case "on", "off":
            do {
                try LaunchAtLogin.set(mode == "on")
            } catch {
                let failure = error as? LaunchAtLogin.Failure
                Log.info("launch at login check: set(\(mode)) threw \(failure?.diagnostic ?? "\(error)")")
            }
        case "status":
            break
        default:
            Log.info("launch at login check: unknown mode \(mode)")
        }
        LaunchAtLogin.logCurrentState()
        let live = LaunchAtLogin.state()
        Log.info(
            "launch at login check: plist=\(live.fileExists) type=\(live.fileType) "
                + "path=\(LaunchAtLogin.launchAgentURL.path) bundle=\(Bundle.main.bundlePath)")
        // codex round 3, MAJOR 5: the fact the toggle now depends on. `launchctl print` exiting 0
        // says the label is taken; this says by what, and whether that is the executable this
        // build would have registered.
        Log.info(
            "launch at login check: verified live program=\(live.loadedProgram ?? "none") "
                + "wanted=\(LaunchAtLogin.installedExecutablePath) "
                + "matches=\(live.loadedProgram == LaunchAtLogin.installedExecutablePath) "
                + "isOurs=\(live.loadedProgramIsOurs) toggleReadsOn=\(LaunchAtLogin.isEnabled)")
        checkLaunchctlPrintParsing()
        checkLaunchAgentPlistSchema()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
    }

    /// codex round 3, MAJOR 5 and MINOR 1: the two grammars this file now depends on, exercised
    /// against fixed text so they are evidence on a Mac where nothing is loaded.
    ///
    /// `launchctl print` prints `program = <path>` for a job that has a `Program`, and
    /// `program identifier = <relative path>` for one another process submitted — which is not a
    /// program path and must not be read as one. The plist half checks that
    /// `PropertyListSerialization` round-trips a `Program` containing the XML metacharacters a
    /// managed home directory can carry, which string interpolation used to emit unescaped.
    private func checkLaunchctlPrintParsing() {
        let samples: [(String, String, String?)] = [
            ("program", "\tpath = /Users/x/Library/LaunchAgents/a.plist\n\tprogram = /Applications/BranchBar.app/Contents/MacOS/BranchBar\n\targuments = {\n",
             "/Applications/BranchBar.app/Contents/MacOS/BranchBar"),
            ("program-identifier-only", "\tpath = (submitted by smd.310)\n\tprogram identifier = Contents/Library/LaunchAgents/other\n", nil),
            ("no-program", "\tpath = (submitted by runningboardd.384)\n\tactive count = 1\n", nil),
            ("empty-output", "", nil),
        ]
        let verdicts = samples.map { name, output, expected in
            "\(name)=\(LaunchAtLogin.programPath(inLaunchctlPrint: output) == expected)"
        }
        Log.info("launch at login check: launchctl print parse " + verdicts.joined(separator: " "))

        let hostile = "/Users/a&b/<Applications>/BranchBar.app/Contents/MacOS/BranchBar"
        let plist: [String: Any] = [
            "Label": LaunchAtLogin.bundleID, "Program": hostile, "RunAtLoad": true,
        ]
        let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        let parsed = data.flatMap {
            try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil)
        } as? [String: Any]
        Log.info(
            "launch at login check: plist serialization round-trips a Program carrying & and <"
                + " = \(parsed?["Program"] as? String == hostile)")
    }

    /// codex MAJOR 8: `Label` and `Program` were the whole check, so a plist carrying those two
    /// plus `KeepAlive` — which relaunches the app the user just quit — or `ProgramArguments` or
    /// `EnvironmentVariables` read as BranchBar's own login item. The schema rule is exercised here
    /// against the dictionary rather than against a file, so nothing has to be written to prove it.
    private func checkLaunchAgentPlistSchema() {
        let program = LaunchAtLogin.executablePath(inBundleAt: LaunchAtLogin.systemBundlePath)
        let userProgram = LaunchAtLogin.executablePath(inBundleAt: LaunchAtLogin.userBundlePath)
        let good: [String: Any] = [
            "Label": LaunchAtLogin.bundleID, "Program": program, "RunAtLoad": true,
        ]
        let cases: [(String, [String: Any])] = [
            ("ours-in-applications", good),
            ("ours-in-home-applications", [
                "Label": LaunchAtLogin.bundleID, "Program": userProgram, "RunAtLoad": true,
            ]),
            ("keep-alive", good.merging(["KeepAlive": true]) { _, new in new }),
            ("program-arguments", good.merging(["ProgramArguments": ["/bin/sh"]]) { _, new in new }),
            ("environment", good.merging(
                ["EnvironmentVariables": ["DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"]]) { _, new in new }),
            ("run-at-load-false", good.merging(["RunAtLoad": false]) { _, new in new }),
            ("no-run-at-load", ["Label": LaunchAtLogin.bundleID, "Program": program]),
            ("someone-elses-program", [
                "Label": LaunchAtLogin.bundleID, "Program": "/tmp/BranchBar", "RunAtLoad": true,
            ]),
        ]
        let verdicts = cases
            .map { "\($0.0)=\(LaunchAtLogin.isOwnLaunchAgentPlist($0.1))" }
            .joined(separator: " ")
        Log.info("launch at login check: plist schema \(verdicts)")
        Log.info(
            "launch at login check: install candidates "
                + LaunchAtLogin.installCandidateBundlePaths.joined(separator: " , ")
                + " · running=\(LaunchAtLogin.runningInstallBundlePath ?? "neither")"
                + " · agentWouldName=\(LaunchAtLogin.installedExecutablePath)")
    }

    /// Lays the popover's own view out in an ordinary window and logs `rendered state <id>` once
    /// SwiftUI has actually built the body — so the log line is evidence the state rendered, not
    /// evidence the JSON parsed.
    private func showFixtureWindow(for model: AppModel, state: String) {
        let hosting = NSHostingView(rootView: RootView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: Metrics.popoverWidth, height: 600)
        hosting.layoutSubtreeIfNeeded()

        let size = hosting.fittingSize
        let height = max(120, min(size.height, Metrics.maxPopoverHeight))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.popoverWidth, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "BranchBar — \(state)"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.center()
        window.orderFrontRegardless()
        fixtureWindow = window

        // One turn of the run loop so the hosting view has drawn before anything screenshots it.
        DispatchQueue.main.async {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let shot = ProcessInfo.processInfo.environment["BRANCHBAR_STATE_SHOT"]
            if let shot, !shot.isEmpty { Self.writePNG(of: hosting, to: shot) }
            Log.info("rendered state \(state) · window \(window.windowNumber) · height \(Int(height))")
        }
    }

    /// The grant-free half of the screenshot pipeline. `screencapture -l` and ScreenCaptureKit both
    /// need Screen Recording; `cacheDisplay` asks the view to draw itself into a bitmap the app
    /// already owns, so a headless run on a Mac that has granted nothing still produces the real
    /// pixels. scripts/screenshot-states.sh prefers `screencapture` and falls back to this.
    private static func writePNG(of view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Log.info("shot: could not make a bitmap for \(path)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            Log.info("shot: could not encode a PNG for \(path)")
            return
        }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
            Log.info("shot: wrote \(path) (\(data.count) bytes, \(rep.pixelsWide)x\(rep.pixelsHigh))")
        } catch {
            Log.info("shot: could not write \(path): \(error)")
        }
    }

    /// `uname -m`, without shelling out.
    static var chip: String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

// MARK: - App

@main
struct BranchBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            RootView(model: model)
                // `.window` re-runs `onAppear` on every open (0.2 spike item 7), which is exactly
                // where the on-open refresh belongs. The coordinator's 30 s debounce is what keeps
                // a user who opens and closes the popover four times from walking their repos four
                // times, so this asks unconditionally and lets Core decide.
                .onAppear {
                    Log.info("popover opened")
                    model.refresh(reason: .popoverOpen)
                }
        } label: {
            // Template symbol: monochrome, and it never conveys state — the menu bar item looks the
            // same whether a PR is approved or the refresh failed.
            Image(systemName: Glyph.menuBar)
                .accessibilityLabel(Strings.menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)
    }
}
