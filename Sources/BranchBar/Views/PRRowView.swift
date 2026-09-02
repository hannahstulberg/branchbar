import BranchBarCore
import SwiftUI

/// A PR with no matching branch on this Mac. Two tiers only — title and pill — and no branch
/// actions, because there is no branch here to open (PLAN.md §3: state and link only).
struct PRRowView: View {
    let row: PRRowVM
    let isFocused: Bool
    let openPR: (String) -> Void

    var body: some View {
        Button(action: { openPR(row.url) }) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                DecorativeIcon(name: Glyph.openPR)
                    .frame(width: Metrics.glyphColumn, alignment: .leading)
                Text(row.title)
                    .font(.body)
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
                PRPillView(pill: row.prPill)
                Spacer(minLength: 0)
            }
            .frame(minHeight: Metrics.prRowHeight, alignment: .center)
            .padding(.horizontal, Metrics.horizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(focusBackground)
        .help(row.url)
        .contextMenu {
            Button {
                openPR(row.url)
            } label: {
                Label(Strings.openPRActionLabel, systemImage: Glyph.openPR)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Strings.openPRActionLabel) { openPR(row.url) }
    }

    @ViewBuilder private var focusBackground: some View {
        if isFocused {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(0.25))
                .padding(.horizontal, 6)
        }
    }
}
