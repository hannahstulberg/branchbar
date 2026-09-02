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

    /// The bare `gh auth status` (no `--hostname`) whose host lines say which hosts `gh` holds a
    /// login for — the allow-list codex round 2 MAJOR 6 requires before any host but `github.com`
    /// is treated as GitHub.
    static let loggedInHostsArguments = ["auth", "status"]

    static func stubLoggedInHosts(_ runner: RecordedCommandRunner, hosts: [String]) {
        let body = hosts
            .map { "\($0)\n  ✓ Logged in to \($0) account tester (keyring)\n  - Active account: true\n" }
            .joined(separator: "\n")
        runner.stub(.init(executableName: "gh", arguments: loggedInHostsArguments, result: .stdout(body)))
    }

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
        // codex round 2, MAJOR 6: an enterprise host is a GitHub host because `gh auth status`
        // says it holds a login for it, so the allow-list read comes first.
        GH.stubLoggedInHosts(runner, hosts: ["github.com", "github.nytimes.com"])
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

// MARK: - Packet F3 — failure classification, one preflight per host, and per-refresh caches

/// A `CommandRunner` that answers a scripted sequence, so a test can make the same invocation
/// fail once and then succeed. `RecordedCommandRunner` matches a stub table and always returns
/// the same answer for the same argument array, which cannot express "the first attempt was
/// cancelled".
private final class ScriptedRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [String: [RecordedCommandRunner.StubResult]] = [:]
    private var _calls: [Command] = []
    /// Held before answering, so overlapping callers really do overlap.
    var delay: TimeInterval = 0

    var calls: [Command] { lock.lock(); defer { lock.unlock() }; return _calls }

    func script(_ arguments: [String], _ results: [RecordedCommandRunner.StubResult]) {
        lock.lock(); defer { lock.unlock() }
        scripted[arguments.joined(separator: "\u{1}")] = results
    }

    func run(_ command: Command) async throws -> CommandOutput {
        let key = command.arguments.joined(separator: "\u{1}")
        let result: RecordedCommandRunner.StubResult? = lock.withLock {
            _calls.append(command)
            guard var queue = scripted[key], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            // The last scripted answer repeats, so a caller that runs one extra time is not a
            // crash but an observable extra call.
            if !queue.isEmpty { scripted[key] = queue }
            return next
        }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }

        guard let result else {
            Issue.record("unscripted command: \(command.displayString)")
            throw CommandError.launchFailed(executable: command.executable, message: "unscripted")
        }
        switch result {
        case .output(let output): return output
        case .failure(let error): throw error
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}

@Suite("GHClient classifies 403 honestly, preflights a host once, and can be reset per refresh")
struct GHClientHardeningTests {

    /// codex MAJOR 11. SAML enforcement, a missing `repo` scope, an IP allow-list denial and a
    /// repository policy are all HTTP 403, and `rateLimited`'s copy says waiting a few minutes
    /// fixes it — false for every one of them, and most misleading on exactly the managed
    /// account this ships to. Only an explicit rate-limit message or a 429 is rate limiting.
    @Test("plain403IsNotRateLimited")
    func plain403IsNotRateLimited() async throws {
        let saml = "HTTP 403: Resource protected by organization SAML enforcement. "
            + "You must grant your OAuth token access to this organization (https://api.github.com/graphql)\n"
            + "trailing diagnostic line\n"
        let availability = GHClient.availability(
            forFailedCommand: .nonZeroExit(exitCode: 1, standardError: saml), host: "github.com")

        // Was `ghNotAuthenticated` until codex round 2 MAJOR 7: SAML, an IP allow-list and an
        // organization policy are not credential problems, and the one action that reason offers
        // is `gh auth login`, which cannot lift any of them.
        #expect(reason(availability) == .forbidden(repo: "github.com"))
        #expect(detail(availability)?.hasPrefix("HTTP 403: Resource protected") == true)
        #expect(detail(availability)?.contains("trailing diagnostic line") == false,
                "the first stderr line is the diagnostic")

