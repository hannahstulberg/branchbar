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

    /// OWNER: packet 2.3 — run `gh auth status --hostname <host>` once per distinct host per
    /// refresh, memoize the answer for this instance, and return `.available` on exit 0 or
    /// `.unavailable(.ghNotAuthenticated(host:), detail:)` carrying the stderr on failure, so one
    /// failure short-circuits `gh pr list` for every repo on that host.
    public func authStatus(host: String) async -> PRAvailability {
        fatalError("OWNER: packet 2.3 — run `gh auth status --hostname <host>` once per host per refresh and memoize the PRAvailability it implies.")
    }

    /// OWNER: packet 2.3 — run the frozen `gh pr list --state all --limit 100` invocation and
    /// return the decoded PRs, mapping a rate-limit stderr to `.rateLimited` and any other
    /// non-zero exit to `.commandFailed` rather than throwing
    /// (`rateLimitResponseMapsToRateLimitedNotCommandFailed`).
    public func recentPullRequests(slug: GitHubSlug) async -> Result<[PRInfo], PRAvailability> {
        fatalError("OWNER: packet 2.3 — run `gh pr list --state all --limit 100` for the slug and return the decoded PRs or the PRAvailability its failure implies.")
    }

    /// OWNER: packet 2.3 — run the frozen `gh pr list --state all --head <branch> --limit 5`
    /// invocation for one branch that the recent-100 list did not match, with the same failure
    /// mapping; the per-repo cap of 20 is enforced by the caller, and every branch past it renders
    /// `notChecked`, never `none`.
    public func pullRequests(slug: GitHubSlug, head: String) async -> Result<[PRInfo], PRAvailability> {
        fatalError("OWNER: packet 2.3 — run `gh pr list --state all --head <branch> --limit 5` for one unmatched branch.")
    }

    /// OWNER: packet 2.3 — run the frozen `gh pr list --state open --author @me --limit 100`
    /// invocation and return the decoded PRs; an empty array is a valid answer, not a failure.
    public func openAuthoredPullRequests(slug: GitHubSlug) async -> Result<[PRInfo], PRAvailability> {
        fatalError("OWNER: packet 2.3 — run `gh pr list --state open --author @me --limit 100` for the slug.")
    }

    /// OWNER: packet 2.3 — classify a failed `gh` invocation from its exit code and stderr into
    /// the `PRUnavailableReason` whose copy names the one action that fixes it: a 401 or "Bad
    /// credentials" is `ghNotAuthenticated`, a 403 naming the rate limit is `rateLimited`, and
    /// anything else is `commandFailed` carrying the stderr as the diagnostic.
    public nonisolated static func availability(forFailedCommand error: CommandError, host: String) -> PRAvailability {
        fatalError("OWNER: packet 2.3 — classify a gh CommandError into PRAvailability: 401/Bad credentials, rate limit 403, or commandFailed.")
    }
}
