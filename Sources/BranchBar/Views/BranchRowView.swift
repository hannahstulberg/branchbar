import BranchBarCore
import SwiftUI

/// One branch row, in the four tiers docs/UI-CONTRACT.md section 3 froze: worktree marker leading,
/// branch name primary, PR pill secondary, push line and ahead count tertiary. The tooltip and the
/// VoiceOver label come straight off the view model; nothing here composes copy.
struct BranchRowView: View {
    let row: BranchRowVM
    let isFocused: Bool
    let perform: (UserFacingFailure.Action) -> Void
    /// The repo's validated GitHub host (`RepoSectionVM.host`). `Actions.openPR` refuses a link
    /// that does not match it, so the row cannot open an address the repo does not own.
    let prHost: String?

    var body: some View {
        Button(action: performPrimaryAction) {
            HStack(alignment: .top, spacing: 6) {
                DecorativeIcon(name: leadingGlyph)
                    .frame(width: Metrics.glyphColumn, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // Repository-owned, so escaped and isolated on its way in (codex
                        // round 4, MINOR 2): a branch name may carry bidi controls, and this one
                        // shares its line with the PR pill.
                        Text(RepositoryText.display(row.title))
                            .font(.body)
                            .foregroundStyle(Color(nsColor: .labelColor))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let pill = row.prPill { PRPillView(pill: pill) }
                        Spacer(minLength: 0)
                    }

                    if let marker = row.worktreeMarker, !marker.isEmpty {
                        Text(RepositoryText.display(marker))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if !row.pushLabel.isEmpty {
                        HStack(spacing: 4) {
                            DecorativeIcon(name: pushGlyph, font: .caption2)
                            Text(RepositoryText.display(row.pushLabel))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let ahead = row.aheadLabel, !ahead.isEmpty {
                        HStack(spacing: 4) {
                            if showsAheadGlyph { DecorativeIcon(name: Glyph.ahead, font: .caption2) }
                            // Core copy, but `Strings.ahead(_:remote:)` interpolates the
                            // remote's own name into it.
                            Text(RepositoryText.display(ahead))
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
        .help(RepositoryText.spoken(row.pushTooltip))
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RepositoryText.spoken(row.accessibilityLabel))
        .accessibilityAddTraits(.isButton)
        // VoiceOver reaches a context menu through the rotor, so the item the mouse just gained is
        // an accessibility action too (§5a: a control the mouse has, the keyboard has). The
        // primary action joined them when it became optional: a row whose worktree record is
        // prunable or bare has no folder to open, and an action named after one it does not have
        // is a promise VoiceOver would read aloud.
        .accessibilityActions {
            if let action = row.primaryAction {
                Button(action.label) { perform(action) }
            }
            if let url = row.prURL, !url.isEmpty {
                Button(Strings.openPRActionLabel) { Actions.openPR(url: url, host: prHost) }
            }
        }
    }

    /// The click, and what happens when there is nothing to click: `BranchRowVM.primaryAction` is
    /// optional, because a worktree record git has marked prunable names a folder that is not
    /// there any more (codex round 3, BLOCKER 1). The row still draws — it is a branch the repo
    /// has — and clicking it does nothing but say so in the log.
    private func performPrimaryAction() {
        guard let action = row.primaryAction else {
            Log.info("action: \(row.title) has no folder to open")
            return
        }
        perform(action)
    }

    /// The secondary actions §5a names. `BranchRowVM` holds only `primaryAction`, so these labels
    /// are view-owned chrome pinned by packet 2.2's frozen exemption list.
    @ViewBuilder private var menu: some View {
        if let action = row.primaryAction {
            Button {
                perform(action)
            } label: {
                Label(action.label, systemImage: Glyph.openInEditor)
            }
        }
        // Only on a row whose branch actually matched a PR (packet 4.3's `BranchRowVM.prURL`): an
        // item that opens nothing is worse than no item.
        if let url = row.prURL, !url.isEmpty {
            Button {
                Actions.openPR(url: url, host: prHost)
            } label: {
                Label(Strings.openPRActionLabel, systemImage: Glyph.openPR)
            }
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
        guard let payload = row.primaryAction?.payload, payload.hasPrefix("/") else { return nil }
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

    /// The ahead arrow belongs to exactly one sentence, `Strings.ahead(_:remote:)`, so the row
    /// tests for that sentence rather than excluding the three it must not appear on.
    ///
    /// The exclusion list was `Strings.inSync`, `Strings.noUpstream`, and `Strings.upstreamMissing`
    /// — the origin-only spellings. A branch tracking a fork reads "In sync with last-known fork",
    /// which none of those prefixes match, so an in-sync row drew an ahead arrow (codex round 2,
    /// MAJOR 5 reached the copy but not the glyph). Matching the positive case holds for every
    /// remote and needs no remote name in the view.
    private var showsAheadGlyph: Bool {
        guard let ahead = row.aheadLabel,
              let infix = ahead.range(of: Self.aheadInfix)
        else { return false }
        // "2 ahead of last-known fork" qualifies; "No local commits ahead of last-known origin"
        // carries the same words with a sentence in front of them and does not.
        let count = ahead[ahead.startIndex..<infix.lowerBound]
        return !count.isEmpty && count.allSatisfy(\.isNumber)
    }

    /// " ahead of last-known " — asked of `Strings.ahead(_:remote:)` rather than typed here, so the
    /// row still composes no copy of its own and the wording stays owned by Core.
    private static let aheadInfix: String = {
        let count = 0
        return String(Strings.ahead(count, remote: "").dropFirst("\(count)".count))
    }()

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