        // The scope failure and the plain forbidden body take the same path.
        #expect(reason(GHClient.availability(
            forFailedCommand: .nonZeroExit(
                exitCode: 1,
                standardError: "HTTP 403: Must have admin rights to Repository. (https://api.github.com/graphql)"),
            host: "github.com",
            repo: "github.com/tester/demo")) == .forbidden(repo: "github.com/tester/demo"))

        // And the real rate limit still is one, message or status code.
        #expect(reason(GHClient.availability(
            forFailedCommand: .nonZeroExit(exitCode: 1, standardError: Fixture.text("synthetic-gh-rate-limit-403.txt")),
            host: "github.com")) == .rateLimited)
        #expect(reason(GHClient.availability(
            forFailedCommand: .nonZeroExit(exitCode: 1, standardError: "You have exceeded a secondary RATE LIMIT."),
            host: "github.com")) == .rateLimited)
    }

    /// codex round 2, MAJOR 7. Only evidence about the credential maps to "not signed in": a 401,
    /// a "Bad credentials" body, or `gh`'s own "not logged in". Every other 403 — SAML, an IP
    /// allow-list, an organization policy, a missing grant on a repo the account can otherwise
    /// see — is a refusal that signing in again does not lift, and telling the user to sign in
    /// again sent them round a loop that could not end.
    @Test("only401OrBadCredentialsMapsToGhNotAuthenticated")
    func only401OrBadCredentialsMapsToGhNotAuthenticated() async throws {
        let unauthorized = GHClient.availability(
            forFailedCommand: .nonZeroExit(exitCode: 1, standardError: "HTTP 401: Bad credentials (https://api.github.com/graphql)"),
            host: "github.com")
        #expect(reason(unauthorized) == .ghNotAuthenticated(host: "github.com"))

        let notLoggedIn = GHClient.availability(
            forFailedCommand: .nonZeroExit(exitCode: 1, standardError: "You are not logged into any GitHub hosts. To log in, run: gh auth login"),
            host: "github.com")
        #expect(reason(notLoggedIn) == .ghNotAuthenticated(host: "github.com"))
    }

    /// codex round 2, MAJOR 7. The 403 that is not rate limiting and not a bad token gets a reason
    /// of its own, and copy that says so rather than sending the user back to `gh auth login`.
    @Test("policyForbiddenIsItsOwnReasonNotAnAuthenticationProblem")
    func policyForbiddenIsItsOwnReasonNotAnAuthenticationProblem() async throws {
        let saml = "HTTP 403: Resource protected by organization SAML enforcement. "
            + "You must grant your OAuth token access to this organization (https://api.github.com/graphql)\n"
        let availability = GHClient.availability(
            forFailedCommand: .nonZeroExit(exitCode: 1, standardError: saml),
            host: "github.com",
            repo: "github.com/newsroom/demo")

        #expect(reason(availability) == .forbidden(repo: "github.com/newsroom/demo"))
        let copy = Strings.unavailable(reason: try #require(reason(availability)))
        #expect(copy.message == "GitHub refused this request for github.com/newsroom/demo "
                + "(policy, SSO, or scopes). Signing in again will not fix it.")
        #expect(copy.action?.kind != .openTerminalWithGhAuthLogin,
                "the one action may not be the one the copy says will not help")
    }

    /// codex round 2, MAJOR 7. `commandFailed` covered a 404 answered in 40 ms and a lookup that
    /// really did run out of time, and its copy asserted both the timing and the cure. The timeout
    /// keeps that copy under its own reason; `commandFailed` says only what happened.
    @Test("timeoutIsItsOwnReasonAndCommandFailedClaimsNoTimingOrCure")
    func timeoutIsItsOwnReasonAndCommandFailedClaimsNoTimingOrCure() async throws {
        let timedOut = GHClient.availability(forFailedCommand: .timedOut(after: 25), host: "github.com")
        #expect(reason(timedOut) == .timedOut)
        #expect(Strings.unavailable(reason: .timedOut).message
                == "The GitHub CLI did not answer for this repo in time. Refreshing usually fixes it.")

        let notFound = GHClient.availability(
            forFailedCommand: .nonZeroExit(exitCode: 1, standardError: "HTTP 404: Not Found (https://api.github.com/repos/x/y)"),
            host: "github.com")
        #expect(reason(notFound) == .commandFailed)

        let copy = Strings.unavailable(reason: .commandFailed, detail: "HTTP 404: Not Found")
        #expect(copy.message == "The GitHub CLI reported an error for this repo: HTTP 404: Not Found")
        for forbidden in ["in time", "Refreshing usually fixes it"] {
            #expect(!copy.message.contains(forbidden), "commandFailed copy claims \(forbidden)")
        }
    }

    /// REVIEW WR-02. A renamed, deleted, or no-longer-visible repo answers 404 or "Could not
    /// resolve to a Repository". Neither is rate limiting and neither is fixed by signing in
    /// again, so both keep the neutral `commandFailed` reason carrying the line that says what
    /// happened.
    @Test("notFoundRepoIsCommandFailed")
    func notFoundRepoIsCommandFailed() async throws {
        let resolve = "GraphQL: Could not resolve to a Repository with the name 'hannahstulberg/gone'. (repository)\n"
        let resolved = GHClient.availability(
            forFailedCommand: .nonZeroExit(exitCode: 1, standardError: resolve), host: "github.com")
        #expect(reason(resolved) == .commandFailed)
        #expect(detail(resolved)?.contains("Could not resolve to a Repository") == true)

        let notFound = GHClient.availability(
            forFailedCommand: .nonZeroExit(
                exitCode: 1, standardError: "HTTP 404: Not Found (https://api.github.com/repos/x/y)"),
            host: "github.com")
        #expect(reason(notFound) == .commandFailed)

        // A 403 that names the missing repo is the repo's problem, not the token's.
        let both = GHClient.availability(
            forFailedCommand: .nonZeroExit(
                exitCode: 1,
                standardError: "HTTP 403: Could not resolve to a Repository with the name 'x/y'."),
            host: "github.com")
        #expect(reason(both) == .commandFailed)
    }

    /// codex round 2, MAJOR 6. The other half of the rule: a host `gh auth status` reports a
    /// login for is a GitHub host whatever it is called, so a GitHub Enterprise remote at NYT
    /// keeps its preflight, its `--repo` operand, and its PR list. Rejecting unknown hosts must
    /// not reject the one enterprise host this app was written for.
    @Test("enterpriseHostAlreadyLoggedInIsAccepted")
    func enterpriseHostAlreadyLoggedInIsAccepted() async throws {
        let enterprise = try #require(GitHubSlug(remoteURL: Fixture.text("synthetic-config-remote-origin-url-ghe.txt")))
        #expect(enterprise.host == "github.nytimes.com")

        let runner = RecordedCommandRunner()
        GH.stubLoggedInHosts(runner, hosts: ["github.com", "github.nytimes.com"])
        GH.stubAuthSuccess(runner, host: "github.nytimes.com")
        runner.stubGH(GH.recentArguments(enterprise), stdout: Fixture.text("synthetic-gh-pr-list-empty.json"))

        let client = GHClient(runner: runner, ghPath: GH.path)
        let result = await client.recentPullRequests(slug: enterprise)

        #expect(value(result) != nil, "a logged-in enterprise host answers like github.com")
        let gh = runner.calls(matchingExecutable: "gh").map(\.arguments)
        #expect(gh.contains(GH.authArguments(host: "github.nytimes.com")), "the per-host preflight still runs")
        #expect(gh.contains(GH.recentArguments(enterprise)))
    }

    /// codex round 2, MAJOR 6. `Repo.swift` accepts any RFC 1123 hostname, so `gitlab.com`,
    /// `localhost`, and an attacker-chosen domain all became "GitHub" slugs and were preflighted
    /// with a `gh` process and offered as `gh auth login --hostname <repo-controlled-host>`.
    /// Only `github.com` and hosts `gh` already holds a login for are GitHub hosts.
    @Test("unknownHostIsNeverPreflightedOrOfferedForSignIn")
    func unknownHostIsNeverPreflightedOrOfferedForSignIn() async throws {
        let gitlab = try #require(GitHubSlug(remoteURL: "git@gitlab.com:team/tools.git"))
        let runner = RecordedCommandRunner()
        GH.stubLoggedInHosts(runner, hosts: ["github.com"])

        let client = GHClient(runner: runner, ghPath: GH.path)
        let result = await client.recentPullRequests(slug: gitlab)

        #expect(reason(try #require(failure(result))) == .notGitHubRemote)
        let gh = runner.calls(matchingExecutable: "gh").map(\.arguments)
        #expect(!gh.contains(GH.authArguments(host: "gitlab.com")))
        #expect(!gh.contains(GH.recentArguments(gitlab)))
    }

    /// codex MINOR 2. Four repo tasks reach `authStatus` at once, all see an empty memo, all
    /// suspend inside `runner.run`, and four `gh auth status` processes start before the first
    /// one memoizes anything. The memo has to hold the in-flight `Task`, not only its result.
    @Test("concurrentReposIssueOneAuthStatusPerHost")
    func concurrentReposIssueOneAuthStatusPerHost() async throws {
        let runner = RecordedCommandRunner()
        runner.tracksConcurrency = true
        runner.stub(.init(
            executableName: "gh",
            arguments: GH.authArguments(host: "github.com"),
            result: .stdout(Fixture.text("recorded-gh-auth-status-github.com.txt")),
            delay: 0.2))
        let client = GHClient(runner: runner, ghPath: GH.path)

        await withTaskGroup(of: PRAvailability.self) { group in
            for _ in 0..<4 {
                group.addTask { await client.authStatus(host: "github.com") }
            }
            for await availability in group { #expect(availability == .available) }
        }

        #expect(runner.calls(matchingExecutable: "gh").count == 1,
                "four repos on one host issued \(runner.calls(matchingExecutable: "gh").count) auth checks")
        #expect(runner.peakInFlight <= 1)
    }

    /// REVIEW CR-02. A `gh auth status` that was cancelled by the refresh deadline, or that timed
    /// out on a slow keychain, says nothing about whether the account is signed in. Memoizing it
    /// makes one slow first refresh report "PR status did not load" for the rest of the session.
    @Test("cancelledAuthCheckIsNotMemoized")
    func cancelledAuthCheckIsNotMemoized() async throws {
        let runner = ScriptedRunner()
        runner.script(GH.authArguments(host: "github.com"), [
            .failure(.cancelled),
            .failure(.timedOut(after: 10)),
            .stdout(Fixture.text("recorded-gh-auth-status-github.com.txt")),
        ])
        let client = GHClient(runner: runner, ghPath: GH.path)

        #expect(reason(await client.authStatus(host: "github.com")) == .commandFailed)
        // The timeout has its own reason since codex round 2 MAJOR 7; what this test is about —
        // that neither is memoized — is unchanged.
        #expect(reason(await client.authStatus(host: "github.com")) == .timedOut)
        #expect(await client.authStatus(host: "github.com") == .available,
                "a cancelled or timed-out preflight was memoized as a failure")
        #expect(runner.calls.count == 3)

        // A real answer is still memoized: the retry is for the two that are not answers.
        #expect(await client.authStatus(host: "github.com") == .available)
        #expect(runner.calls.count == 3)
    }

    /// REVIEW CR-02. `AppModel` keeps one `GHClient` for the life of the process, so "Refresh PRs
    /// now" has to reach past the actor's own list caches, and a sign-in that happened between
    /// refreshes has to be re-checked.
    @Test("bypassSkipsInMemoryPRCache")
    func bypassSkipsInMemoryPRCache() async throws {
        let runner = RecordedCommandRunner()
        GH.stubAuthSuccess(runner)
        runner.stubGH(GH.recentArguments(GH.personalAgent),
                      stdout: Fixture.text("synthetic-gh-pr-list-mixed.json"))
        runner.stubGH(GH.authorArguments(GH.personalAgent),
                      stdout: Fixture.text("recorded-gh-pr-list-author-me-hannah-personal-agent.json"))
        let client = GHClient(runner: runner, ghPath: GH.path)

        _ = await client.recentPullRequests(slug: GH.personalAgent)
        _ = await client.recentPullRequests(slug: GH.personalAgent)
        #expect(runner.calls(matchingExecutable: "gh").filter { $0.arguments.contains("--state") }.count == 1)

        _ = await client.recentPullRequests(slug: GH.personalAgent, bypass: true)
        _ = await client.openAuthoredPullRequests(slug: GH.personalAgent)
        _ = await client.openAuthoredPullRequests(slug: GH.personalAgent, bypass: true)

        let listCalls = runner.calls(matchingExecutable: "gh").filter { $0.arguments.first == "pr" }
        #expect(listCalls.count == 4, "bypass served \(listCalls.count) calls; it must re-fetch each time")
        // The bypassed fetch replaces the entry, so the next cached read is the fresh one.
        _ = await client.recentPullRequests(slug: GH.personalAgent)
        #expect(runner.calls(matchingExecutable: "gh").filter { $0.arguments.first == "pr" }.count == 4)
    }

    /// REVIEW CR-02, the other half: the client outlives one refresh, so the per-refresh promises
    /// in its own doc comment need a way to come true. After a reset the host is preflighted
    /// again — which is what makes the app's own "Open Terminal → `gh auth login` → Refresh"
    /// flow able to succeed without a relaunch.
    @Test("resetForNewRefreshClearsTheAuthMemoAndTheListCaches")
    func resetForNewRefreshClearsTheMemos() async throws {
        let runner = ScriptedRunner()
        runner.script(GH.authArguments(host: "github.com"), [
            .exit(1, stderr: Fixture.text("synthetic-gh-auth-status-401.txt")),
            .stdout(Fixture.text("recorded-gh-auth-status-github.com.txt")),
        ])
        runner.script(GH.recentArguments(GH.personalAgent), [
            .stdout(Fixture.text("synthetic-gh-pr-list-empty.json")),
        ])
        let client = GHClient(runner: runner, ghPath: GH.path)

        #expect(reason(await client.authStatus(host: "github.com")) == .ghNotAuthenticated(host: "github.com"))

        await client.resetForNewRefresh()

        #expect(await client.authStatus(host: "github.com") == .available,
                "the sign-in that just happened is invisible until the memo is cleared")
        #expect(value(await client.recentPullRequests(slug: GH.personalAgent))?.isEmpty == true)

        // And the list caches are cleared too, so a refresh after a reset re-fetches.
        await client.resetForNewRefresh()
        runner.script(GH.recentArguments(GH.personalAgent), [
            .stdout(Fixture.text("synthetic-gh-pr-list-empty.json")),
        ])
        _ = await client.recentPullRequests(slug: GH.personalAgent)
        #expect(runner.calls.filter { $0.arguments.first == "pr" }.count == 2)
    }
}

