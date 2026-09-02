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
            Text(state.title)
                .font(.headline)
                .foregroundStyle(Color(nsColor: .labelColor))
            Text(state.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    perform(state.action)
                } label: {
                    Label(state.action.label, systemImage: Glyph.addFolder)
                }
                Button {
                    perform(UserFacingFailure.Action(label: Strings.rescanActionLabel, kind: .rescan))
                } label: {
                    Label(Strings.rescanActionLabel, systemImage: Glyph.rescan)
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
