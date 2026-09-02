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

        model.refresh(reason: .launch)
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
