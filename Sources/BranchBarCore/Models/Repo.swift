import Foundation

// PLAN.md §5, frozen in packet 1.1. Every type in this directory is
// `Hashable, Codable, Sendable` so a `Snapshot` round-trips through `CacheFile`
// and crosses actor boundaries without a copy of the rules living anywhere else.

/// Identity of a repository. PLAN.md §3 dedupes discovered repos by
/// `git rev-parse --git-common-dir`, so a linked worktree and its primary are one repo.
public struct RepoID: Hashable, Codable, Sendable {
    /// Absolute path printed by `git rev-parse --path-format=absolute --git-common-dir`.
    public var commonDir: String

    public init(commonDir: String) {
        self.commonDir = commonDir
    }
}

/// `host/owner/name` parsed out of `remote.origin.url`. Any host: PLAN.md §2 does not
/// rule out GitHub Enterprise at NYT, and §5 says the host comes from the remote URL.
///
/// This is the one behavioral type packet 1.1 implements, because every later packet
/// needs a real slug to build a `gh --repo` argument with.
public struct GitHubSlug: Hashable, Codable, Sendable {
    /// Lower-cased host, never a port and never user info.
    public var host: String
    public var owner: String
    public var name: String

    public init(host: String, owner: String, name: String) {
        self.host = host
        self.owner = owner
        self.name = name
    }

    /// The `--repo` operand of every `gh pr list` invocation in PLAN.md §5.
    public var ghRepoArgument: String { "\(host)/\(owner)/\(name)" }

    /// Parses the string `git config --get remote.origin.url` prints.
    ///
    /// Handles the four shapes git writes — `https://host/owner/name(.git)`,
    /// `ssh://user@host(:port)/owner/name(.git)`, `git://host/owner/name(.git)`, and the
    /// scp-like `user@host:owner/name(.git)` — with or without `.git`, with or without a
    /// trailing slash. Returns `nil` for anything that is not a host plus at least two path
    /// components, which is how a local path, a `file://` URL, or a malformed remote reaches
    /// `PRUnavailableReason.notGitHubRemote` instead of a bad `gh` call.
    ///
    /// Deliberately no network and no allow-list of hosts: the host is reported as written
    /// (lower-cased) and `gh auth status --hostname <host>` decides whether it is reachable.
    public init?(remoteURL: String) {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let hostAndPath: (host: String, path: String)

        if let schemeRange = trimmed.range(of: "://") {
            // scheme://[user[:password]@]host[:port]/path
            let scheme = trimmed[trimmed.startIndex..<schemeRange.lowerBound].lowercased()
            guard ["https", "http", "ssh", "git"].contains(scheme) else { return nil }

            let rest = String(trimmed[schemeRange.upperBound...])
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var authority = String(rest[rest.startIndex..<slash])
            let path = String(rest[rest.index(after: slash)...])

            if let at = authority.lastIndex(of: "@") {
                authority = String(authority[authority.index(after: at)...])
            }
            if let colon = authority.lastIndex(of: ":") {
                authority = String(authority[authority.startIndex..<colon])
            }
            guard !authority.isEmpty else { return nil }
            hostAndPath = (authority, path)
        } else if let colon = trimmed.firstIndex(of: ":"), !trimmed.hasPrefix("/") {
            // scp-like: [user@]host:owner/name
            var authority = String(trimmed[trimmed.startIndex..<colon])
            let path = String(trimmed[trimmed.index(after: colon)...])
            if let at = authority.lastIndex(of: "@") {
                authority = String(authority[authority.index(after: at)...])
            }
            guard !authority.isEmpty, authority.contains(".") || authority.contains("localhost") else { return nil }
            hostAndPath = (authority, path)
        } else {
            return nil
        }

        var components = hostAndPath.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count >= 2 else { return nil }

        var last = components.removeLast()
        if last.hasSuffix(".git") { last.removeLast(4) }
        guard !last.isEmpty, let owner = components.last, !owner.isEmpty else { return nil }

        self.host = hostAndPath.host.lowercased()
        self.owner = owner
        self.name = last
    }
}

/// One repository as the UI sees it. PLAN.md §5.
public struct Repo: Hashable, Codable, Sendable {
    public var id: RepoID
    /// Last path component of `path`, shown as the section title.
    public var name: String
    /// Absolute working-tree path of the primary worktree.
    public var path: String
    public var remoteURL: String?
    public var githubSlug: GitHubSlug?
    public var worktrees: [Worktree]
    public var branches: [Branch]
    /// PLAN.md §3: author-@me PRs whose (head owner login, head branch) matches no local branch.
    public var openPRsNotOnThisMac: [PRInfo]
    public var prAvailability: PRAvailability
    public var prFetchedAt: Date?
    public var prLoadState: PRLoadState
    public var lastRefreshed: Date?
    public var errors: [RepoError]
    /// True when the overall 45 s deadline cut this repo off mid-refresh.
    public var isStale: Bool
    /// Newest committer date across the repo's branches; decides section order.
    public var lastActivity: Date?

    public init(
        id: RepoID,
        name: String,
        path: String,
        remoteURL: String? = nil,
        githubSlug: GitHubSlug? = nil,
        worktrees: [Worktree] = [],
        branches: [Branch] = [],
        openPRsNotOnThisMac: [PRInfo] = [],
        prAvailability: PRAvailability = .available,
        prFetchedAt: Date? = nil,
        prLoadState: PRLoadState = .notLoaded,
        lastRefreshed: Date? = nil,
        errors: [RepoError] = [],
        isStale: Bool = false,
        lastActivity: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.remoteURL = remoteURL
        self.githubSlug = githubSlug
        self.worktrees = worktrees
        self.branches = branches
        self.openPRsNotOnThisMac = openPRsNotOnThisMac
        self.prAvailability = prAvailability
        self.prFetchedAt = prFetchedAt
        self.prLoadState = prLoadState
        self.lastRefreshed = lastRefreshed
        self.errors = errors
        self.isStale = isStale
        self.lastActivity = lastActivity
    }
}

/// PLAN.md §5. One repo failing a stage never blanks the others (`oneRepoFailingLeavesOthersPopulated`).
public struct RepoError: Hashable, Codable, Sendable {
    public enum Stage: String, Hashable, Codable, Sendable, CaseIterable {
        case branches
        case worktrees
        case remotes
        case reflog
        case github
        case deadlineExceeded
    }

    public var stage: Stage
    public var message: String

    public init(stage: Stage, message: String) {
        self.stage = stage
        self.message = message
    }
}
