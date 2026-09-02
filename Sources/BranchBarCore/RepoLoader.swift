import Foundation

/// One repo, end to end: git first (always, it is local and fast), then `gh` only when the repo
/// is expanded or in the 5 most recently active and its PR cache is older than the TTL.
///
/// PLAN.md §3: a stage that fails is recorded as a `RepoError` and the other stages still run,
/// so `oneRepoFailingLeavesOthersPopulated` holds.
public struct RepoLoader: Sendable {
    private let git: GitClient
    private let gh: GHClient?
    private let reflog: ReflogFileReader
    private let policy: RefreshPolicy

    public init(git: GitClient, gh: GHClient?, reflog: ReflogFileReader, policy: RefreshPolicy = .default) {
        self.git = git
        self.gh = gh
        self.reflog = reflog
        self.policy = policy
    }

    /// Run the five git stages for this repo (`rev-parse`, `config --get remote.origin.url`, both
    /// `for-each-ref`s, `worktree list`) plus a reflog file read per upstream branch, catching each
    /// stage into a `RepoError` instead of throwing; then, only when `wantsPullRequests` is true
    /// and `cachedPRs` is nil or older than `policy.prCacheTTL`, run the recent-100 `gh` list, up
    /// to `policy.perHeadFallbackCap` per-head queries for branches it did not match, and the
    /// author-@me list; and return `RepoAssembler.assemble` of everything, with `queriedHeads`
    /// naming exactly the heads that were actually queried.
    ///
    /// Never throws. Every failure is a `RepoError` on the returned `Repo`, which is what makes
    /// `oneRepoFailingLeavesOthersPopulated` hold one level up in `RefreshCoordinator`.
    ///
    /// `previous` is the repo this loader returned last refresh, and it is the one added
    /// parameter beyond the frozen signature: when `for-each-ref -- refs/heads` fails there is no
    /// branch list, and PLAN.md §3 says the rows go stale rather than vanishing.
    public func load(
        _ discovered: DiscoveredRepo,
        wantsPullRequests: Bool,
        cachedPRs: PRCacheEntry?,
        now: Date,
        previous: Repo? = nil
    ) async -> Repo {
        var errors: [RepoError] = []

        // Stage 1 — identity. The scan already recorded both paths, so a failure here costs only
        // the canonical spelling; it is reported against `.reflog` because the common dir is what
        // the reflog stage reads, and that is the stage a wrong one would silently break.
        var commonDirectory = discovered.id.commonDir
        var path = discovered.path
        do {
            let identity = try await git.identity(at: discovered.path)
            commonDirectory = identity.commonDirectory
            path = identity.topLevel
        } catch {
            errors.append(RepoError(
                stage: .reflog,
                message: "git rev-parse failed (\(Self.describe(error))); falling back to the scanned paths"))
        }

        // Stage 2 — the remote URL. An unset key is nil and not an error: it is how a repo reaches
        // `PRUnavailableReason.noRemote`.
        var remoteURL: String?
        do {
            remoteURL = try await git.remoteOriginURL(at: path)
        } catch {
            errors.append(RepoError(stage: .remotes, message: "git config --get remote.origin.url failed (\(Self.describe(error)))"))
        }
        let slug = remoteURL.flatMap(GitHubSlug.init(remoteURL:))

        // Stage 3 — the branch list. This one is the repo: with no rows there is nothing honest to
        // render, so the previous refresh's repo comes back marked stale.
        let branchRefs: [ParsedBranchRef]
        do {
            branchRefs = try await git.branchRefs(at: path)
        } catch {
            errors.append(RepoError(stage: .branches, message: "git for-each-ref -- refs/heads failed (\(Self.describe(error)))"))
            return Self.stale(
                previous: previous,
                discovered: discovered,
                path: path,
                remoteURL: remoteURL,
                slug: slug,
                errors: errors)
        }

        // Stage 4 — the remote-tracking tips, which back `originMovedSince` and the last-known
        // origin anchor. Losing them costs push detail, never a branch row.
        var remoteRefs: [ParsedRemoteRef] = []
        do {
            remoteRefs = try await git.remoteRefs(at: path)
        } catch {
            errors.append(RepoError(stage: .remotes, message: "git for-each-ref -- refs/remotes/ failed (\(Self.describe(error)))"))
        }

        // Stage 5 — worktrees. Losing them costs the worktree marker, never a branch row.
        var worktrees: [Worktree] = []
        do {
            worktrees = try await git.worktrees(at: path)
        } catch {
            errors.append(RepoError(stage: .worktrees, message: "git worktree list --porcelain failed (\(Self.describe(error)))"))
        }

        // Stage 6 — one reflog file per upstream branch, isolated per branch. An absent file is
        // nil and not an error (a branch that was never pushed has no reflog); a file that exists
        // and cannot be read is reported by name, because swallowing it would render "Last push
        // unknown" for a branch that really was pushed.
        var observations: [String: ReflogObservation] = [:]
        for row in branchRefs where row.refName.hasPrefix("refs/heads/") {
            guard let upstream = ForEachRefParser.upstream(from: row) else { continue }
            do {
                if let observation = try reflog.observation(
                    commonDirectory: commonDirectory,
                    remote: upstream.remote,
                    branch: upstream.branchName) {
                    observations[row.branchName] = observation
                }
            } catch {
                let file = ReflogFileReader.reflogPath(
                    commonDirectory: commonDirectory, remote: upstream.remote, branch: upstream.branchName)
                errors.append(RepoError(stage: .reflog, message: "\(file): \(Self.describe(error))"))
            }
        }

        // Stage 7 — PRs, and only if asked. PLAN.md §3: `gh` runs when the repo is expanded or in
        // the 5 most recently active, and the cache exists "for latency, not quota".
        var pr = PRStage()
        let cacheIsFresh = cachedPRs.map { now.timeIntervalSince($0.fetchedAt) < policy.prCacheTTL } ?? false

        if let cachedPRs, cacheIsFresh {
            // `prCacheWithinTTLIssuesNoGhCalls`: a warm entry answers outright. `queriedHeads`
            // stays empty because this refresh asked nothing, so a branch the cached list does not
            // name reads `notChecked` and never `none`.
            pr.pullRequests = cachedPRs.prs
            pr.authored = cachedPRs.authorPRs
            pr.fetchedAt = cachedPRs.fetchedAt
            pr.loadState = .loaded
        } else if wantsPullRequests {
            await runPullRequestStage(
                into: &pr,
                errors: &errors,
                branchRefs: branchRefs,
                remoteURL: remoteURL,
                slug: slug,
                now: now)
        } else if let cachedPRs {
            // Not eager, and the entry is past its TTL: show what was last known rather than
            // blanking the pills, and say it is stale.
            pr.pullRequests = cachedPRs.prs
            pr.authored = cachedPRs.authorPRs
            pr.fetchedAt = cachedPRs.fetchedAt
            pr.loadState = .stale
        }

        return RepoAssembler.assemble(RepoAssembler.Inputs(
            id: discovered.id,
            path: path,
            remoteURL: remoteURL,
            branchRefs: branchRefs,
            remoteRefs: remoteRefs,
            worktrees: worktrees,
            pushObservations: observations,
            pullRequests: pr.pullRequests,
            authoredOpenPullRequests: pr.authored,
            queriedHeads: pr.queriedHeads,
            prAvailability: pr.availability,
            prFetchedAt: pr.fetchedAt,
            prLoadState: pr.loadState,
            errors: errors,
            isStale: false,
            refreshedAt: now))
    }

