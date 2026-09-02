import BranchBarCore
import Foundation

/// Text a repository owns, on its way into SwiftUI.
///
/// codex round 4, MINOR 2. Branch names, repo folder names, worktree paths, PR titles, and the git
/// and `gh` messages a notice carries are all written by something other than this app, and until
/// now the CLI table and the log escaped them while the popover — the surface a person actually
/// reads — rendered them exactly as they arrived. Git accepts a ref name containing U+202E, and a
/// branch called `feature\u{202E}drowssap` reorders the glyphs that follow it: the row's PR pill,
/// its push line, and the row beneath it can be made to read as something other than what they
/// say. That is the same lie `SafeText` was written for in codex round 3, one layer up.
///
/// Two members because the two destinations differ. `display` is for anything laid out beside
/// other text: it escapes every control scalar (Core's `SafeText.escapingControlScalars`, which
/// covers C0, DEL, C1, and the bidi overrides and isolates) and then wraps the result in
/// FSI…PDI, so a name that is *genuinely* right-to-left lays itself out inside its own run and
/// cannot reorder the pill or the label next to it. `spoken` is for VoiceOver labels and tooltips,
/// which are read out or shown alone: the escaping matters there and the isolate scalars would be
/// two characters a screen reader has no reason to meet.
///
/// The isolate is unconditional here, unlike `SafeText.displayCell`, which skips it for an
/// all-ASCII cell so a byte-compared table stays byte-comparable. Nothing compares the popover
/// byte for byte, and "every untrusted field is isolated" is a rule with no exception to remember.
enum RepositoryText {

    /// Escaped and isolated: the form for a `Text` that shares a line with anything else.
    static func display(_ raw: String) -> String {
        SafeText.isolatePrefix + SafeText.escapingControlScalars(raw) + SafeText.isolateSuffix
    }

    /// Optional convenience, so a view can keep `if let` around a field the view model may not
    /// carry.
    static func display(_ raw: String?) -> String? {
        raw.map(display)
    }

    /// Escaped only: for a VoiceOver label or a tooltip, which is spoken or shown on its own.
    static func spoken(_ raw: String) -> String {
        SafeText.escapingControlScalars(raw)
    }
}
