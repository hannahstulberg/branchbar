import BranchBarCore
import SwiftUI

/// One repo: a title row with the collapse chevron, then the four groups in the order §5a fixed.
/// Collapsed, it shows the title and the PR notice and nothing else — which is also why `gh` never
/// runs for it, so collapse is a cost control as well as a layout choice.
struct RepoSectionView: View {
    let section: RepoSectionVM
    let focus: RowFocus?
    let toggleCollapse: (RepoID) -> Void
    let perform: (UserFacingFailure.Action) -> Void
    let openPR: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            header

            if let notice = section.notScannedNotice {
                NotScannedView(notice: notice, perform: perform)
                    .padding(.horizontal, Metrics.horizontalPadding)
            }

            if let notice = section.prNotice {
                NoticeView(notice: notice, glyph: prNoticeGlyph(notice), perform: perform)
                    .padding(.horizontal, Metrics.horizontalPadding)
            }

            if !section.isCollapsed {
                group(Strings.activeGroupHeading, note: nil, rows: section.active)

                if !section.openElsewhere.isEmpty {
                    VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                        GroupHeaderView(
                            title: Strings.openElsewhereGroupHeading,
                            note: Strings.openElsewhereGroupNote
                        )
                        .padding(.horizontal, Metrics.horizontalPadding)
                        ForEach(Array(section.openElsewhere.enumerated()), id: \.offset) { index, row in
                            PRRowView(
                                row: row,
                                isFocused: focus == .prRow(section.id, index),
                                openPR: openPR)
                        }
                    }
                    .padding(.top, Metrics.groupSpacing)
                }

                group(Strings.mergedGroupHeading, note: nil, rows: section.merged, kind: .merged)
                group(
                    Strings.closedUnmergedGroupHeading,
                    note: nil,
                    rows: section.closedUnmerged,
                    kind: .closedUnmerged)
            }
        }
    }

    /// The two "not yet" notices state a fact about what has been asked for, not a problem; the
    /// rest of what lands in this slot (a `PRAvailability` reason, a failed git stage) is a problem
    /// and keeps the warning glyph.
    private func prNoticeGlyph(_ notice: NoticeVM) -> String? {
        let quiet = notice.text == Strings.prNotLoaded || notice.text == Strings.prNotChecked
        return quiet ? nil : Glyph.warning
    }

    // MARK: - Header

    private var header: some View {
        Button(action: { toggleCollapse(section.id) }) {
            HStack(spacing: 6) {
                Image(systemName: section.isCollapsed ? Glyph.collapsed : Glyph.expanded)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Metrics.glyphColumn, alignment: .leading)
                    .accessibilityHidden(true)
                Text(section.title)
                    .font(.headline)
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .frame(height: Metrics.sectionHeaderHeight)
            .padding(.horizontal, Metrics.horizontalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(headerBackground)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(section.title)
        .accessibilityValue(
            section.isCollapsed
                ? Strings.expandSectionActionLabel
                : Strings.collapseSectionActionLabel
        )
        .accessibilityAddTraits(.isHeader)
        .accessibilityAction(
            named: section.isCollapsed
                ? Strings.expandSectionActionLabel
                : Strings.collapseSectionActionLabel
        ) { toggleCollapse(section.id) }
    }

    @ViewBuilder private var headerBackground: some View {
        if focus == .section(section.id) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(0.25))
                .padding(.horizontal, 6)
        }
    }

    // MARK: - Groups

    @ViewBuilder
    private func group(
        _ title: String,
        note: String?,
        rows: [BranchRowVM],
        kind: RowFocus.Group = .active
    ) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                GroupHeaderView(title: title, note: note)
                    .padding(.horizontal, Metrics.horizontalPadding)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    BranchRowView(
                        row: row,
                        isFocused: focus == .branchRow(section.id, kind, index),
                        perform: perform)
                }
            }
            .padding(.top, Metrics.groupSpacing)
        }
    }
}
