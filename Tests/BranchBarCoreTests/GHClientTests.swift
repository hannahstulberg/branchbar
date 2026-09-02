import Foundation
import Testing

@testable import BranchBarCore

// Acceptance tests for packet 2.3, written before the implementation (PLAN.md §3, §7) from
// PLAN.md §5's frozen invocations, the OWNER comments on `GHClient`, and docs/TEST-PLAN.md.
//
// Every test drives the actor through `RecordedCommandRunner`, which matches on the executable's
// basename plus the exact argument array and records an Issue for anything it was not told about.
// That double-checks the frozen invocations: a `gh pr list` whose flags drift by one character is
// unstubbed, and an unstubbed command fails the test by itself.
//
// API this packet's implementer must provide beyond the stub file, and nothing else:
//
//     public func pullRequests(slug: GitHubSlug, unmatchedHeads: [String]) async -> [String: [PRInfo]]
//
// the capped per-head fallback. The single-head `pullRequests(slug:head:)` stays uncapped — its
// OWNER comment says the cap belongs to the caller — and this batch entry point is the caller
// `RepoLoader` (packet 3.1) uses: it queries at most `policy.perHeadFallbackCap` heads, in the
// order given, and returns one entry per head it actually queried. A head that was queried and
// has no PR maps to an empty array; a head past the cap is absent from the dictionary, which is
// exactly the `none` versus `notChecked` distinction `RepoAssembler` renders
// (`unqueriedBranchIsNotCheckedNeverNone`).

// MARK: - The frozen gh invocations (PLAN.md §5)

private enum GH {
    /// A Homebrew path on purpose: `RecordedCommandRunner` matches on the basename, and PLAN.md §2
    /// says the GUI PATH cannot see this directory, so `ToolLocator` is what resolved it.
    static let path = "/opt/homebrew/bin/gh"

    static var fields: String { GHClient.jsonFields }

    static func authArguments(host: String) -> [String] {
        ["auth", "status", "--hostname", host]
    }

    static func recentArguments(_ slug: GitHubSlug) -> [String] {
        ["pr", "list", "--repo", slug.ghRepoArgument, "--state", "all", "--limit", "100", "--json", fields]
    }

    static func headArguments(_ slug: GitHubSlug, head: String) -> [String] {
        ["pr", "list", "--repo", slug.ghRepoArgument, "--state", "all", "--head", head, "--limit", "5", "--json", fields]
    }

    static func authorArguments(_ slug: GitHubSlug) -> [String] {
        ["pr", "list", "--repo", slug.ghRepoArgument, "--state", "open", "--author", "@me", "--limit", "100", "--json", fields]
    }

    static let personalAgent = GitHubSlug(host: "github.com", owner: "hannahstulberg", name: "hannah-personal-agent")
    static let branchbar = GitHubSlug(host: "github.com", owner: "hannahstulberg", name: "branchbar")

    /// Stubs the successful `gh auth status` every list invocation preflights.
    static func stubAuthSuccess(_ runner: RecordedCommandRunner, host: String = "github.com") {
        runner.stub(.init(
            executableName: "gh",
            arguments: authArguments(host: host),
            result: .stdout(Fixture.text("recorded-gh-auth-status-github.com.txt"))
        ))
    }
}

private func reason(_ availability: PRAvailability) -> PRUnavailableReason? {
    guard case .unavailable(let reason, _) = availability else { return nil }
    return reason
}

private func detail(_ availability: PRAvailability) -> String? {
    guard case .unavailable(_, let detail) = availability else { return nil }
    return detail
}

private func failure(_ result: Result<[PRInfo], PRAvailability>) -> PRAvailability? {
    guard case .failure(let availability) = result else { return nil }
    return availability
}

private func value(_ result: Result<[PRInfo], PRAvailability>) -> [PRInfo]? {
    guard case .success(let prs) = result else { return nil }
    return prs
}

// MARK: - Per-host auth preflight

@Suite("GHClient runs one auth preflight per host and lets its answer govern every repo there")
struct GHClientAuthTests {

