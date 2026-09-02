import AppKit
import BranchBarCore
import SwiftUI

// MARK: - Version and machine identity

/// Version as the tester sees it. `Bundle.main` is authoritative once the app is bundled; the
/// hardcoded core version covers `swift run`, where there is no Info.plist.
///
/// Reading a *version string* out of `Bundle.main` is fine. Reading a *path* out of it is not:
/// the 0.2 spike proved a quarantined bundle runs app-translocated out of
/// `/private/var/folders/…/AppTranslocation/…`, so nothing may be derived from `bundlePath`.
enum SpikeIdentity {
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        default: return "\(BranchBarCore.version) (unbundled)"
        }
    }

    static var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    /// `uname -m`, without shelling out.
    static var chip: String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &info.machine) { raw in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

// MARK: - Model

@MainActor
final class SpikeModel: ObservableObject {
    @Published var ghReport = "Not checked yet."
    @Published var folderReport = "No folder added yet."
    @Published var isChecking = false
    @Published var didCopy = false

    func checkGitHubCLI() async {
        guard !isChecking else { return }
        isChecking = true
        ghReport = "Checking…"
        Log.info("action: check github cli")

        let report = await SpikeChecks.ghAuthStatus()

        ghReport = report
        isChecking = false
        Log.info("gh report:\n\(report)")
    }

    func addFolder() {
        Log.info("action: add folder (opening panel)")

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add folder"
        panel.message = "Pick a folder and BranchBar will list the repos it can see inside it."

        // An accessory app is never frontmost, so the panel would open behind everything.
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else {
            folderReport = "Folder pick cancelled."
            Log.info("action: add folder cancelled")
            return
        }

        let repos = SpikeChecks.listGitDirs(under: url)
        let shown = repos.prefix(20)

        var report = "Folder: \(url.path)\nRepos found: \(repos.count)"
        if repos.isEmpty {
            report += "\n(none — either there are no repos in this folder, or macOS did not let BranchBar read it)"
        } else {
            report += "\n" + shown.map { "  \($0)" }.joined(separator: "\n")
            if repos.count > shown.count {
                report += "\n  …and \(repos.count - shown.count) more"
            }
        }

        folderReport = report
        Log.info("folder report:\n\(report)")
    }

    /// Everything a tester needs to paste back, in one clipboard write.
    func copyReport() {
        let text = """
            BranchBar spike report
            version: \(SpikeIdentity.version)
            macOS: \(SpikeIdentity.osVersion)
            chip: \(SpikeIdentity.chip)

            === Check GitHub CLI ===
            \(ghReport)

            === Add folder… ===
            \(folderReport)
            """

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        Log.info("action: copy report (\(text.count) characters)")
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            didCopy = false
        }
    }
}

// MARK: - Views

/// Fixed-height scroller so a long `gh auth status` cannot push Quit off the bottom of the popover.
private struct ReportBox: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(height: 110)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct SpikeView: View {
    @StateObject private var model = SpikeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BranchBar spike v\(SpikeIdentity.version)")
                .font(.headline)

            HStack(spacing: 8) {
                Button("Check GitHub CLI") {
                    Task { await model.checkGitHubCLI() }
                }
                .disabled(model.isChecking)

                Button("Add folder…") { model.addFolder() }
            }

            ReportBox(title: "Check GitHub CLI", text: model.ghReport)
            ReportBox(title: "Add folder…", text: model.folderReport)

            HStack {
                Button(model.didCopy ? "Copied" : "Copy report") { model.copyReport() }
                Spacer()
                Button("Quit") {
                    Log.info("action: quit")
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 380)
        .onAppear { Log.info("menu opened") }
    }
}

// MARK: - App

/// Menu-bar-only agent app. `LSUIElement` in Info.plist keeps it out of the Dock when
/// launched from a bundle; `setActivationPolicy(.accessory)` covers the un-bundled case
/// (`swift run`) and is harmless when the plist already said so.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.info(
            "launched v\(SpikeIdentity.version) · macOS \(SpikeIdentity.osVersion) · \(SpikeIdentity.chip)"
        )

        // Verification hook. A status item cannot be clicked from a script and `screencapture`
        // cannot see it (0.2 spike), so this is how the GUI-launched gh check gets proved:
        //
        //   launchctl setenv BRANCHBAR_SPIKE_AUTORUN 1
        //   open /Applications/BranchBar.app
        //   launchctl unsetenv BRANCHBAR_SPIKE_AUTORUN
        //
        // `launchctl setenv` is required — `open` does not forward the shell's environment, which
        // is the whole reason ToolLocator exists. Harmless when unset, and left in for Gate 0b so
        // a tester who cannot describe what they saw can still produce a log line.
        if ProcessInfo.processInfo.environment["BRANCHBAR_SPIKE_AUTORUN"] == "1" {
            Log.info("autorun: BRANCHBAR_SPIKE_AUTORUN=1")
            Task {
                let report = await SpikeChecks.ghAuthStatus()
                Log.info("autorun gh report:\n\(report)")
            }
        }
    }
}

@main
struct BranchBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("BranchBar", systemImage: "arrow.triangle.branch") {
            SpikeView()
        }
        .menuBarExtraStyle(.window)
    }
}
