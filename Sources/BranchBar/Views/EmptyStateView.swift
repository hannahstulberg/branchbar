import BranchBarCore
import SwiftUI

/// Zero repos, in both of the ways §5a names them: a scan still running is "Looking for repos", a
/// finished one is "No repos found". Which of the two is showing is the presenter's decision, made
/// from `RefreshState`; this view renders whichever it was handed.
struct EmptyStateView: View {
    let state: EmptyStateVM
    let perform: (UserFacingFailure.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(RepositoryText.display(state.title))
                .font(.headline)
                .foregroundStyle(Color(nsColor: .labelColor))
            // Names the scan roots, which are folders on this Mac (codex round 4, MINOR 2).
            Text(RepositoryText.display(state.message))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    perform(state.action)
                } label: {
                    if let glyph = primaryGlyph {
                        Label(state.action.label, systemImage: glyph)
                    } else {
                        Text(state.action.label)
                    }
                }
                if showsRescan {
                    Button {
                        perform(UserFacingFailure.Action(label: Strings.rescanActionLabel, kind: .rescan))
                    } label: {
                        Label(Strings.rescanActionLabel, systemImage: Glyph.rescan)
                    }
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The glyph follows the action the presenter actually chose. The empty state is not only
    /// "Add folder…": a refresh that failed before it produced a snapshot hands its own action
    /// through (`git not found` offers Refresh), and a folder-plus beside "Refresh" names the
    /// wrong thing. A kind with no glyph of its own gets a plain text label rather than a
    /// borrowed one.
    private var primaryGlyph: String? {
        switch state.action.kind {
        case .addFolder: return Glyph.addFolder
        case .retryRefresh: return Glyph.refresh
        case .rescan: return Glyph.rescan
        case .openTerminalWithGhAuthLogin, .openURL, .grantFolderAccess: return nil
        }
    }

    /// Rescan is the second half of "no repos found" — it only makes sense when the primary action
    /// is the other half of that pair. On a `git not found` empty state there is nothing to rescan
    /// with, so offering it would be a button that cannot work.
    private var showsRescan: Bool { state.action.kind == .addFolder }
}