    /// PLAN.md §3: "`gh auth status --hostname <host>` once per distinct host per refresh".
    @Test("authStatusRunsOncePerHostAndMemoizesTheAnswer")
    func authStatusRunsOncePerHostAndMemoizesTheAnswer() async throws {
        let runner = RecordedCommandRunner()
        GH.stubAuthSuccess(runner)
        let client = GHClient(runner: runner, ghPath: GH.path)

        let first = await client.authStatus(host: "github.com")
        let second = await client.authStatus(host: "github.com")

        #expect(first == .available)
        #expect(second == .available)
        #expect(runner.calls(matchingExecutable: "gh").count == 1,
                "the second ask is answered from the memoized preflight, not a second gh call")
    }

    /// PLAN.md §3: an auth failure short-circuits `gh pr list` for **every** repo on that host.
    /// The two slugs below share a host, so the second must cost no gh call at all — and any
    /// `pr list` that slips through is unstubbed, which fails this test on its own.
    @Test("authStatusFailureShortCircuitsPRListForAllReposOnThatHost")
    func authStatusFailureShortCircuitsPRListForAllReposOnThatHost() async throws {
        let runner = RecordedCommandRunner()
        runner.stub(.init(
            executableName: "gh",
            arguments: GH.authArguments(host: "github.com"),
            result: .exit(1, stderr: Fixture.text("synthetic-gh-auth-status-401.txt"))
        ))
        let client = GHClient(runner: runner, ghPath: GH.path)

        let first = try #require(failure(await client.recentPullRequests(slug: GH.personalAgent)))
        let second = try #require(failure(await client.recentPullRequests(slug: GH.branchbar)))
        let authored = try #require(failure(await client.openAuthoredPullRequests(slug: GH.branchbar)))

        #expect(reason(first) == .ghNotAuthenticated(host: "github.com"))
        #expect(reason(second) == .ghNotAuthenticated(host: "github.com"))
        #expect(reason(authored) == .ghNotAuthenticated(host: "github.com"))
        #expect(detail(first)?.contains("HTTP 401: Bad credentials") == true,
                "the stderr rides along as the diagnostic; packet 4.0 owns the copy")
        #expect(runner.calls(matchingExecutable: "gh").count == 1,
                "one preflight for the host, and no pr list for any repo on it")
    }

    /// PLAN.md §2 does not rule out GitHub Enterprise at NYT. The slug half of this invariant is
    /// already green in `GitHubSlugTests`; this is the preflight half: the host the remote names
    /// is the host `--hostname` and `--repo` carry, and a second host preflights separately.
    @Test("enterpriseHostRemoteResolvesSlugAndAuthPreflightPerHost")
    func enterpriseHostRemoteResolvesSlugAndAuthPreflightPerHost() async throws {
        let enterprise = try #require(GitHubSlug(remoteURL: Fixture.text("synthetic-config-remote-origin-url-ghe.txt")))
        #expect(enterprise.host == "github.nytimes.com")

        let runner = RecordedCommandRunner()
        GH.stubAuthSuccess(runner, host: "github.nytimes.com")
        GH.stubAuthSuccess(runner, host: "github.com")
        runner.stubGH(GH.recentArguments(enterprise), stdout: Fixture.text("synthetic-gh-pr-list-empty.json"))
        runner.stubGH(GH.recentArguments(GH.branchbar), stdout: Fixture.text("synthetic-gh-pr-list-empty.json"))

        let client = GHClient(runner: runner, ghPath: GH.path)
        _ = await client.recentPullRequests(slug: enterprise)
        _ = await client.recentPullRequests(slug: GH.branchbar)

        let authCalls = runner.calls(matchingExecutable: "gh").filter { $0.arguments.first == "auth" }
        #expect(authCalls.contains { $0.arguments == GH.authArguments(host: "github.nytimes.com") })
        #expect(authCalls.contains { $0.arguments == GH.authArguments(host: "github.com") })

        let listCalls = runner.calls(matchingExecutable: "gh").filter { $0.arguments.first == "pr" }
        #expect(listCalls.contains { $0.arguments.contains("github.nytimes.com/newsroom/interactive-tooling") },
                "the --repo operand is host/owner/name, host included")
    }

    /// The launch failure a GUI-launched process gets when `gh` is not on its PATH
    /// (`synthetic-gh-not-found.txt`). It has to become `ghNotInstalled` — a reason with one
    /// action — and never a thrown error that blanks the repo.
    @Test("ghMissingMakesEveryBranchUnavailableWithoutThrowing")
    func ghMissingMakesEveryBranchUnavailableWithoutThrowing() async throws {
        let notFound = Fixture.text("synthetic-gh-not-found.txt")
        let runner = RecordedCommandRunner()
        runner.stub(.init(
            executableName: "gh",
            arguments: GH.authArguments(host: "github.com"),
            result: .failure(.launchFailed(executable: GH.path, message: notFound))
        ))
        let client = GHClient(runner: runner, ghPath: GH.path)

        let status = await client.authStatus(host: "github.com")
        #expect(reason(status) == .ghNotInstalled)

        // Every entry point answers with the same availability rather than throwing, so a repo
        // renders "gh is not installed" on every branch instead of disappearing.
        let recent = try #require(failure(await client.recentPullRequests(slug: GH.personalAgent)))
        let head = try #require(failure(await client.pullRequests(slug: GH.personalAgent, head: "main")))
        let authored = try #require(failure(await client.openAuthoredPullRequests(slug: GH.personalAgent)))
        #expect(reason(recent) == .ghNotInstalled)
        #expect(reason(head) == .ghNotInstalled)
        #expect(reason(authored) == .ghNotInstalled)

        let classified = GHClient.availability(
            forFailedCommand: .launchFailed(executable: GH.path, message: notFound),
            host: "github.com"
        )
        #expect(reason(classified) == .ghNotInstalled)
        #expect(detail(classified)?.isEmpty == false, "the launch message is the diagnostic")
    }
}

