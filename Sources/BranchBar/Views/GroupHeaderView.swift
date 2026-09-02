import SwiftUI

/// One of the four group headings. An empty group is never rendered — no heading, no placeholder
/// row — so this view only ever appears above rows that exist.
///
/// The heading strings have no view-model field of their own: packet 2.2 recorded them as
/// view-owned chrome (DECISION-LOG) and the test `everyFixtureStringIsRenderedOrOnAFrozenExemptionList`
/// pins the exact set of 17, so reading them from `Strings` here cannot grow silently.
struct GroupHeaderView: View {
    let title: String
    /// "Open PRs not on this Mac" carries a second line explaining what the group is.
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(height: Metrics.groupHeadingHeight, alignment: .leading)

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}
