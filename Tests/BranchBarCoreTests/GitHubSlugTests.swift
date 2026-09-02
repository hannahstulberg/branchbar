import Foundation
import Testing

@testable import BranchBarCore

// Packet 1.1 owns `GitHubSlug.init?(remoteURL:)`. It is pure parsing over the string
// `git config --get remote.origin.url` prints, so it is unit-tested here with no seams.
// PLAN.md §5: "`GitHubSlug { host, owner, name; init?(remoteURL:) }` any host."

@Suite("GitHubSlug parses every remote URL shape git writes")
struct GitHubSlugTests {

    @Test("HTTPS remote with .git suffix")
    func httpsWithGitSuffix() throws {
        let slug = try #require(GitHubSlug(remoteURL: "https://github.com/hannahstulberg/branchbar.git"))
        #expect(slug.host == "github.com")
        #expect(slug.owner == "hannahstulberg")
        #expect(slug.name == "branchbar")
    }

    @Test("HTTPS remote without .git suffix")
    func httpsWithoutGitSuffix() throws {
        let slug = try #require(GitHubSlug(remoteURL: "https://github.com/hannahstulberg/branchbar"))
        #expect(slug.host == "github.com")
        #expect(slug.owner == "hannahstulberg")
        #expect(slug.name == "branchbar")
    }

    @Test("HTTPS remote with a trailing slash")
    func httpsWithTrailingSlash() throws {
        let slug = try #require(GitHubSlug(remoteURL: "https://github.com/hannahstulberg/branchbar/"))
        #expect(slug.name == "branchbar")
    }

    @Test("HTTPS remote with a trailing slash after .git")
    func httpsWithTrailingSlashAfterGit() throws {
        let slug = try #require(GitHubSlug(remoteURL: "https://github.com/hannahstulberg/branchbar.git/"))
        #expect(slug.name == "branchbar")
    }

    @Test("scp-like remote git@host:owner/name.git")
    func scpLikeRemote() throws {
        let slug = try #require(GitHubSlug(remoteURL: "git@github.com:hannahstulberg/branchbar.git"))
        #expect(slug.host == "github.com")
        #expect(slug.owner == "hannahstulberg")
        #expect(slug.name == "branchbar")
    }

    @Test("scp-like remote with no user part")
    func scpLikeRemoteWithoutUser() throws {
        let slug = try #require(GitHubSlug(remoteURL: "github.com:hannahstulberg/branchbar"))
        #expect(slug.host == "github.com")
        #expect(slug.owner == "hannahstulberg")
        #expect(slug.name == "branchbar")
    }

    @Test("ssh:// remote")
    func sshSchemeRemote() throws {
        let slug = try #require(GitHubSlug(remoteURL: "ssh://git@github.com/hannahstulberg/branchbar.git"))
        #expect(slug.host == "github.com")
        #expect(slug.owner == "hannahstulberg")
        #expect(slug.name == "branchbar")
    }

    @Test("ssh:// remote with an explicit port drops the port from the host")
    func sshSchemeRemoteWithPort() throws {
        let slug = try #require(GitHubSlug(remoteURL: "ssh://git@github.com:22/hannahstulberg/branchbar.git"))
        #expect(slug.host == "github.com")
        #expect(slug.owner == "hannahstulberg")
        #expect(slug.name == "branchbar")
    }

    @Test("git:// remote")
    func gitSchemeRemote() throws {
        let slug = try #require(GitHubSlug(remoteURL: "git://github.com/hannahstulberg/branchbar.git"))
        #expect(slug.host == "github.com")
        #expect(slug.name == "branchbar")
    }

    // PLAN.md §2: "NYT git host: github.com most likely; GHE not ruled out"; §5 says any host.
    @Test("GitHub Enterprise host is preserved, not rewritten to github.com")
    func enterpriseHostIsPreserved() throws {
        let https = try #require(GitHubSlug(remoteURL: "https://github.nytimes.com/newsroom/tooling.git"))
        #expect(https.host == "github.nytimes.com")
        #expect(https.owner == "newsroom")
        #expect(https.name == "tooling")

        let ssh = try #require(GitHubSlug(remoteURL: "git@github.nytimes.com:newsroom/tooling.git"))
        #expect(ssh.host == "github.nytimes.com")
        #expect(ssh.owner == "newsroom")
        #expect(ssh.name == "tooling")
    }

    @Test("Credentials embedded in the URL never leak into the host")
    func userInfoIsStripped() throws {
        let slug = try #require(GitHubSlug(remoteURL: "https://hannahstulberg:ghp_notarealtoken@github.com/hannahstulberg/branchbar.git"))
        #expect(slug.host == "github.com")
        #expect(slug.owner == "hannahstulberg")
        #expect(slug.name == "branchbar")
    }

    @Test("Host case is normalized to lower case; owner and name keep their case")
    func hostIsLowercasedOwnerAndNameAreNot() throws {
        let slug = try #require(GitHubSlug(remoteURL: "https://GitHub.COM/HannahStulberg/BranchBar.git"))
        #expect(slug.host == "github.com")
        #expect(slug.owner == "HannahStulberg")
        #expect(slug.name == "BranchBar")
    }

    @Test("A deeper path uses the last two components as owner and name")
    func deeperPathUsesLastTwoComponents() throws {
        let slug = try #require(GitHubSlug(remoteURL: "ssh://git@github.nytimes.com/v3/newsroom/tooling.git"))
        #expect(slug.host == "github.nytimes.com")
        #expect(slug.owner == "newsroom")
        #expect(slug.name == "tooling")
    }

    @Test("Surrounding whitespace from a config read is tolerated")
    func trailingNewlineIsTolerated() throws {
        let slug = try #require(GitHubSlug(remoteURL: "  https://github.com/hannahstulberg/branchbar.git\n"))
        #expect(slug.name == "branchbar")
    }

    @Test("The slug renders as host/owner/name for gh --repo")
    func ghRepoArgumentShape() throws {
        let slug = try #require(GitHubSlug(remoteURL: "https://github.com/hannahstulberg/branchbar.git"))
        #expect(slug.ghRepoArgument == "github.com/hannahstulberg/branchbar")
    }

    @Test("Remotes that are not a host plus owner plus name return nil", arguments: [
        "",
        "   ",
        "not a url at all",
        "https://github.com/hannahstulberg",
        "https://github.com/",
        "https://github.com",
        "/Users/hannahstulberg/some/local/repo.git",
        "file:///Users/hannahstulberg/some/local/repo.git",
        "../relative/repo.git",
        "git@github.com:",
        "git@github.com:onlyowner",
    ])
    func rejectsNonSlugRemotes(_ remote: String) {
        #expect(GitHubSlug(remoteURL: remote) == nil, "\(remote) should not parse as a slug")
    }
}
