import BranchBarCore
import SwiftUI

/// A `NoticeVM`: the joined copy plus the one action its reason offers
/// (`unavailableReasonCopyNamesOneActionPerReason`). Notices are pinned above the scroll region,
/// never inside it, so the reason a repo looks the way it does cannot scroll out of sight.
struct NoticeView: View {
    let notice: NoticeVM
    /// Nil where the icon table names no glyph for what the notice says. "PR status loads when
    /// expanded" is not a warning, and borrowing the warning triangle for it would overstate a
    /// sentence that is only telling the user what a closed section is holding back.
    var glyph: String? = Glyph.warning
    let perform: (UserFacingFailure.Action) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Group {
                if let glyph { DecorativeIcon(name: glyph) } else { Color.clear }
            }
            .frame(width: Metrics.glyphColumn, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                // A notice joins Core's copy with the message a failure carried, and a git or
                // `gh` failure quotes the repository back (codex round 4, MINOR 2).
                Text(RepositoryText.display(notice.text))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let action = notice.action {
                    Button(action.label) { perform(action) }
                        .font(.caption)
                        .buttonStyle(.link)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The TCC-denied folders plus the categories the scan skips on purpose. Its own view because the
/// contract gives it its own glyph and its own action, and because "not scanned" is a claim about
/// the whole Mac rather than about the repo whose section carries it.
struct NotScannedView: View {
    let notice: NoticeVM
    let perform: (UserFacingFailure.Action) -> Void

    var body: some View {
        NoticeView(notice: notice, glyph: Glyph.notScanned, perform: perform)
    }
}
