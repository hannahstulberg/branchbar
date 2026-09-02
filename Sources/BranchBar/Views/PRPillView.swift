import BranchBarCore
import SwiftUI

/// docs/UI-CONTRACT.md section 4: a 16 pt capsule, 6 pt horizontal padding, corner radius 8.
/// Filled variants put the status colour behind the text at 12 % opacity; outline variants draw a
/// 1 pt border and no fill; `notChecked` dashes that border. Shape carries "BranchBar knows this
/// PR's state" so the three unknown states stay legible without a colour of their own, and no
/// emoji ever carries status (§5a accessibility).
struct PRPillView: View {
    let pill: PRPillVM

    var body: some View {
        label
            .fixedSize()
            .accessibilityHidden(true)
    }

    @ViewBuilder private var label: some View {
        switch pill.status.pillTreatment {
        case .textOnly:
            text
        case .filled:
            text
                .padding(.horizontal, Metrics.pillHorizontalPadding)
                .frame(height: Metrics.pillHeight)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.pillCornerRadius, style: .continuous)
                        .fill(pill.status.tokenColor.opacity(0.12)))
        case .outline:
            bordered(dashed: false, warning: false)
        case .outlineWarning:
            bordered(dashed: false, warning: true)
        case .dashedOutline:
            bordered(dashed: true, warning: false)
        }
    }

    private var text: some View {
        Text(pill.text)
            .font(.caption.weight(.medium))
            .foregroundStyle(pill.status.tokenColor)
    }

    private func bordered(dashed: Bool, warning: Bool) -> some View {
        HStack(spacing: 3) {
            if warning { DecorativeIcon(name: Glyph.warning, font: .caption2) }
            text
        }
        .padding(.horizontal, Metrics.pillHorizontalPadding)
        .frame(height: Metrics.pillHeight)
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.pillCornerRadius, style: .continuous)
                .strokeBorder(
                    pill.status.tokenColor,
                    style: StrokeStyle(lineWidth: 1, dash: dashed ? [2, 2] : [])))
    }
}