// MARK: - The three list invocations and their failure mapping

@Suite("GHClient issues the frozen pr list invocations and maps their failures by reason")
struct GHClientListTests {

    @Test("recentPullRequestsIssuesTheFrozenListInvocationAndDecodesIt")
    func recentPullRequestsIssuesTheFrozenListInvocationAndDecodesIt() async throws {
        let runner = RecordedCommandRunner()
        GH.stubAuthSuccess(runner)
        runner.stubGH(GH.recentArguments(GH.personalAgent),
                      stdout: Fixture.text("synthetic-gh-pr-list-mixed.json"))
        let client = GHClient(runner: runner, ghPath: GH.path)

        let prs = try #require(value(await client.recentPullRequests(slug: GH.personalAgent)))
        #expect(prs.count == 10)
        #expect(prs.first?.number == 110, "the client hands back what PRListDecoder sorted: newest updatedAt first")
        #expect(prs.contains { $0.headRepositoryOwnerLogin == "contributor" },
                "forkOriginatedPRStillMatchesItsLocalBranch: the client drops no fork PR before the join")

        let listCall = try #require(runner.calls(matchingExecutable: "gh").first { $0.arguments.first == "pr" })
        #expect(listCall.arguments == GH.recentArguments(GH.personalAgent))
    }

    /// PLAN.md §3: a branch with no match in the 100 most recent PRs gets its own `--head` query.
    /// The recorded fixture is that query answering with the one older PR the list missed.
    @Test("branchWithAnOlderPRStillResolvesItsPRStatusViaHeadQuery")
    func branchWithAnOlderPRStillResolvesItsPRStatusViaHeadQuery() async throws {
        let head = "allison-bachelorette-itinerary-pdf"
        let runner = RecordedCommandRunner()
        GH.stubAuthSuccess(runner)
        runner.stubGH(GH.recentArguments(GH.personalAgent),
                      stdout: Fixture.text("synthetic-gh-pr-list-empty.json"))
        runner.stubGH(GH.headArguments(GH.personalAgent, head: head),
                      stdout: Fixture.text("recorded-gh-pr-list-head-hannah-personal-agent.json"))
        let client = GHClient(runner: runner, ghPath: GH.path)

        let recent = try #require(value(await client.recentPullRequests(slug: GH.personalAgent)))
        #expect(recent.isEmpty, "the recent list matched nothing, which is what sends this branch to the fallback")

        let fallback = try #require(value(await client.pullRequests(slug: GH.personalAgent, head: head)))
        let pr = try #require(fallback.first)
        #expect(fallback.count == 1)
        #expect(pr.number == 17)
        #expect(pr.state == "MERGED")
        #expect(pr.headRefName == head)
        #expect(pr.mergedAt != nil)

        let headCall = try #require(runner.calls(matchingExecutable: "gh").last)
        #expect(headCall.arguments == GH.headArguments(GH.personalAgent, head: head),
                "--head <branch> --limit 5, exactly as PLAN.md §5 froze it")
    }

    @Test("openAuthoredPullRequestsAcceptsAnEmptyArrayAsAnAnswer")
    func openAuthoredPullRequestsAcceptsAnEmptyArrayAsAnAnswer() async throws {
        let runner = RecordedCommandRunner()
        GH.stubAuthSuccess(runner)
        runner.stubGH(GH.authorArguments(GH.personalAgent),
                      stdout: Fixture.text("recorded-gh-pr-list-author-me-hannah-personal-agent.json"))
        runner.stubGH(GH.authorArguments(GH.branchbar),
                      stdout: Fixture.text("synthetic-gh-pr-list-mixed.json"))
        let client = GHClient(runner: runner, ghPath: GH.path)

        let empty = try #require(value(await client.openAuthoredPullRequests(slug: GH.personalAgent)))
        #expect(empty.isEmpty, "an author with no open PRs is an answer, not a failure")

        let populated = try #require(value(await client.openAuthoredPullRequests(slug: GH.branchbar)))
        #expect(populated.count == 10)
    }

    /// `rateLimitResponseMapsToRateLimitedNotCommandFailed` — the copy for `rateLimited` says
    /// waiting fixes it, and `commandFailed` says nothing useful about a 403.
    @Test("rateLimitResponseMapsToRateLimitedNotCommandFailed")
    func rateLimitResponseMapsToRateLimitedNotCommandFailed() async throws {
        let stderr = Fixture.text("synthetic-gh-rate-limit-403.txt")
        let runner = RecordedCommandRunner()
        GH.stubAuthSuccess(runner)
        runner.stub(.init(
            executableName: "gh",
            arguments: GH.recentArguments(GH.personalAgent),
            result: .exit(1, stderr: stderr)
        ))
        let client = GHClient(runner: runner, ghPath: GH.path)

        let limited = try #require(failure(await client.recentPullRequests(slug: GH.personalAgent)))
        #expect(reason(limited) == .rateLimited)
        #expect(detail(limited)?.contains("rate limit") == true)

        #expect(reason(GHClient.availability(
            forFailedCommand: .nonZeroExit(exitCode: 1, standardError: stderr),
            host: "github.com")) == .rateLimited)
        #expect(reason(GHClient.availability(
            forFailedCommand: .nonZeroExit(exitCode: 1, standardError: "HTTP 429: Too Many Requests"),
            host: "github.com")) == .rateLimited)
    }

    /// Anything the reason list does not name is `commandFailed` carrying the first stderr line,
    /// so the log has the diagnostic and the row still renders.
    @Test("otherFailuresAreCommandFailedCarryingTheFirstStderrLine")
    func otherFailuresAreCommandFailedCarryingTheFirstStderrLine() async throws {
        let stderr = "could not resolve to a Repository with the name 'hannahstulberg/gone'.\nsecond line\n"
        let runner = RecordedCommandRunner()
        GH.stubAuthSuccess(runner)
        runner.stub(.init(
            executableName: "gh",
            arguments: GH.recentArguments(GH.personalAgent),
            result: .exit(1, stderr: stderr)
        ))
        let client = GHClient(runner: runner, ghPath: GH.path)

        let failed = try #require(failure(await client.recentPullRequests(slug: GH.personalAgent)))
        #expect(reason(failed) == .commandFailed)
        let carried = try #require(detail(failed))
        #expect(carried.contains("could not resolve to a Repository"))
        #expect(!carried.contains("second line"), "the first stderr line is the diagnostic")
    }

    /// A truncated JSON stream is a failed read of PR status, not an empty repo: an empty list
    /// would render every branch as "no PR", which is a lie.
    @Test("malformedJSONIsCommandFailed")
    func malformedJSONIsCommandFailed() async throws {
        let runner = RecordedCommandRunner()
        GH.stubAuthSuccess(runner)
        runner.stubGH(GH.recentArguments(GH.personalAgent),
                      stdout: Fixture.text("synthetic-gh-pr-list-malformed.json"))
        let client = GHClient(runner: runner, ghPath: GH.path)

        let failed = try #require(failure(await client.recentPullRequests(slug: GH.personalAgent)))
        #expect(reason(failed) == .commandFailed)
        #expect(detail(failed)?.isEmpty == false, "the decode error is the diagnostic")
    }

    /// PLAN.md §5: the gh environment and the per-invocation timeouts are frozen. A GUI-launched
    /// `gh` that prompts, pages, or colorizes hangs or garbles the output on someone else's Mac.
    @Test("ghEnvIsFrozenOnEveryInvocation")
    func ghEnvIsFrozenOnEveryInvocation() async throws {
        let runner = RecordedCommandRunner()
        GH.stubAuthSuccess(runner)
        runner.stubGH(GH.recentArguments(GH.personalAgent),
                      stdout: Fixture.text("synthetic-gh-pr-list-mixed.json"))
        runner.stubGH(GH.headArguments(GH.personalAgent, head: "main"),
                      stdout: Fixture.text("synthetic-gh-pr-list-empty.json"))
        runner.stubGH(GH.authorArguments(GH.personalAgent),
                      stdout: Fixture.text("recorded-gh-pr-list-author-me-hannah-personal-agent.json"))
        let policy = RefreshPolicy.default
        let client = GHClient(runner: runner, ghPath: GH.path, policy: policy)

        _ = await client.authStatus(host: "github.com")
        _ = await client.recentPullRequests(slug: GH.personalAgent)
        _ = await client.pullRequests(slug: GH.personalAgent, head: "main")
        _ = await client.openAuthoredPullRequests(slug: GH.personalAgent)

        let calls = runner.calls(matchingExecutable: "gh")
        #expect(calls.count == 4)
        for call in calls {
            #expect(call.executable == GH.path, "the path ToolLocator resolved, never a bare `gh`")
            #expect(call.environment == GHClient.frozenEnvironment,
                    "\(call.displayString) ran with \(String(describing: call.environment))")
        }

        let auth = try #require(calls.first { $0.arguments.first == "auth" })
        #expect(auth.timeout == policy.ghAuthTimeout)
        for list in calls.filter({ $0.arguments.first == "pr" }) {
            #expect(list.timeout == policy.ghListTimeout)
            #expect(list.arguments.contains("--json"))
            #expect(list.arguments.last == GHClient.jsonFields)
        }
    }
}

