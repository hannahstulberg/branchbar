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
    /// which is one refresh. A failure is memoized exactly like a success, so it short-circuits
    /// `gh pr list` for every repo on that host
    /// (`authStatusFailureShortCircuitsPRListForAllReposOnThatHost`).
    private var authByHost: [String: PRAvailability] = [:]

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
        if let memoized = authByHost[host] { return memoized }

        let command = Command(
            executable: ghPath,
            arguments: ["auth", "status", "--hostname", host],
            environment: Self.frozenEnvironment,
            timeout: policy.ghAuthTimeout
        )

        let availability: PRAvailability
        do {
            let output = try await runner.run(command)
            if output.exitCode == 0 {
                availability = .available
            } else {
                // Every non-zero exit of the preflight means the same thing to the UI: this host
                // needs `gh auth login`. The stderr rides along as the diagnostic.
                availability = .unavailable(
                    .ghNotAuthenticated(host: host),
                    detail: Self.diagnostic(output.standardErrorText)
                )
            }
        } catch let error as CommandError {
            availability = Self.availability(forFailedCommand: error, host: host)
        } catch {
            availability = .unavailable(.commandFailed, detail: Self.diagnostic("\(error)"))
        }

        authByHost[host] = availability
        return availability
    }

    // MARK: - The three frozen list invocations

    /// Runs the frozen `gh pr list --state all --limit 100` invocation and returns the decoded
    /// PRs, mapping a rate-limit stderr to `.rateLimited` and any other non-zero exit to
    /// `.commandFailed` rather than throwing
    /// (`rateLimitResponseMapsToRateLimitedNotCommandFailed`).
    public func recentPullRequests(slug: GitHubSlug) async -> Result<[PRInfo], PRAvailability> {
        let key = slug.ghRepoArgument
        if let cached = cachedPRs(recentCache[key]) { return .success(cached) }

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
    public func pullRequests(slug: GitHubSlug, head: String) async -> Result<[PRInfo], PRAvailability> {
        let key = "\(slug.ghRepoArgument)#\(head)"
        if let cached = cachedPRs(headCache[key]) { return .success(cached) }

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
    public func pullRequests(slug: GitHubSlug, unmatchedHeads: [String]) async -> [String: [PRInfo]] {
        var seen: Set<String> = []
        let heads = unmatchedHeads.filter { seen.insert($0).inserted }.prefix(policy.perHeadFallbackCap)

        var queried: [String: [PRInfo]] = [:]
        for head in heads {
            // A failed query is not an answer: the head stays absent rather than claiming `none`.
            if case .success(let prs) = await pullRequests(slug: slug, head: head) {
                queried[head] = prs
            }
        }
        return queried
    }

    /// Runs the frozen `gh pr list --state open --author @me --limit 100` invocation and returns
    /// the decoded PRs; an empty array is a valid answer, not a failure.
    public func openAuthoredPullRequests(slug: GitHubSlug) async -> Result<[PRInfo], PRAvailability> {
        let key = slug.ghRepoArgument
        if let cached = cachedPRs(authorCache[key]) { return .success(cached) }

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
    /// `PRUnavailableReason` whose copy names the one action that fixes it: a 401 or "Bad
    /// credentials" is `ghNotAuthenticated`, a 403 naming the rate limit is `rateLimited`, and
    /// anything else is `commandFailed` carrying the stderr as the diagnostic.
    public nonisolated static func availability(forFailedCommand error: CommandError, host: String) -> PRAvailability {
        switch error {
        case .launchFailed(_, let message):
            // The GUI PATH has no Homebrew: a launch failure is a missing `gh`, and the reason
            // has exactly one action (`ghMissingMakesEveryBranchUnavailableWithoutThrowing`).
            return .unavailable(.ghNotInstalled, detail: diagnostic(message))

        case .nonZeroExit(_, let standardError):
            let lowercased = standardError.lowercased()
            if lowercased.contains("bad credentials") || standardError.contains("HTTP 401") {
                return .unavailable(.ghNotAuthenticated(host: host), detail: diagnostic(standardError))
            }
            if lowercased.contains("rate limit")
                || standardError.contains("HTTP 429")
                || standardError.contains("HTTP 403") {
                return .unavailable(.rateLimited, detail: diagnostic(standardError))
            }
            // Everything the reason list does not name: the first stderr line is the diagnostic,
            // so the log says what happened and the row still renders.
            return .unavailable(.commandFailed, detail: firstLine(standardError))

        case .timedOut(let after):
            return .unavailable(.commandFailed, detail: "gh timed out after \(Int(after))s")

        case .cancelled:
            return .unavailable(.commandFailed, detail: "gh was cancelled")
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
                    host: slug.host
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
            return .failure(Self.availability(forFailedCommand: error, host: slug.host))
        } catch {
            return .failure(.unavailable(.commandFailed, detail: Self.diagnostic("\(error)")))
        }
    }

    private func cachedPRs(_ entry: CachedList?) -> [PRInfo]? {
        guard let entry, Date().timeIntervalSince(entry.fetchedAt) < policy.prCacheTTL else { return nil }
        return entry.prs
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
