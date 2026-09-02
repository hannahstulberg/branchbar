import AppKit
import BranchBarCore
import SwiftUI

// docs/UI-CONTRACT.md section 4, transcribed once so no view carries a magic number and a token
// change is one edit. Colours name the `NSColor`, never the hex the contract prints for review:
// a future macOS keeps its own palette and the app follows it into light and dark.

enum Metrics {
    /// Fixed by §5a item 4. The popover never grows with content.
    static let popoverWidth: CGFloat = 340
    static let horizontalPadding: CGFloat = 12
    static let rowSpacing: CGFloat = 6
    static let groupSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 12
    /// Keeps branch names aligned whether or not a row has a marker glyph.
    static let glyphColumn: CGFloat = 16
    static let branchRowHeight: CGFloat = 44
    static let branchRowSingleLineHeight: CGFloat = 36
    static let prRowHeight: CGFloat = 32
    static let groupHeadingHeight: CGFloat = 24
    static let sectionHeaderHeight: CGFloat = 28
    static let footerHeight: CGFloat = 32
    static let pillHeight: CGFloat = 16
    static let pillHorizontalPadding: CGFloat = 6
    static let pillCornerRadius: CGFloat = 8

    /// 70 % of the active screen, computed per open because the tester may move the app between a
    /// laptop panel and an external display. `NSScreen.main` is nil in a headless render, so the
    /// fallback is a plausible laptop height rather than zero.
    @MainActor static var maxPopoverHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(280, (visible * 0.7).rounded(.down))
    }
}

/// The ten `PRStatus` treatments. Shape is what separates "BranchBar knows the PR state" from
/// "BranchBar does not", so the three unknown states stay legible without a colour of their own.
enum PillTreatment {
    case textOnly
    case filled
    case outline
    /// `unavailable`: outline plus the warning glyph.
    case outlineWarning
    /// `notChecked`: a `[2, 2]` dashed outline.
    case dashedOutline
}

extension PRStatus {
    var tokenColor: Color {
        switch self {
        case .none, .unavailable, .notLoaded, .notChecked: return Color(nsColor: .secondaryLabelColor)
        case .draft: return Color(nsColor: .systemGray)
        case .open: return Color(nsColor: .systemBlue)
        case .changesRequested: return Color(nsColor: .systemOrange)
        case .approved: return Color(nsColor: .systemGreen)
        case .merged: return Color(nsColor: .systemPurple)
        case .closed: return Color(nsColor: .systemRed)
        }
    }

    var pillTreatment: PillTreatment {
        switch self {
        case .none: return .textOnly
        case .draft, .open, .changesRequested, .approved, .merged, .closed: return .filled
        case .unavailable: return .outlineWarning
        case .notLoaded: return .outline
        case .notChecked: return .dashedOutline
        }
    }
}

/// Every glyph the contract names. All ship with macOS 13, and every one is decorative: it repeats
/// what the adjacent text already says, so VoiceOver skips it and greyscale loses nothing.
enum Glyph {
    static let menuBar = "arrow.triangle.branch"
    static let branch = "arrow.triangle.branch"
    static let worktree = "folder"
    static let worktreeNoBranch = "folder.badge.questionmark"
    static let collapsed = "chevron.right"
    static let expanded = "chevron.down"
    static let openPR = "arrow.up.right.square"
    static let openInEditor = "arrow.up.forward.app"
    static let revealInFinder = "folder"
    static let copyPath = "doc.on.doc"
    static let refresh = "arrow.clockwise"
    static let addFolder = "folder.badge.plus"
    static let grantAccess = "lock.open"
    static let rescan = "magnifyingglass"
    static let removeRoot = "minus.circle"
    static let warning = "exclamationmark.triangle"
    static let notScanned = "eye.slash"
    static let rateLimited = "clock"
    static let pushObserved = "arrow.up.circle"
    static let pushUnknown = "questionmark.circle"
    static let ahead = "arrow.up"
}

/// A glyph that is never spoken and never focused.
struct DecorativeIcon: View {
    let name: String
    var font: Font = .caption

    var body: some View {
        Image(systemName: name)
            .font(font)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}