// MARK: - Per-head fallback cap, notChecked, and the PR cache

@Suite("GHClient caps the per-head fallback and serves a warm cache without calling gh")
struct GHClientFallbackAndCacheTests {

    /// PLAN.md §3: at most 20 per-head queries per repo per refresh. Twenty-five branches missed
    /// the recent list; twenty are queried and five are not, which is what keeps a busy repo
    /// inside the 45 s deadline.
    @Test("perHeadFallbackRespectsPerRepoCap")
    func perHeadFallbackRespectsPerRepoCap() async throws {
        let policy = RefreshPolicy.default
        let heads = (1...25).map { "feature-\($0)" }

        let runner = RecordedCommandRunner()
        GH.stubAuthSuccess(runner)
        for head in heads {
            runner.stubGH(GH.headArguments(GH.personalAgent, head: head),
                          stdout: Fixture.text("synthetic-gh-pr-list-empty.json"))
        }
        let client = GHClient(runner: runner, ghPath: GH.path, policy: policy)

        let queried = await client.pullRequests(slug: GH.personalAgent, unmatchedHeads: heads)

        let headCalls = runner.calls(matchingExecutable: "gh").filter { $0.arguments.contains("--head") }
        #expect(policy.perHeadFallbackCap == 20)
        #expect(headCalls.count == policy.perHeadFallbackCap,
                "one gh call per queried head, and the cap is the ceiling")
        #expect(Set(queried.keys) == Set(heads.prefix(policy.perHeadFallbackCap)),
                "the cap takes the heads in the order it was given them")
        #expect(queried["feature-25"] == nil, "the remainder was never queried")
    }

    /// The distinction a review finding put in `PRStatus`: `none` means asked and answered
    /// nothing; `notChecked` means never asked. `GHClient` reports which heads it queried, and a
    /// head it skipped is absent — never an empty answer that would render as "no PR".
    @Test("unqueriedBranchIsNotCheckedNeverNone")
    func unqueriedBranchIsNotCheckedNeverNone() async throws {
        let policy = RefreshPolicy(perHeadFallbackCap: 2)
        let heads = ["queried-with-a-pr", "queried-and-empty", "never-queried"]

        let runner = RecordedCommandRunner()
        GH.stubAuthSuccess(runner)
        runner.stubGH(GH.headArguments(GH.personalAgent, head: "queried-with-a-pr"),
                      stdout: Fixture.text("recorded-gh-pr-list-head-hannah-personal-agent.json"))
        runner.stubGH(GH.headArguments(GH.personalAgent, head: "queried-and-empty"),
                      stdout: Fixture.text("synthetic-gh-pr-list-empty.json"))
        runner.stubGH(GH.headArguments(GH.personalAgent, head: "never-queried"),
                      stdout: Fixture.text("synthetic-gh-pr-list-empty.json"))
        let client = GHClient(runner: runner, ghPath: GH.path, policy: policy)

        let queried = await client.pullRequests(slug: GH.personalAgent, unmatchedHeads: heads)

        #expect(queried["queried-with-a-pr"]?.count == 1)
        #expect(queried["queried-and-empty"]?.isEmpty == true,
                "queried and empty is an entry with no PRs, which RepoAssembler renders as none")
        #expect(queried.keys.contains("never-queried") == false,
                "past the cap it is absent, which RepoAssembler renders as notChecked")
        #expect(runner.calls(matchingExecutable: "gh").filter { $0.arguments.contains("--head") }.count == 2)
    }

    /// PLAN.md §3: PR results are cached per repo, TTL 10 minutes, "for latency, not quota".
    /// Inside the TTL the actor answers from what it already fetched and issues no gh call; a
    /// different repo is a different cache entry and pays for its own call.
    @Test("prCacheWithinTTLIssuesNoGhCalls")
    func prCacheWithinTTLIssuesNoGhCalls() async throws {
        let runner = RecordedCommandRunner()
        GH.stubAuthSuccess(runner)
        runner.stubGH(GH.recentArguments(GH.personalAgent),
                      stdout: Fixture.text("synthetic-gh-pr-list-mixed.json"))
        runner.stubGH(GH.recentArguments(GH.branchbar),
                      stdout: Fixture.text("synthetic-gh-pr-list-empty.json"))
        let client = GHClient(runner: runner, ghPath: GH.path, policy: RefreshPolicy.default)

        let first = try #require(value(await client.recentPullRequests(slug: GH.personalAgent)))
        let second = try #require(value(await client.recentPullRequests(slug: GH.personalAgent)))

        #expect(first == second, "the cached entry is the same answer, not a re-fetch")
        #expect(runner.calls(matchingExecutable: "gh").filter { $0.arguments.first == "pr" }.count == 1,
                "the second call inside the 600 s TTL issues no gh call")

        _ = await client.recentPullRequests(slug: GH.branchbar)
        #expect(runner.calls(matchingExecutable: "gh").filter { $0.arguments.first == "pr" }.count == 2,
                "the cache is per repo; a second repo still runs its own list")
    }
}
