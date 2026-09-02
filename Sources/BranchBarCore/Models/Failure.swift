import Foundation

/// A failure the user reads. PLAN.md §5a item 1 gives every state a literal string, and
/// packet 4.0's `Strings.swift` is where those literals live; this type only carries them.
/// `diagnostic` is for the log and never rendered as the message.
public struct UserFacingFailure: Hashable, Codable, Sendable {
    public var title: String
    public var message: String
    /// One action per reason (`unavailableReasonCopyNamesOneActionPerReason`).
    public var action: Action?
    public var diagnostic: String

    /// The button beside a failure. The label is copy; the case is what the shell dispatches on.
    public struct Action: Hashable, Codable, Sendable {
        public enum Kind: String, Hashable, Codable, Sendable, CaseIterable {
            case addFolder
            case openTerminalWithGhAuthLogin
            case openURL
            case retryRefresh
            case rescan
            case grantFolderAccess
        }

        public var label: String
        public var kind: Kind
        /// `gh auth login --hostname <host>` for `openTerminalWithGhAuthLogin`, a URL for `openURL`.
        public var payload: String?

        public init(label: String, kind: Kind, payload: String? = nil) {
            self.label = label
            self.kind = kind
            self.payload = payload
        }
    }

    public init(title: String, message: String, action: Action? = nil, diagnostic: String = "") {
        self.title = title
        self.message = message
        self.action = action
        self.diagnostic = diagnostic
    }
}

/// PLAN.md §5. `running(completed, total)` drives the footer while progressive emits land.
public enum RefreshState: Hashable, Codable, Sendable {
    case idle(lastRefreshedAt: Date?)
    case running(completed: Int, total: Int)
    case failed(UserFacingFailure)
}
