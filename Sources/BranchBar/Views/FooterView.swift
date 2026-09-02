import BranchBarCore
import SwiftUI

/// Pinned below the scroll region: what the list is, when it was updated, and every control that
/// acts on the whole app rather than on one row.
///
/// The launch-at-login toggle is a disabled placeholder. `SMAppService` is packet 4.2's, and a
/// toggle that flips without doing anything would be a lie, so it says what it is in its tooltip.
struct FooterView: View {
    let footer: FooterVM
    let isRefreshing: Bool
    let perform: (UserFacingFailure.Action) -> Void
    let refresh: (RefreshReason) -> Void
    let addFolder: () -> Void
    let removeRoot: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()

            if let notice = footer.toolNotice {
                NoticeView(notice: notice, perform: perform)
                    .padding(.horizontal, Metrics.horizontalPadding)
            }

            if !footer.scanRoots.isEmpty { scanRoots }

            Text(footer.updatedLabel)
                .font(.caption)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .lineLimit(1)
                .padding(.horizontal, Metrics.horizontalPadding)
                .frame(minHeight: Metrics.footerHeight, alignment: .leading)

            // Two rows of two rather than one row of four: at 340 pt a single row truncates
            // "Refresh PRs now" to "Refresh PRs…", and a control whose label is guessed at is a
            // control the user has to click to find out about.
            HStack(spacing: 8) {
                Button {
                    refresh(.manual)
                } label: {
                    Label(Strings.refreshActionLabel, systemImage: Glyph.refresh).fixedSize()
                }
                .disabled(isRefreshing)
                Button {
                    refresh(.refreshPRsNow)
                } label: {
                    Label(Strings.refreshPRsNowActionLabel, systemImage: Glyph.refresh).fixedSize()
                }
                .disabled(isRefreshing)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .padding(.horizontal, Metrics.horizontalPadding)

            HStack(spacing: 8) {
                Button {
                    refresh(.rescan)
                } label: {
                    Label(Strings.rescanActionLabel, systemImage: Glyph.rescan).fixedSize()
                }
                .disabled(isRefreshing)
                Button {
                    addFolder()
                } label: {
                    Label(Strings.addFolderActionLabel, systemImage: Glyph.addFolder).fixedSize()
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .padding(.horizontal, Metrics.horizontalPadding)

            Toggle(Strings.launchAtLoginToggleLabel, isOn: .constant(false))
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(true)
                .help("coming in the next packet")
                .padding(.horizontal, Metrics.horizontalPadding)

            HStack {
                Text(footer.version)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                Spacer(minLength: 0)
                Button(Strings.quitActionLabel) { Actions.quit() }
                    .font(.caption)
                    .buttonStyle(.link)
            }
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.bottom, 8)
        }
    }

    /// PLAN.md §3: the roots the user added are listed and removable, so "Add folder…" is not a
    /// one-way door.
    private var scanRoots: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Strings.scanRootsHeading)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(footer.scanRoots, id: \.self) { root in
                HStack(spacing: 6) {
                    Text(root)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(root)
                    Spacer(minLength: 0)
                    Button {
                        removeRoot(root)
                    } label: {
                        Label(Strings.removeScanRootActionLabel, systemImage: Glyph.removeRoot)
                            .labelStyle(.titleAndIcon)
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                    .accessibilityLabel("\(Strings.removeScanRootActionLabel) \(root)")
                }
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
    }
}
