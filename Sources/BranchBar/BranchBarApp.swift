import AppKit
import BranchBarCore
import SwiftUI

/// Menu-bar-only agent app. `LSUIElement` in Info.plist keeps it out of the Dock when
/// launched from a bundle; `setActivationPolicy(.accessory)` covers the un-bundled case
/// (`swift run`) and is harmless when the plist already said so.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.info("launched v\(BranchBarCore.version)")
    }
}

@main
struct BranchBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("BranchBar", systemImage: "arrow.triangle.branch") {
            VStack {
                Text("BranchBar spike")
                Button("Quit") { NSApp.terminate(nil) }
            }
            .padding()
            .onAppear { Log.info("menu opened") }
        }
        .menuBarExtraStyle(.window)
    }
}
