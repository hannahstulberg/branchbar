import Foundation

/// What one refresh actually established about a remote fact, as opposed to what it guessed
/// (codex round 3, MAJOR 6).
///
/// `git config --get remote.origin.url` exiting non-zero and the key being unset both left
/// `remoteURL == nil`, and the copy read that as "No origin for this repo" — a claim only the
/// second of the two supports. The same collapse behind `for-each-ref -- refs/remotes/`: a failed
/// listing produced no tip, the deriver selected `.none`, and the row said "No tracked remote
/// branch" over a tertiary line that said the branch was in sync with it.
///
/// Three states, and the middle one is the only one absence copy may follow:
///
/// - `known` — the query ran and returned a value.
/// - `absent` — the query ran and proved there is nothing there (git exit 1 with no output for an
///   unset key; an empty but successful ref listing).
/// - `failed` — the query did not run or did not answer. Nothing is known, and nothing is claimed.
public enum RemoteFactState: String, Hashable, Codable, Sendable, CaseIterable {
    case known
    case absent
    case failed
}

/// The two remote reads one repo's row depends on, carried together so `RepoAssembler` and
/// `PushInfoDeriver` never have to infer "we asked and there is nothing" from "we have nothing".
public struct RemoteFacts: Hashable, Codable, Sendable {
    /// `git config --get remote.origin.url`.
    public var originURL: RemoteFactState
    /// `git for-each-ref -- refs/remotes/`.
    public var remoteRefs: RemoteFactState

    public init(originURL: RemoteFactState = .known, remoteRefs: RemoteFactState = .known) {
        self.originURL = originURL
        self.remoteRefs = remoteRefs
    }

    /// Explicit for the reason spelled out on `PRCacheEntry.init(from:)` (packet F12): a
    /// synthesized decoder ignores a stored property's default, so a value written before either
    /// key existed would fail to load rather than read as "this refresh recorded nothing".
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        originURL = try container.decodeIfPresent(RemoteFactState.self, forKey: .originURL) ?? .known
        remoteRefs = try container.decodeIfPresent(RemoteFactState.self, forKey: .remoteRefs) ?? .known
    }
}

/// Who a remote belongs to, on which host (codex round 3, MAJOR 4).
///
/// A PR head is an (owner, branch) pair *on a host*. `Repo.remoteOwners` stored the owner alone,
/// so a branch tracking `gitlab.com/alice/product` inside a clone of `github.com/nyt/product`
/// matched a GitHub PR whose head was `alice:<same name>` — a different head on a different
/// service that happens to share two strings. Different GitHub Enterprise installations have the
/// same collision.
///
/// `host` is the lower-cased hostname `GitHubSlug` already validated; it is empty exactly when it
/// came from a value written before this type existed, and `Repo.init(from:)` fills that in from
/// origin's own host, which is what the old single-string encoding implied.
public struct RemoteIdentity: Hashable, Codable, Sendable {
    public var host: String
    public var owner: String

    public init(host: String, owner: String) {
        self.host = host
        self.owner = owner
    }

    /// Both halves folded for comparison, never for display. GitHub logins are case-insensitive
    /// and so are hostnames; `owner` and `host` keep the casing a `--repo` operand and a PR link
    /// are built from (the same rule as `GitHubSlug.ownerKey`).
    public var ownerKey: String { owner.lowercased() }
    public var hostKey: String { host.lowercased() }

    /// The two remotes name the same repository owner on the same service.
    public func matchesHost(_ other: String?) -> Bool {
        guard let other, !other.isEmpty else { return false }
        return hostKey == other.lowercased()
    }

    /// Lenient the same way every post-freeze decoder in this package is (packet F12): a cache
    /// written when `remoteOwners` was `[String: String]` holds a bare login, which decodes as the
    /// owner with no host. `Repo.init(from:)` then fills the host from origin's, because a
    /// single-string entry could only ever have meant "origin's service".
    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let owner = try? single.decode(String.self) {
            self.host = ""
            self.owner = owner
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        owner = try container.decode(String.self, forKey: .owner)
    }
}
