import BranchBarCore
import SwiftUI

/// Pinned below the scroll region: what the list is, when it was updated, and every control that
/// acts on the whole app rather than on one row.
struct FooterView: View {
    let footer: FooterVM
    let isRefreshing: Bool
    let perform: (UserFacingFailure.Action) -> Void
    let refresh: (RefreshReason) -> Void
    let addFolder: () -> Void
    let removeRoot: (String) -> Void

    /// How many repos are hidden, and whether they are being shown anyway. Zero hidden repos means
    /// no control at all — a "Show hidden (0)" checkbox is a control with nothing behind it.
    let hiddenCount: Int
    let showsHidden: Bool
    let setShowsHidden: (Bool) -> Void

    let launchAtLoginIsOn: Bool
    let launchAtLoginIsAvailable: Bool
    /// Why the toggle is off-limits, or what macOS is waiting for. Rendered under the toggle.
    let launchAtLoginNotice: String?
    let setLaunchAtLogin: (Bool) -> Void

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

            if hiddenCount > 0 { showHidden }

            launchAtLogin

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

    /// Hiding a repo is reversible, and this is the reversal: turning it on puts the hidden repos
    /// back in the list, each carrying "Stop hiding this repo" in its context menu. The count is
    /// the only evidence a hidden repo exists, so it is in the label rather than in a tooltip.
    private var showHidden: some View {
        Toggle(
            ShellStrings.showHiddenToggleLabel(count: hiddenCount),
            isOn: Binding(get: { showsHidden }, set: setShowsHidden)
        )
        .toggleStyle(.checkbox)
        .font(.caption)
        .padding(.horizontal, Metrics.horizontalPadding)
        .accessibilityHint(ShellStrings.unhideRepoActionLabel)
    }

    /// PLAN.md §3's opt-in toggle. Disabled rather than hidden where it cannot work, because a
    /// missing control tells a user nothing and a disabled one with a sentence under it tells them
    /// what to do about it.
    private var launchAtLogin: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(
                Strings.launchAtLoginToggleLabel,
                isOn: Binding(get: { launchAtLoginIsOn }, set: setLaunchAtLogin)
            )
            .toggleStyle(.checkbox)
            .font(.caption)
            .disabled(!launchAtLoginIsAvailable)

            if let notice = launchAtLoginNotice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityHint(launchAtLoginNotice ?? "")
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
