import BranchBarCore
import SwiftUI

/// One repo: a title row with the collapse chevron, then the four groups in the order §5a fixed.
/// Collapsed, it shows the title and the PR notice and nothing else — which is also why `gh` never
/// runs for it, so collapse is a cost control as well as a layout choice.
struct RepoSectionView: View {
    let section: RepoSectionVM
    let focus: RowFocus?
    /// True only while the footer's "Show hidden" is on: a hidden repo is normally filtered out
    /// before the presenter ever sees it.
    let isHidden: Bool
    let toggleCollapse: (RepoID) -> Void
    let hide: (RepoID) -> Void
    let unhide: (RepoID) -> Void
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
                if isHidden {
                    Text(ShellStrings.hiddenRepoMarker)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(height: Metrics.sectionHeaderHeight)
            .padding(.horizontal, Metrics.horizontalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(headerBackground)
        .contextMenu { headerMenu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isHidden ? "\(section.title), \(ShellStrings.hiddenRepoMarker)" : section.title)
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
        // VoiceOver reaches a context menu through the rotor's actions, so every menu item is also
        // an accessibility action; §5a's rule is that a control the mouse has, the keyboard has.
        .accessibilityAction(named: hideActionLabel) { toggleHidden() }
        .accessibilityActions {
            if let path = repoPath {
                Button(Strings.revealInFinderActionLabel) { Actions.revealInFinder(path: path) }
                Button(Strings.copyPathActionLabel) { Actions.copyPath(path) }
            }
        }
    }

    /// Per-row Hide (PLAN.md §8 packet 4.2) plus the two folder actions that make sense for a whole
    /// repo. Nothing here deletes: hiding drops the repo out of this list and out of every future
    /// refresh's `gh` budget, and the repo on disk is untouched.
    @ViewBuilder private var headerMenu: some View {
        Button {
            toggleHidden()
        } label: {
            Label(hideActionLabel, systemImage: isHidden ? Glyph.unhide : Glyph.hide)
        }
        if let path = repoPath {
            Divider()
            Button {
                Actions.openInAvailableEditor(path: path)
            } label: {
                Label(Actions.openInAvailableEditorLabel, systemImage: Glyph.openInEditor)
            }
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

    private var hideActionLabel: String {
        isHidden ? ShellStrings.unhideRepoActionLabel : ShellStrings.hideRepoActionLabel
    }

    private func toggleHidden() {
        if isHidden { unhide(section.id) } else { hide(section.id) }
    }

    /// The repo's own folder. `RepoSectionVM` carries no path — the presenter had no reason to add
    /// one — so it comes off the first row whose primary action names an absolute path, which is
    /// the checked-out worktree the row would open. Nil for a repo whose rows have not loaded yet,
    /// and the menu then offers Hide alone rather than a Finder item that would open nothing.
    private var repoPath: String? {
        let rows = section.active + section.merged + section.closedUnmerged
        return rows.compactMap { row -> String? in
            guard let payload = row.primaryAction.payload, payload.hasPrefix("/") else { return nil }
            return payload
        }.first
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
