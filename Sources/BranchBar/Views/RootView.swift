import AppKit
import BranchBarCore
import SwiftUI

/// Which row the keyboard is on. Identity is the repo plus the group plus the index rather than a
/// row's title, because two repos can hold a branch of the same name and a title is not an id.
enum RowFocus: Hashable {
    enum Group: Hashable {
        case active
        case merged
        case closedUnmerged
    }

    case section(RepoID)
    case branchRow(RepoID, Group, Int)
    case prRow(RepoID, Int)
}

/// The popover. 340 pt wide and never wider; the repo list scrolls inside a height capped at 70 %
/// of the screen while the footer stays pinned below it, so Quit and Refresh cannot be pushed off
/// the bottom by a Mac with forty repos on it.
struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var focus: RowFocus?
    @State private var contentHeight: CGFloat = 0
    @FocusState private var listHasFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    // codex MAJOR 4 / REVIEW CR-04: a refresh that failed before it could produce a
                    // snapshot — no git on the Mac — has no repo section and no scan result to hang
                    // a notice on, so the failure is rendered here, from the state itself. It
                    // replaces the empty state rather than sitting above it: "No repos found" is
                    // not the reason, and offering "Add folder…" for a missing git is a dead end.
                    if let failure = refreshFailure {
                        NoticeView(
                            notice: NoticeVM(
                                text: "\(failure.title)\n\(failure.message)",
                                action: failure.action),
                            perform: model.perform)
                            .padding(.horizontal, Metrics.horizontalPadding)
                            .padding(.vertical, 8)
                    } else if let empty = model.vm.emptyState {
                        EmptyStateView(state: empty, perform: model.perform)
                    }
                    ForEach(model.vm.sections, id: \.id) { section in
                        RepoSectionView(
                            section: section,
                            focus: focus,
                            isHidden: model.isHidden(section.id),
                            toggleCollapse: model.toggleCollapse,
                            hide: model.hide,
                            unhide: model.unhide,
                            perform: model.perform,
                            openPR: { Actions.openPR(url: $0, host: section.host) })
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    })
            }
            // A `ScrollView` has no ideal height of its own, so a popover built around one comes
            // out either 10 pt tall or as tall as the screen. Measuring the list is what lets the
            // popover be exactly as tall as it needs to be, and no taller than the 70 % cap.
            .frame(height: min(max(contentHeight, 1), Metrics.maxPopoverHeight))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }

            FooterView(
                footer: model.vm.footer,
                isRefreshing: isRefreshing,
                perform: model.perform,
                refresh: { model.refresh(reason: $0) },
                addFolder: { if let url = Actions.pickFolder() { model.addFolder(url) } },
                removeRoot: model.removeRoot,
                hiddenCount: model.hiddenRepoIDs.count,
                showsHidden: model.showsHiddenRepos,
                setShowsHidden: model.setShowsHiddenRepos,
                launchAtLoginIsOn: model.launchAtLoginIsOn,
                launchAtLoginIsAvailable: !model.isPreviewing && LaunchAtLogin.isAvailable,
                launchAtLoginNotice: model.launchAtLoginNotice,
                setLaunchAtLogin: model.setLaunchAtLogin)

            // Return runs the focused row's primary action. `onKeyPress` is macOS 14; a hidden
            // button carrying the Return shortcut is the macOS 13 way to say the same thing.
            Button("", action: runFocusedAction)
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .frame(width: Metrics.popoverWidth)
        .focusable()
        .focused($listHasFocus)
        .onMoveCommand(perform: move)
        .onExitCommand(perform: dismiss)
        // Focus starts nowhere: a highlighted row at rest reads as a selection the user did not
        // make. The first arrow key puts it on the first row.
        .onAppear { listHasFocus = true }
    }

    private var isRefreshing: Bool {
        if case .running = model.refreshState { return true }
        return false
    }

    /// The failure a refresh ended in, if it ended in one. `.failed` is not `.running`, so the
    /// footer's buttons are live and the user can act on what the notice says.
    private var refreshFailure: UserFacingFailure? {
        if case .failed(let failure) = model.refreshState { return failure }
        return nil
    }

    // MARK: - Keyboard

    /// Every focusable thing, in the order it is drawn. Rebuilt per keystroke rather than cached:
    /// a progressive emit can add rows between two arrow presses, and a stale order would move the
    /// selection to a row that is no longer there.
    private var focusOrder: [RowFocus] {
        var order: [RowFocus] = []
        for section in model.vm.sections {
            order.append(.section(section.id))
            guard !section.isCollapsed else { continue }
            order += section.active.indices.map { .branchRow(section.id, .active, $0) }
            order += section.openElsewhere.indices.map { .prRow(section.id, $0) }
            order += section.merged.indices.map { .branchRow(section.id, .merged, $0) }
            order += section.closedUnmerged.indices.map { .branchRow(section.id, .closedUnmerged, $0) }
        }
        return order
    }

    private func move(_ direction: MoveCommandDirection) {
        let order = focusOrder
        guard !order.isEmpty else { return }
        guard focus != nil else {
            focus = direction == .up ? order.last : order.first
            return
        }
        switch direction {
        case .down:
            let index = focus.flatMap { order.firstIndex(of: $0) }
            focus = order[min((index ?? -1) + 1, order.count - 1)]
        case .up:
            let index = focus.flatMap { order.firstIndex(of: $0) }
            focus = order[max((index ?? 1) - 1, 0)]
        case .right:
            // Right opens a collapsed repo, left closes an open one: the disclosure behaviour a
            // list gives its rows everywhere else on the Mac.
            if case .section(let id) = focus,
               let section = model.vm.sections.first(where: { $0.id == id }),
               section.isCollapsed {
                model.toggleCollapse(id)
            }
        case .left:
            if case .section(let id) = focus,
               let section = model.vm.sections.first(where: { $0.id == id }),
               !section.isCollapsed {
                model.toggleCollapse(id)
            }
        @unknown default:
            break
        }
    }

    private func runFocusedAction() {
        guard let focus else { return }
        switch focus {
        case .section(let id):
            model.toggleCollapse(id)
        case .branchRow(let id, let group, let index):
            guard let section = model.vm.sections.first(where: { $0.id == id }) else { return }
            let rows: [BranchRowVM]
            switch group {
            case .active: rows = section.active
            case .merged: rows = section.merged
            case .closedUnmerged: rows = section.closedUnmerged
            }
            guard rows.indices.contains(index) else { return }
            model.perform(rows[index].primaryAction)
        case .prRow(let id, let index):
            guard let section = model.vm.sections.first(where: { $0.id == id }),
                  section.openElsewhere.indices.contains(index)
            else { return }
            Actions.openPR(url: section.openElsewhere[index].url, host: section.host)
        }
    }

    /// Escape dismisses. A `MenuBarExtra(.window)` popover is an ordinary key window, so closing
    /// it is what putting it away means.
    private func dismiss() {
        NSApp.keyWindow?.close()
    }
}


/// The measured height of the repo list, reported up so the popover can size itself to its
/// content.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