// MARK: - Packet F13 — codex round 3, MAJOR 3

/// codex round 3, MAJOR 3: "F7's authentication-error classification is not wired into the real
/// preflight." `gh auth status` returning any non-zero exit was hard-coded to `ghNotAuthenticated`
/// while the 401/403/rate-limit classifier sat one method away, reachable only from a **thrown**
/// `CommandError` — and the real runner returns a `CommandOutput` for an ordinary non-zero exit.
/// A managed account refused by SAML was therefore sent round a `gh auth login` loop that cannot
/// lift it.
@Suite("The auth preflight classifies its failure instead of assuming one")
struct GHClientAuthClassificationTests {

    @Test("authStatusPolicyFailureIsForbiddenNotNotAuthenticated")
    func authStatusPolicyFailureIsForbiddenNotNotAuthenticated() async throws {
        let runner = RecordedCommandRunner()
        runner.stub(.init(
            executableName: "gh",
            arguments: GH.authArguments(host: "github.com"),
            result: .exit(1, stderr: "HTTP 403: Resource protected by organization SAML enforcement "
                + "(https://api.github.com/graphql)")))
        let client = GHClient(runner: runner, ghPath: GH.path)

        let availability = await client.authStatus(host: "github.com")
        #expect(reason(availability) == .forbidden(repo: "github.com"),
                "a policy refusal was reported as a credential problem, whose one action is gh auth login")
        #expect(Strings.unavailable(reason: .forbidden(repo: "github.com")).action?.kind == .retryRefresh)
    }

    /// The report is on **stdout** on gh 2.89 and on stderr on older releases (ARCHITECTURE.md
    /// §8), so classifying one stream by name reads the wrong one on half the versions this ships
    /// to. Both are classified together.
    @Test("authStatusClassifiesStdoutAsWellAsStderr")
    func authStatusClassifiesStdoutAsWellAsStderr() async throws {
        let runner = RecordedCommandRunner()
        runner.stub(.init(
            executableName: "gh",
            arguments: GH.authArguments(host: "github.com"),
            result: .exit(1, stdout: Fixture.text("synthetic-gh-auth-status-401.txt"))))
        let client = GHClient(runner: runner, ghPath: GH.path)

        let availability = await client.authStatus(host: "github.com")
        #expect(reason(availability) == .ghNotAuthenticated(host: "github.com"))
        #expect(detail(availability)?.contains("HTTP 401: Bad credentials") == true)
    }

    /// The two reasons that were unreachable from the preflight before, and the fallback that is
    /// neither: a rate limit is a wait, and anything the list does not name claims nothing.
    @Test("authStatusRateLimitAndUnknownFailuresKeepTheirOwnReasons")
    func authStatusRateLimitAndUnknownFailuresKeepTheirOwnReasons() async throws {
        func availability(stderr: String) async -> PRAvailability {
            let runner = RecordedCommandRunner()
            runner.stub(.init(
                executableName: "gh",
                arguments: GH.authArguments(host: "github.com"),
                result: .exit(1, stderr: stderr)))
            return await GHClient(runner: runner, ghPath: GH.path).authStatus(host: "github.com")
        }

        #expect(reason(await availability(stderr: "HTTP 429: API rate limit exceeded")) == .rateLimited)
        #expect(reason(await availability(stderr: "dial tcp: lookup github.com: no such host")) == .commandFailed)
        // And `gh`'s own logged-out wording still means what it always meant.
        #expect(reason(await availability(
            stderr: "You are not logged into any GitHub hosts. To log in, run: gh auth login"))
                == .ghNotAuthenticated(host: "github.com"))
    }
}