    // MARK: - The `gh` stage

    /// What the PR stage produced, gathered in one value so `load` reads as seven stages rather
    /// than seven mutable locals.
    private struct PRStage {
        var pullRequests: [PRInfo] = []
        var authored: [PRInfo] = []
        var queriedHeads: Set<String> = []
        var availability: PRAvailability = .available
        var fetchedAt: Date?
        var loadState: PRLoadState = .notLoaded
    }

    /// The three frozen `gh pr list` invocations, in PLAN.md §5's order. A failure of the
    /// recent-100 list is a repo-wide answer — the host cannot be asked — so the per-head and
    /// author calls are skipped rather than repeating it once per branch.
    private func runPullRequestStage(
        into pr: inout PRStage,
        errors: inout [RepoError],
        branchRefs: [ParsedBranchRef],
        remoteURL: String?,
        slug: GitHubSlug?,
        now: Date
    ) async {
        pr.loadState = .loaded

        guard let gh else {
            pr.availability = .unavailable(.ghNotInstalled, detail: nil)
            return
        }
        guard let slug else {
            // Two different answers with two different actions (PLAN.md §5a): no remote at all,
            // versus a remote this app cannot turn into a `gh --repo` argument.
            pr.availability = remoteURL == nil
                ? .unavailable(.noRemote, detail: nil)
                : .unavailable(.notGitHubRemote, detail: remoteURL)
            return
        }

        switch await gh.recentPullRequests(slug: slug) {
        case .failure(let unavailable):
            pr.availability = unavailable
            errors.append(RepoError(stage: .github, message: Self.describe(unavailable)))
            return
        case .success(let recent):
            pr.pullRequests = recent
            pr.fetchedAt = now
            pr.queriedHeads.formUnion(recent.map(\.headRefName))
        }

        // The per-head fallback, capped per repo per refresh by `GHClient`. The cap is spent
        // most-recently-active first, because that is where a live PR is: branches past it render
        // `notChecked`, never `none` (`unqueriedBranchIsNotCheckedNeverNone`).
        let unmatched = branchRefs
            .filter { $0.refName.hasPrefix("refs/heads/") }
            .sorted { $0.committerDate > $1.committerDate }
            .map(\.branchName)
            .filter { !pr.queriedHeads.contains($0) }

        if !unmatched.isEmpty {
            for (head, prs) in await gh.pullRequests(slug: slug, unmatchedHeads: unmatched) {
                pr.queriedHeads.insert(head)
                pr.pullRequests.append(contentsOf: prs)
            }
        }

        // "Open PRs not on this Mac". Its failure costs one group, not the pills, so the repo
        // stays available and the error rides along.
        switch await gh.openAuthoredPullRequests(slug: slug) {
        case .success(let authored):
            pr.authored = authored
        case .failure(let unavailable):
            errors.append(RepoError(stage: .github, message: "author PR list: \(Self.describe(unavailable))"))
        }
    }

