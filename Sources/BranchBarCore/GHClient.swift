import Foundation

/// Every `gh` invocation PLAN.md §5 freezes. An actor because the per-repo PR cache and the
/// per-host auth result are shared across the four concurrent repo tasks.
///
/// No `--search` (PLAN.md §3: the search API is 30 req/min); the core limit is 5000/h, so the
/// cache exists for latency, not quota.
public actor GHClient {
    private let runner: CommandRunner
    private let ghPath: String
    private let policy: RefreshPolicy

    /// One `gh auth status --hostname <host>` per distinct host, for the life of this instance —
    /// which is one refresh, and which `resetForNewRefresh()` is how the app makes true. A
    /// failure is memoized exactly like a success, so it short-circuits `gh pr list` for every
    /// repo on that host (`authStatusFailureShortCircuitsPRListForAllReposOnThatHost`).
    ///
    /// The value is the in-flight `Task`, not its result (codex MINOR 2). Four repo tasks reach
    /// this at once; with a result-only memo all four saw an empty dictionary, suspended inside
    /// `runner.run`, and started four `gh auth status` processes before the first one wrote
    /// anything back (`concurrentReposIssueOneAuthStatusPerHost`).
    private var authByHost: [String: Task<AuthAnswer, Never>] = [:]

    /// The hosts `gh auth status` reports a login for, read once per refresh (codex round 2,
    /// MAJOR 6). `Repo.swift` accepts any RFC 1123 hostname as a slug, which is right for parsing
    /// and wrong for trust: `gitlab.com`, `localhost`, an IPv4 literal and an attacker-chosen
    /// domain all became "GitHub" hosts, each one preflighted with a `gh` process and each one
    /// offered to the user as `gh auth login --hostname <repo-controlled-host>`. Only
    /// `github.com` and a host `gh` already holds a login for is treated as GitHub. Held as the
    /// in-flight `Task` for the same reason `authByHost` is.
    private var loggedInHostsTask: Task<Set<String>, Never>?

    /// A preflight result plus whether it is an answer about the account at all.
    private struct AuthAnswer: Sendable {
        var availability: PRAvailability
        /// False for a cancelled or timed-out check: the command never produced a verdict.
        var isVerdict: Bool
    }

    /// PR results cached per repo, TTL `policy.prCacheTTL` — "for latency, not quota"
    /// (`prCacheWithinTTLIssuesNoGhCalls`). Keyed by `slug.ghRepoArgument`, and by the head as
    /// well for the per-branch fallback.
    private struct CachedList {
        var fetchedAt: Date
        var prs: [PRInfo]
    }

    private var recentCache: [String: CachedList] = [:]
    private var authorCache: [String: CachedList] = [:]
    private var headCache: [String: CachedList] = [:]

    /// PLAN.md §5, frozen after the codex review: a GUI-launched `gh` must never prompt, never
    /// page, never colorize, and never check for updates.
    public static let frozenEnvironment: [String: String] = [
        "GH_PROMPT_DISABLED": "1",
        "GH_NO_UPDATE_NOTIFIER": "1",
        "GH_PAGER": "cat",
        "NO_COLOR": "1",
        "CLICOLOR": "0",
    ]

    /// The `--json` field list shared by all three `gh pr list` invocations.
    public static let jsonFields = "number,url,state,isDraft,reviewDecision,mergedAt,updatedAt,baseRefName,headRefName,headRefOid,headRepositoryOwner,mergeCommit"

    // depends on ToolLocator (packet 0.3)
    public init(runner: CommandRunner, ghPath: String, policy: RefreshPolicy = .default) {
        self.runner = runner
        self.ghPath = ghPath
        self.policy = policy
    }

    // MARK: - Auth preflight

    /// Runs `gh auth status --hostname <host>` once per distinct host per refresh, memoizes the
    /// answer for this instance, and returns `.available` on exit 0 or
    /// `.unavailable(.ghNotAuthenticated(host:), detail:)` carrying the stderr on failure, so one
    /// failure short-circuits `gh pr list` for every repo on that host.
    public func authStatus(host: String) async -> PRAvailability {
        // codex round 2, MAJOR 6: a host this app has no reason to believe is GitHub never
        // reaches a `gh` process and is never offered as a sign-in target. It gets the answer a
        // `file://` remote gets.
        guard await isGitHubHost(host) else {
            return .unavailable(.notGitHubRemote, detail: host)
        }
        if let inFlight = authByHost[host] { return await inFlight.value.availability }

        let command = Command(
            executable: ghPath,
            arguments: ["auth", "status", "--hostname", host],
            environment: Self.frozenEnvironment,
            timeout: policy.ghAuthTimeout
        )

        let task = Task<AuthAnswer, Never> { [runner] in
            do {
                let output = try await runner.run(command)
                if output.exitCode == 0 { return AuthAnswer(availability: .available, isVerdict: true) }
                // codex round 3, MAJOR 3. Every non-zero exit used to mean the same thing here —
                // "this host needs `gh auth login`" — while the classifier that tells a 401 from a
                // 403 from a rate limit sat one method away, reachable only from a **thrown**
                // `CommandError`. The real runner returns a `CommandOutput` for an ordinary
                // non-zero exit, so the classifier never ran on the preflight, and a managed
                // account refused by SAML or an organization policy was sent round a
                // `gh auth login` loop that cannot lift either.
                //
                // Both streams are classified together because `gh auth status` writes its report
                // to stdout on gh 2.89 and to stderr on older releases (ARCHITECTURE.md §8), so
                // reading either one by name reads the wrong one on half the versions this ships
                // to.
                return AuthAnswer(
                    availability: Self.availability(
                        forFailedCommand: .nonZeroExit(
                            exitCode: output.exitCode,
                            standardError: Self.combinedStreams(output)),
                        host: host),
                    isVerdict: true)
            } catch let error as CommandError {
                // A cancelled or timed-out check says nothing about the account: the refresh
                // deadline arrived, or the keychain was slow.
                let isVerdict: Bool
                switch error {
                // Packet F6 / codex round 2, MINOR 2: a pipe we could not read through says
                // nothing about the account either.
                case .cancelled, .timedOut, .outputTooLarge, .readFailed: isVerdict = false
                case .launchFailed, .nonZeroExit: isVerdict = true
                }
                return AuthAnswer(
                    availability: Self.availability(forFailedCommand: error, host: host),
                    isVerdict: isVerdict)
            } catch {
                return AuthAnswer(
                    availability: .unavailable(.commandFailed, detail: Self.diagnostic("\(error)")),
                    isVerdict: false)
            }
        }
        authByHost[host] = task

        let answer = await task.value
        // Keeping a non-verdict makes one slow first refresh report "PR status did not load" for
        // the rest of the session (REVIEW CR-02, `cancelledAuthCheckIsNotMemoized`). Drop it so
        // the next repo — or the next refresh — asks again.
        if !answer.isVerdict, authByHost[host] == task {
            authByHost[host] = nil
        }
        return answer.availability
    }

    /// Everything memoized in this actor belongs to one refresh; the app keeps one client for the
    /// life of the process, so this is how the next refresh gets a clean one (REVIEW CR-02).
    /// Without it a `gh auth login` the user just ran in Terminal stays invisible until relaunch,
    /// and "Refresh PRs now" serves the same ten-minute-old list it was told to bypass.
    /// True for `github.com`, and for a host `gh auth status` lists a login for. Nothing else
    /// (codex round 2, MAJOR 6).
    public func isGitHubHost(_ host: String) async -> Bool {
        if host == GitHubSlug.gitHubDotCom { return true }
        return await loggedInHosts().contains(host)
    }

    /// `gh auth status` with no `--hostname`: one process per refresh, whose host lines name every
    /// host `gh` holds a login for. Judged by its output and not by its exit code — `gh` exits
    /// non-zero when *any* configured host is logged out, and the hosts that are logged in are
    /// still listed.
    private func loggedInHosts() async -> Set<String> {
        if let inFlight = loggedInHostsTask { return await inFlight.value }

        let command = Command(
            executable: ghPath,
            arguments: ["auth", "status"],
            environment: Self.frozenEnvironment,
            timeout: policy.ghAuthTimeout
        )
        let task = Task<Set<String>, Never> { [runner] in
            guard let output = try? await runner.run(command) else { return [] }
            return Self.loggedInHosts(inAuthStatus: output.standardOutputText + "\n" + output.standardErrorText)
        }
        loggedInHostsTask = task
        return await task.value
    }

    /// Every `<host>` in a `Logged in to <host> …` line, lower-cased and held to the same hostname
    /// grammar `GitHubSlug` applies. gh 2.89 writes the list to stdout; older builds wrote it to
    /// stderr, so both streams are read.
    nonisolated static func loggedInHosts(inAuthStatus text: String) -> Set<String> {
        var hosts: Set<String> = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let marker = line.range(of: "Logged in to ") else { continue }
            let rest = line[marker.upperBound...]
            guard let token = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first else {
                continue
            }
            let host = String(token).lowercased()
            if GitHubSlug.isValidHostname(host) { hosts.insert(host) }
        }
        return hosts
    }

    public func resetForNewRefresh() {
        loggedInHostsTask = nil
        authByHost.removeAll()
        recentCache.removeAll()
        authorCache.removeAll()
        headCache.removeAll()
    }


    // MARK: - The three frozen list invocations

    /// Runs the frozen `gh pr list --state all --limit 100` invocation and returns the decoded
    /// PRs, mapping a rate-limit stderr to `.rateLimited` and any other non-zero exit to
    /// `.commandFailed` rather than throwing
    /// (`rateLimitResponseMapsToRateLimitedNotCommandFailed`).
    public func recentPullRequests(slug: GitHubSlug, bypass: Bool = false) async -> Result<[PRInfo], PRAvailability> {
        let key = slug.ghRepoArgument
        if !bypass, let cached = cachedPRs(recentCache[key]) { return .success(cached) }

        let result = await list(
            slug: slug,
            arguments: [
                "pr", "list",
                "--repo", slug.ghRepoArgument,
                "--state", "all",
                "--limit", "100",
                "--json", Self.jsonFields,
            ]
        )
        if case .success(let prs) = result {
            recentCache[key] = CachedList(fetchedAt: Date(), prs: prs)
        }
        return result
    }

    /// Runs the frozen `gh pr list --state all --head <branch> --limit 5` invocation for one
    /// branch that the recent-100 list did not match, with the same failure mapping; the per-repo
    /// cap of 20 is enforced by the caller, and every branch past it renders `notChecked`, never
    /// `none`.
    public func pullRequests(slug: GitHubSlug, head: String, bypass: Bool = false) async -> Result<[PRInfo], PRAvailability> {
        let key = "\(slug.ghRepoArgument)#\(head)"
        if !bypass, let cached = cachedPRs(headCache[key]) { return .success(cached) }

        let result = await list(
            slug: slug,
            arguments: [
                "pr", "list",
                "--repo", slug.ghRepoArgument,
                "--state", "all",
                "--head", head,
                "--limit", "5",
                "--json", Self.jsonFields,
            ]
        )
        if case .success(let prs) = result {
            headCache[key] = CachedList(fetchedAt: Date(), prs: prs)
        }
        return result
    }

    /// The capped per-head fallback, and the caller `RepoLoader` (packet 3.1) uses it: queries at
    /// most `policy.perHeadFallbackCap` heads, in the order given, and returns one entry per head
    /// it actually queried. A head that was queried and found no PR maps to an empty array; a
    /// head past the cap is absent, which is the `none` versus `notChecked` distinction
    /// `RepoAssembler` renders (`unqueriedBranchIsNotCheckedNeverNone`).
    public func pullRequests(slug: GitHubSlug, unmatchedHeads: [String], bypass: Bool = false) async -> [String: [PRInfo]] {
        var seen: Set<String> = []
        let heads = unmatchedHeads.filter { seen.insert($0).inserted }.prefix(policy.perHeadFallbackCap)

        var queried: [String: [PRInfo]] = [:]
        for head in heads {
            // A failed query is not an answer: the head stays absent rather than claiming `none`.
            if case .success(let prs) = await pullRequests(slug: slug, head: head, bypass: bypass) {
                queried[head] = prs
            }
        }
        return queried
    }

    /// Runs the frozen `gh pr list --state open --author @me --limit 100` invocation and returns
    /// the decoded PRs; an empty array is a valid answer, not a failure.
    public func openAuthoredPullRequests(slug: GitHubSlug, bypass: Bool = false) async -> Result<[PRInfo], PRAvailability> {
        let key = slug.ghRepoArgument
        if !bypass, let cached = cachedPRs(authorCache[key]) { return .success(cached) }

        let result = await list(
            slug: slug,
            arguments: [
                "pr", "list",
                "--repo", slug.ghRepoArgument,
                "--state", "open",
                "--author", "@me",
                "--limit", "100",
                "--json", Self.jsonFields,
            ]
        )
        if case .success(let prs) = result {
            authorCache[key] = CachedList(fetchedAt: Date(), prs: prs)
        }
        return result
    }

    // MARK: - Failure classification

    /// Classifies a failed `gh` invocation from its exit code and stderr into the
    /// `PRUnavailableReason` whose copy names the one action that fixes it.
    ///
    /// The order matters, and it is the order of how specific the evidence is (codex MAJOR 11,
    /// REVIEW WR-02):
    ///
    /// 1. A 401, a "Bad credentials" body, or `gh`'s own "not logged in" is `ghNotAuthenticated`:
    ///    the credential is wrong or missing, and signing in again is the fix.
    /// 2. A 404 or "Could not resolve to a Repository" is `commandFailed`: the repo is renamed,
    ///    deleted, or not visible to this account. Neither waiting nor signing in fixes it, so it
    ///    keeps the neutral reason and carries the line that says what happened.
    /// 3. Only an explicit rate-limit message or a 429 is `rateLimited`, whose copy promises that
    ///    waiting a few minutes fixes it.
    /// 4. Any **other** 403 is `forbidden`: SAML enforcement, a missing `repo` scope, an IP
    ///    allow-list, an organization policy. It used to be `ghNotAuthenticated`, whose one action
    ///    is `gh auth login` — a loop a managed NYT account cannot get out of, because none of
    ///    these is a credential problem (codex round 2, MAJOR 7).
    /// 5. The runner's timeout is `timedOut`, and only the runner's timeout: it is the one failure
    ///    whose copy may say the CLI ran out of time.
    /// 6. Everything else is `commandFailed` carrying the first stderr line, and its copy claims
    ///    nothing about the cause or the cure.
    ///
    /// `repo` is the `host/owner/name` the request named, which `forbidden`'s copy repeats back;
    /// with none given the host stands in, which is what an auth preflight has.
    public nonisolated static func availability(
        forFailedCommand error: CommandError,
        host: String,
        repo: String? = nil
    ) -> PRAvailability {
        switch error {
        case .launchFailed(_, let message):
            // The GUI PATH has no Homebrew: a launch failure is a missing `gh`, and the reason
            // has exactly one action (`ghMissingMakesEveryBranchUnavailableWithoutThrowing`).
            return .unavailable(.ghNotInstalled, detail: diagnostic(message))

        case .nonZeroExit(_, let standardError):
            let lowercased = standardError.lowercased()
            if lowercased.contains("bad credentials")
                || standardError.contains("HTTP 401")
                || lowercased.contains("not logged in") {
                return .unavailable(.ghNotAuthenticated(host: host), detail: diagnostic(standardError))
            }
            if lowercased.contains("could not resolve to a repository")
                || standardError.contains("HTTP 404") {
                return .unavailable(.commandFailed, detail: firstLine(standardError))
            }
            if lowercased.contains("rate limit") || standardError.contains("HTTP 429") {
                return .unavailable(.rateLimited, detail: diagnostic(standardError))
            }
            if standardError.contains("HTTP 403") {
                return .unavailable(.forbidden(repo: repo ?? host), detail: firstLine(standardError))
            }
            // Everything the reason list does not name: the first stderr line is the diagnostic,
            // so the log says what happened and the row still renders.
            return .unavailable(.commandFailed, detail: firstLine(standardError))

        case .timedOut(let after):
            return .unavailable(.timedOut, detail: "gh timed out after \(Int(after))s")

        case .cancelled:
            return .unavailable(.commandFailed, detail: "gh was cancelled")

        case .outputTooLarge(let stream, let limit):
            return .unavailable(.commandFailed, detail: "gh wrote more than \(limit) bytes to \(stream.rawValue)")

        // Packet F6 / codex round 2, MINOR 2. A pipe that failed partway is a failure to hear the
        // answer, not an answer: the partial output is discarded upstream, so the row says the
        // command failed rather than showing a shorter list than gh actually returned.
        case .readFailed(let stream, let message):
            return .unavailable(.commandFailed, detail: "could not read gh's \(stream.rawValue): \(message)")
        }
    }

    // MARK: - Private

    /// One `gh pr list`, preflighted by the host's auth answer and never throwing.
    private func list(slug: GitHubSlug, arguments: [String]) async -> Result<[PRInfo], PRAvailability> {
        let auth = await authStatus(host: slug.host)
        if case .unavailable = auth { return .failure(auth) }

        let command = Command(
            executable: ghPath,
            arguments: arguments,
            environment: Self.frozenEnvironment,
            timeout: policy.ghListTimeout
        )

        do {
            let output = try await runner.run(command)
            guard output.exitCode == 0 else {
                return .failure(Self.availability(
                    forFailedCommand: .nonZeroExit(exitCode: output.exitCode, standardError: output.standardErrorText),
                    host: slug.host,
                    repo: slug.ghRepoArgument
                ))
            }
            do {
                return .success(try PRListDecoder.decode(output.standardOutput))
            } catch {
                // A truncated stream is a failed read of PR status, not an empty repo: an empty
                // list would render every branch as "no PR" (`malformedJSONIsCommandFailed`).
                return .failure(.unavailable(.commandFailed, detail: Self.diagnostic("\(error)")))
            }
        } catch let error as CommandError {
            return .failure(Self.availability(forFailedCommand: error, host: slug.host, repo: slug.ghRepoArgument))
        } catch {
            return .failure(.unavailable(.commandFailed, detail: Self.diagnostic("\(error)")))
        }
    }

    private func cachedPRs(_ entry: CachedList?) -> [PRInfo]? {
        guard let entry, Date().timeIntervalSince(entry.fetchedAt) < policy.prCacheTTL else { return nil }
        return entry.prs
    }

    /// Both streams, in the order a reader would see them, for a command that reports itself to
    /// whichever one the installed `gh` prefers (codex round 3, MAJOR 3).
    private nonisolated static func combinedStreams(_ output: CommandOutput) -> String {
        [output.standardOutputText, output.standardErrorText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The whole stderr, trimmed — the line that names the failure is often several lines in
    /// (`gh auth status` prints its bullet list before "HTTP 401: Bad credentials").
    private nonisolated static func diagnostic(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The first non-empty stderr line, which is what `commandFailed` carries.
    private nonisolated static func firstLine(_ text: String) -> String? {
        let line = text
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let line else { return nil }
        return String(line).trimmingCharacters(in: .whitespaces)
    }
}
