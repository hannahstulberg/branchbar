#!/usr/bin/env swift
//
// Find (and, if asked, capture) a BranchBar window by id.
//
//   swift scripts/windowid.swift list [owner]            # every on-screen window, one per line
//   swift scripts/windowid.swift find <title-substring>  # the first matching window id, or exit 1
//
// PLAN.md §5b names this script; scripts/screenshot-states.sh is its only caller, which feeds the
// id it prints to `screencapture -l`.
//
// **There is no `capture` mode.** PLAN.md §5b planned `CGWindowListCreateImage` as the fallback for
// a blank `screencapture`, and that call is *obsoleted in the macOS 15 SDK* — not deprecated,
// unavailable, so a script that names it does not compile against the Command Line Tools this
// project builds with. Its replacement, ScreenCaptureKit, wants the same Screen Recording grant
// `screencapture` already has, so it would buy nothing. The fallback that does buy something needs
// no grant at all and lives in the app: `BRANCHBAR_STATE_SHOT=<path>` makes BranchBar draw its own
// window into a PNG through `cacheDisplay`, which is the window's real pixels either way.

import CoreGraphics
import Foundation

func windows() -> [[String: Any]] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    return (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
}

func describe(_ window: [String: Any]) -> String {
    let id = window[kCGWindowNumber as String] as? Int ?? -1
    let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
    let name = window[kCGWindowName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = bounds["Width"] as? Double ?? 0
    let height = bounds["Height"] as? Double ?? 0
    return "\(id)\tlayer=\(layer)\t\(Int(width))x\(Int(height))\t\(owner)\t\(name)"
}

/// Owner name, window title, or either — a `MenuBarExtra` popover carries no title of its own, so
/// matching has to fall back to the owner.
func matches(_ window: [String: Any], _ needle: String) -> Bool {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let name = window[kCGWindowName as String] as? String ?? ""
    return owner.localizedCaseInsensitiveContains(needle)
        || name.localizedCaseInsensitiveContains(needle)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    FileHandle.standardError.write(Data("usage: windowid.swift list|find …\n".utf8))
    exit(2)
}

switch command {
case "list":
    let needle = arguments.count > 1 ? arguments[1] : nil
    for window in windows() where needle == nil || matches(window, needle!) {
        print(describe(window))
    }

case "find":
    guard arguments.count > 1 else {
        FileHandle.standardError.write(Data("find needs a title or owner substring\n".utf8))
        exit(2)
    }
    let needle = arguments[1]
    // Biggest first: the popover is the window with area, not the 1x1 helper windows AppKit keeps.
    let candidates = windows()
        .filter { matches($0, needle) }
        .filter {
            let bounds = $0[kCGWindowBounds as String] as? [String: Any] ?? [:]
            return (bounds["Width"] as? Double ?? 0) > 100 && (bounds["Height"] as? Double ?? 0) > 100
        }
        .sorted {
            let left = $0[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let right = $1[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let leftArea = (left["Width"] as? Double ?? 0) * (left["Height"] as? Double ?? 0)
            let rightArea = (right["Width"] as? Double ?? 0) * (right["Height"] as? Double ?? 0)
            return leftArea > rightArea
        }
    guard let best = candidates.first,
          let id = best[kCGWindowNumber as String] as? Int
    else { exit(1) }
    print(id)

default:
    FileHandle.standardError.write(Data("unknown command '\(command)'\n".utf8))
    exit(2)
}
