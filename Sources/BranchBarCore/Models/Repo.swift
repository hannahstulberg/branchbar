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

    /// The hostname grammar every decode boundary applies (codex BLOCKER 1).
    ///
    /// A host is not merely displayed text: it reaches `Strings.ghAuthLoginCommand` and, through
    /// the sign-in action, the zsh script `SignInScript.render` writes. A remote URL is repo-owned
    /// data — anyone who can put a folder under `~` can write `.git/config` — so the host is held
    /// to RFC 1123 rather than to "whatever sat between `://` and the first `/`": labels of
    /// `[A-Za-z0-9-]`, 1–63 characters each, no leading or trailing hyphen, separated by single
    /// dots, 253 characters in total. Nothing a shell reads as syntax survives that.
    ///
    /// Case-insensitive by design, because `openPR` checks a `URL.host` that macOS may hand back
    /// in any case; `init?(remoteURL:)` still stores the lower-cased form, which is what the zsh
    /// re-check in `SignInScript` is written against.
    public static func isValidHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard (1...63).contains(label.count) else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            let isLegal = label.unicodeScalars.allSatisfy { scalar in
                ("a"..."z").contains(scalar)
                    || ("A"..."Z").contains(scalar)
                    || ("0"..."9").contains(scalar)
                    || scalar == "-"
            }
            guard isLegal else { return false }
        }
        return true
    }

    /// The one host that is GitHub without asking anybody (codex round 2, MAJOR 6). Every other
    /// host has to be one `gh auth status` already reports a login for.
    public static let gitHubDotCom = "github.com"

    /// The `--repo` operand of every `gh pr list` invocation in PLAN.md §5.
    public var ghRepoArgument: String { "\(host)/\(owner)/\(name)" }

    /// The owner login folded for comparison, never for display (codex round 2, MAJOR 4).
    ///
    /// GitHub logins are case-insensitive: `Contributor` and `contributor` are one account. The
    /// clone URL carries whatever casing was typed and `gh` prints whatever casing the account was
    /// created with, so comparing the two as bytes rejected the user's own PR and left the row
    /// reading "No PR" beside an open one. `owner` keeps its original casing because it is what a
    /// `--repo` operand and a PR link are built from.
    public var ownerKey: String { owner.lowercased() }

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

        // codex BLOCKER 1: a host that is not a hostname is not a slug. Returning nil here is what
        // sends a hostile remote to `PRUnavailableReason.notGitHubRemote` — the same place a
        // `file://` remote goes — instead of into a `gh` argument, a notice, and a shell script.
        let lowered = hostAndPath.host.lowercased()
        guard Self.isValidHostname(lowered) else { return nil }

        self.host = lowered
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
    /// Remote name → owner login, for every remote this repo's branches actually track: `origin`
    /// from the slug, and one `config --get remote.<name>.url` per other name (codex round 2,
    /// MAJOR 4). `RepoLoader` already resolved these to key the PR match; carrying them on the
    /// repo is what lets the shell report which fork a row was counted against instead of
    /// reconstructing the answer from the PRs that happened to match. Empty for every caller
    /// that has nothing to say, and read with `decodeIfPresent` below (packet F12) so a cache
    /// written before the field existed loads with an empty map — the honest reading, since that
    /// refresh never ran the lookup — rather than costing the whole snapshot a cold rescan.
    /// Values became `RemoteIdentity` in codex round 3, MAJOR 4: a PR head is an (owner, branch)
    /// pair **on a host**, and storing the owner alone let a GitHub PR from `alice` attach to a
    /// branch tracking `gitlab.com/alice/product`.
    public var remoteOwners: [String: RemoteIdentity] = [:]
    /// `path` was verified to be an existing directory, without following a symlink, by the
    /// refresh that produced this repo (codex round 3, BLOCKER 1).
    ///
    /// False means the folder is gone, is a regular file, or is something this app will not open:
    /// the rows under it carry no primary action, because the last editor in the fallback chain is
    /// Terminal and Terminal *executes* a `.command` document. Read with `decodeIfPresent` below
    /// as true, which is what every refresh that wrote a cache before this field had established
    /// by walking to the folder in the first place; the check runs again on the next refresh, and
    /// the shell re-checks at click time.
    public var pathIsDirectory: Bool = true
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
        remoteOwners: [String: RemoteIdentity] = [:],
        pathIsDirectory: Bool = true,
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
        self.remoteOwners = remoteOwners
        self.pathIsDirectory = pathIsDirectory
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

    /// Explicit for the reason spelled out on `PRCacheEntry.init(from:)` (packet F12): a
    /// synthesized decoder ignores a stored property's default, so `remoteOwners` was a required
    /// key and every cached snapshot written before it failed to load. Frozen keys stay required.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(RepoID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        remoteURL = try container.decodeIfPresent(String.self, forKey: .remoteURL)
        githubSlug = try container.decodeIfPresent(GitHubSlug.self, forKey: .githubSlug)
        // A cache written before codex round 3 holds a bare login per remote; `RemoteIdentity`'s
        // own decoder reads that as an owner with no host, and the host it could only have meant
        // is origin's (MAJOR 4).
        let decodedOwners =
            try container.decodeIfPresent([String: RemoteIdentity].self, forKey: .remoteOwners) ?? [:]
        let originHost = githubSlug?.host ?? ""
        remoteOwners = decodedOwners.mapValues { identity in
            identity.host.isEmpty
                ? RemoteIdentity(host: originHost, owner: identity.owner)
                : identity
        }
        pathIsDirectory = try container.decodeIfPresent(Bool.self, forKey: .pathIsDirectory) ?? true
        worktrees = try container.decode([Worktree].self, forKey: .worktrees)
        branches = try container.decode([Branch].self, forKey: .branches)
        openPRsNotOnThisMac = try container.decode([PRInfo].self, forKey: .openPRsNotOnThisMac)
        prAvailability = try container.decode(PRAvailability.self, forKey: .prAvailability)
        prFetchedAt = try container.decodeIfPresent(Date.self, forKey: .prFetchedAt)
        prLoadState = try container.decode(PRLoadState.self, forKey: .prLoadState)
        lastRefreshed = try container.decodeIfPresent(Date.self, forKey: .lastRefreshed)
        errors = try container.decode([RepoError].self, forKey: .errors)
        isStale = try container.decode(Bool.self, forKey: .isStale)
        lastActivity = try container.decodeIfPresent(Date.self, forKey: .lastActivity)
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
