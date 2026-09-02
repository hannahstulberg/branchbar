import BranchBarCore
import SwiftUI

/// One branch row, in the four tiers docs/UI-CONTRACT.md section 3 froze: worktree marker leading,
/// branch name primary, PR pill secondary, push line and ahead count tertiary. The tooltip and the
/// VoiceOver label come straight off the view model; nothing here composes copy.
struct BranchRowView: View {
    let row: BranchRowVM
    let isFocused: Bool
    let perform: (UserFacingFailure.Action) -> Void

    var body: some View {
        Button(action: { perform(row.primaryAction) }) {
            HStack(alignment: .top, spacing: 6) {
                DecorativeIcon(name: leadingGlyph)
                    .frame(width: Metrics.glyphColumn, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.title)
                            .font(.body)
                            .foregroundStyle(Color(nsColor: .labelColor))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let pill = row.prPill { PRPillView(pill: pill) }
                        Spacer(minLength: 0)
                    }

                    if let marker = row.worktreeMarker, !marker.isEmpty {
                        Text(marker)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if !row.pushLabel.isEmpty {
                        HStack(spacing: 4) {
                            DecorativeIcon(name: pushGlyph, font: .caption2)
                            Text(row.pushLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let ahead = row.aheadLabel, !ahead.isEmpty {
                        HStack(spacing: 4) {
                            if showsAheadGlyph { DecorativeIcon(name: Glyph.ahead, font: .caption2) }
                            Text(ahead)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(minHeight: minimumHeight, alignment: .top)
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(focusBackground)
        .help(row.pushTooltip)
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: row.primaryAction.label) { perform(row.primaryAction) }
    }

    /// The secondary actions §5a names. `BranchRowVM` holds only `primaryAction`, so these labels
    /// are view-owned chrome pinned by packet 2.2's frozen exemption list.
    @ViewBuilder private var menu: some View {
        Button {
            perform(row.primaryAction)
        } label: {
            Label(row.primaryAction.label, systemImage: Glyph.openInEditor)
        }
        if let path = folderPath {
            Button {
                Actions.revealInFinder(path: path)
            } label: {
                Label(Strings.revealInFinderActionLabel, systemImage: Glyph.revealInFinder)
            }
            Button {
                Actions.copyPath(path)
            } label: {
                Label(Strings.copyPathActionLabel, systemImage: Glyph.copyPath)
            }
        }
    }

    /// A row's primary action is `.openURL` carrying an absolute path (DECISION-LOG, packet 2.2),
    /// which is also the folder Finder and the clipboard want.
    private var folderPath: String? {
        guard let payload = row.primaryAction.payload, payload.hasPrefix("/") else { return nil }
        return payload
    }

    private var leadingGlyph: String {
        guard let marker = row.worktreeMarker, !marker.isEmpty else { return Glyph.branch }
        // A worktree with no branch is titled by its folder and has no push fact at all.
        return row.pushLabel.isEmpty ? Glyph.worktreeNoBranch : Glyph.worktree
    }

    /// Chosen off the tooltip, which is a `Strings` constant, rather than by reading the label —
    /// the label carries a date and the tooltip does not.
    private var pushGlyph: String {
        row.pushTooltip.hasPrefix(Strings.pushedTooltip) ? Glyph.pushObserved : Glyph.pushUnknown
    }

    private var showsAheadGlyph: Bool {
        guard let ahead = row.aheadLabel else { return false }
        return !ahead.hasPrefix(Strings.inSync)
            && !ahead.hasPrefix(Strings.noUpstream)
            && !ahead.hasPrefix(Strings.upstreamMissing)
    }

    private var minimumHeight: CGFloat {
        row.pushLabel.isEmpty ? Metrics.branchRowSingleLineHeight : Metrics.branchRowHeight
    }

    @ViewBuilder private var focusBackground: some View {
        if isFocused {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(0.25))
                .padding(.horizontal, 6)
        }
    }
}