    // MARK: - Failure paths

    /// PLAN.md §3: when the branch list itself fails, last refresh's rows come back marked stale
    /// with the error attached. With no previous refresh there is nothing to keep, but the repo
    /// still renders as a section carrying its failure.
    private static func stale(
        previous: Repo?,
        discovered: DiscoveredRepo,
        path: String,
        remoteURL: String?,
        slug: GitHubSlug?,
        errors: [RepoError]
    ) -> Repo {
        guard var repo = previous else {
            return Repo(
                id: discovered.id,
                name: (path as NSString).lastPathComponent,
                path: path,
                remoteURL: remoteURL,
                githubSlug: slug,
                errors: errors,
                isStale: true)
        }
        // This refresh's errors, not last refresh's: the old ones described a run that is over.
        repo.errors = errors
        repo.isStale = true
        return repo
    }

    /// A short diagnostic for the log. Never user-facing copy — packet 4.0's `Strings.swift` owns
    /// what the user reads for each failure.
    private static func describe(_ error: Error) -> String {
        switch error {
        case let error as CommandError:
            switch error {
            case .launchFailed(let executable, let message): return "could not launch \(executable): \(message)"
            case .nonZeroExit(let code, let standardError):
                let line = standardError.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                return line.isEmpty ? "exit \(code)" : "exit \(code): \(line)"
            case .timedOut(let after): return "timed out after \(Int(after))s"
            case .cancelled: return "cancelled"
            }
        default:
            return "\(error)"
        }
    }

    private static func describe(_ availability: PRAvailability) -> String {
        guard case .unavailable(let reason, let detail) = availability else { return "available" }
        let name: String
        switch reason {
        case .ghNotInstalled: name = "ghNotInstalled"
        case .ghNotAuthenticated(let host): name = "ghNotAuthenticated(\(host))"
        case .noRemote: name = "noRemote"
        case .notGitHubRemote: name = "notGitHubRemote"
        case .rateLimited: name = "rateLimited"
        case .commandFailed: name = "commandFailed"
        }
        guard let detail, !detail.isEmpty else { return name }
        return "\(name): \(detail)"
    }
}
