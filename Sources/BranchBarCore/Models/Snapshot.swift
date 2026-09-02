import Foundation

/// One complete answer to "what is on this Mac right now". PLAN.md §5.
/// `repos` is in stable order (most recently active first, computed once per refresh);
/// invariant `rowOrderIsStableAcrossProgressiveEmits`.
public struct Snapshot: Hashable, Codable, Sendable {
    public var repos: [Repo]
    public var refreshedAt: Date?
    public var tools: ToolStatus

    public init(repos: [Repo] = [], refreshedAt: Date? = nil, tools: ToolStatus = ToolStatus()) {
        self.repos = repos
        self.refreshedAt = refreshedAt
        self.tools = tools
    }
}

/// What the preflight found. Produced by `ToolLocator` (packet 0.3 owns that file); this type
/// is the value it hands the coordinator, and it is frozen here so packet 1.1 does not have to
/// name `ToolLocator` at all.
// depends on ToolLocator (packet 0.3)
public struct ToolStatus: Hashable, Codable, Sendable {
    public var gitPath: String?
    /// `git --version` output; PLAN.md §5 raises a tool notice below 2.39.
    public var gitVersion: String?
    public var ghPath: String?
    /// `gh auth status --hostname <host>` result, one entry per distinct host per refresh.
    public var ghAuthByHost: [String: Bool]

    public init(
        gitPath: String? = nil,
        gitVersion: String? = nil,
        ghPath: String? = nil,
        ghAuthByHost: [String: Bool] = [:]
    ) {
        self.gitPath = gitPath
        self.gitVersion = gitVersion
        self.ghPath = ghPath
        self.ghAuthByHost = ghAuthByHost
    }
}
