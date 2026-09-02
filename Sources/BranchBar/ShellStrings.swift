import BranchBarCore

/// Copy that packet 4.2 needs and `Sources/BranchBarCore/Strings.swift` does not carry.
///
/// It lives in the app target rather than in `Strings.swift` for two reasons. The write boundary
/// for this packet is `Sources/BranchBar/**`, and `StringsTests.everyFixtureStringIsRenderedOrOnAFrozenExemptionList`
/// pins the exact set of `Strings` members, so a new member there is a failing test rather than a
/// new string. These are the same kind of thing packet 2.2 recorded as view-owned chrome
/// (DECISION-LOG): fixed labels with no view-model field and no state fixture that produces them.
///
/// The gap is reported with the packet: per-row Hide, the "Show hidden" footer control, and every
/// launch-at-login outcome beyond the toggle's own label have no `Strings` member. A follow-up in
/// Core would move these across and extend the exemption list.
enum ShellStrings {

    // MARK: - Per-row Hide (PLAN.md §8 packet 4.2)

    /// Drops one repo out of the list. The app never deletes anything, so the wording is about
    /// this list and not about the repo on disk.
    static let hideRepoActionLabel = "Hide this repo"

    /// The way back, offered on a repo that is only visible because "Show hidden" is on.
    static let unhideRepoActionLabel = "Stop hiding this repo"

    /// Footer toggle. The count is what tells a user a hidden repo exists at all — without it the
    /// only evidence of hiding is a repo that is not there.
    static func showHiddenToggleLabel(count: Int) -> String {
        "Show hidden (\(count))"
    }

    /// Above a repo that is showing only because the toggle is on.
    static let hiddenRepoMarker = "Hidden"

    // MARK: - Launch at login (PLAN.md §3, §5b)

    /// `SMAppService` returned `.requiresApproval`: BranchBar registered, and macOS is waiting for
    /// the user to allow it in the one place that can allow it.
    static let launchAtLoginNeedsApproval =
        "macOS is waiting for approval. Open System Settings → General → Login Items and turn "
        + "BranchBar on under \u{201C}Open at Login\u{201D}."

    /// The 0.2 spike's translocation finding, said to the user: a quarantined bundle runs from a
    /// throwaway copy under `/private/var/folders/…/AppTranslocation/`, and registering that path
    /// would register a folder that disappears.
    static let launchAtLoginTranslocated =
        "Move BranchBar to your Applications folder and open it from there, then this can be "
        + "turned on. Right now it is running from a temporary copy macOS made."

    /// No bundle identifier: `swift run`, or a bundle whose Info.plist did not come along.
    static let launchAtLoginUnbundled =
        "This only works from the BranchBar app in your Applications folder."

    /// The LaunchAgent fallback writes an absolute path, so the app has to be at that path.
    static let launchAtLoginNotInApplications =
        "Copy BranchBar into your Applications folder first — the login item points at "
        + "/Applications/BranchBar.app."

    /// Both mechanisms refused. The diagnostic goes to the log, never into this sentence.
    static let launchAtLoginFailed =
        "macOS would not add BranchBar to your login items. The log has the details."

    // MARK: - The gh sign-in setup action (PLAN.md §3)

    /// Header of the `.command` file the sign-in action opens in Terminal, so the window a user
    /// lands in says what it is before they read the command.
    static let ghSignInScriptBanner = "BranchBar: sign in to the GitHub CLI"

    // MARK: - Grant folder access

    /// macOS's own pane, named the way the user will see it.
    static let filesAndFoldersSettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
}
