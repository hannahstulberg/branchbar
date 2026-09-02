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
    private let fileSystem: FileSystem
    private let policy: RefreshPolicy
    /// The seam the per-remote URL lookup runs through, and the git it runs. Optional because
    /// `GitClient` freezes one remote — `origin` — and belongs to another packet: rather than add
    /// an invocation there, the loader issues `config --get remote.<name>.url` itself, in the same
    /// frozen shape and environment `GitClient.command` builds (codex round 2, MAJOR 4). With no
    /// runner the loader resolves origin from the slug and nothing else, which is what it did
    /// before.
    private let runner: CommandRunner?
    private let gitPath: String?

    /// `fileSystem` is the same seam `reflog` already reads through, named separately because the
    /// loader also has to stat `FETCH_HEAD` for the "last seen" anchor (codex MAJOR 7) and
    /// `ReflogFileReader` holds its copy privately. It defaults to `RealFileSystem` the way
    /// `RefreshCoordinator`'s does, so the two production call sites keep their argument lists.
    public init(
        git: GitClient,
        gh: GHClient?,
        reflog: ReflogFileReader,
        fileSystem: FileSystem = RealFileSystem(),
        policy: RefreshPolicy = .default,
        runner: CommandRunner? = nil,
        gitPath: String? = nil
    ) {
        self.git = git
        self.gh = gh
        self.reflog = reflog
        self.fileSystem = fileSystem
        self.policy = policy
        self.runner = runner
        self.gitPath = gitPath
    }

    /// Run the five git stages for this repo (`rev-parse`, `config --get remote.origin.url`, both
    /// `for-each-ref`s, `worktree list -z`) plus a reflog file read per branch, catching each
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
        await loadReportingPRCache(
            discovered,
            wantsPullRequests: wantsPullRequests,
            cachedPRs: cachedPRs,
            now: now,
            previous: previous).repo
    }

    /// One repo plus the `PRCacheEntry` the next refresh should be handed for it.
    ///
    /// `RefreshCoordinator` (packet 3.2) persists `prCache`, and a `Repo` cannot be turned back
    /// into one honestly: it holds only the PRs that matched a local branch, and nothing at all
    /// about which heads were asked. `queriedHeads` is the field that keeps `none` and
    /// `notChecked` distinguishable across a relaunch.
    public struct LoadResult: Sendable {
        public var repo: Repo
        /// nil when this refresh neither fetched nor was given anything worth keeping.
        public var prCache: PRCacheEntry?

        public init(repo: Repo, prCache: PRCacheEntry?) {
            self.repo = repo
            self.prCache = prCache
        }
    }

    /// `load`, plus the cache entry. See `load` for the stage-by-stage contract.
    public func loadReportingPRCache(
        _ discovered: DiscoveredRepo,
        wantsPullRequests: Bool,
        cachedPRs: PRCacheEntry?,
        now: Date,
        previous: Repo? = nil
    ) async -> LoadResult {
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
            // The entry rides through untouched: this refresh learned nothing about PRs, and
            // dropping it would cost the next one a fetch it does not need.
            return LoadResult(
                repo: Self.stale(
                    previous: previous,
                    discovered: discovered,
                    path: path,
                    remoteURL: remoteURL,
                    slug: slug,
                    errors: errors),
                prCache: cachedPRs)
        }

        // Stage 4 — the remote-tracking tips, which back `originMovedSince` and the last-known
        // origin anchor. Losing them costs push detail, never a branch row.
        var remoteRefs: [ParsedRemoteRef] = []
        do {
            remoteRefs = try await git.remoteRefs(at: path)
        } catch {
            errors.append(RepoError(stage: .remotes, message: "git for-each-ref -- refs/remotes/ failed (\(Self.describe(error)))"))
        }

        // Stage 5 — worktrees. Losing them costs the worktree marker, never a branch row — and
        // `worktreesEnumerated` carries the difference between "no worktree holds this branch" and
        // "we do not know", which is what keeps a checked-out branch out of the Merged group when
        // the stage failed (codex MAJOR 12).
        var worktrees: [Worktree] = []
        var worktreesEnumerated = true
        do {
            worktrees = try await git.worktrees(at: path)
        } catch {
            worktreesEnumerated = false
            errors.append(RepoError(
                stage: .worktrees,
                message: "git worktree list --porcelain -z failed (\(Self.describe(error)))"))
        }

        // Who owns each remote this repo's branches actually track. `origin` is the slug, which
        // stage 2 already read; every other remote costs one `config --get remote.<name>.url`,
        // issued once per distinct name. Without it a branch tracking a fork fell back to the
        // origin repository's owner, which is a different head that happens to share a name
        // (codex round 2, MAJOR 4).
        var remoteOwners: [String: String] = [:]
        if let owner = slug?.owner { remoteOwners["origin"] = owner }
        for name in Self.upstreamRemoteNames(of: branchRefs) where remoteOwners[name] == nil {
            do {
                if let url = try await configuredRemoteURL(forRemote: name, at: path),
                   let remoteSlug = GitHubSlug(remoteURL: url) {
                    remoteOwners[name] = remoteSlug.owner
                }
            } catch {
                errors.append(RepoError(
                    stage: .remotes,
                    message: "git config --get remote.\(name).url failed (\(Self.describe(error)))"))
            }
        }

        // When this clone last heard from origin. `FETCH_HEAD` is rewritten by every fetch and by
        // nothing else, so its modification date is a local observation — unlike the remote tip's
        // committer date, which the tooltip used to report as "last seen" (codex MAJOR 7). A clone
        // that has only ever been pushed from has no `FETCH_HEAD`, and that is not an error.
        let fetchHeadPath = (commonDirectory as NSString).appendingPathComponent("FETCH_HEAD")
        let fetchHeadObservedAt = try? fileSystem.modificationDate(atPath: fetchHeadPath)

        // Stage 6 — one reflog file per upstream branch, isolated per branch. An absent file is
        // nil and not an error (a branch that was never pushed has no reflog); a file that exists
        // and cannot be read is reported by name, because swallowing it would render "Last push
        // unknown" for a branch that really was pushed.
        //
        // A branch with no upstream is read too, against the candidate ref `origin/<branch>`, but
        // only when `for-each-ref -- refs/remotes/` actually listed that ref: `git push origin
        // <branch>` without `-u` leaves a real push record and no tracking configuration, and
        // calling that "never pushed" was a claim the data never supported (codex MAJOR 6).
        let remoteShortNames = Set(remoteRefs.map(\.shortName))
        var observations: [String: ReflogObservation] = [:]
        for row in branchRefs where row.refName.hasPrefix("refs/heads/") {
            let remote: String
            let remoteBranch: String
            if let upstream = ForEachRefParser.upstream(from: row) {
                remote = upstream.remote
                remoteBranch = upstream.branchName
            } else if remoteShortNames.contains("origin/\(row.branchName)") {
                remote = "origin"
                remoteBranch = row.branchName
            } else {
                continue
            }

            do {
                if let observation = try reflog.observation(
                    commonDirectory: commonDirectory,
                    remote: remote,
                    branch: remoteBranch) {
                    observations[row.branchName] = observation
                }
            } catch {
                let file = ReflogFileReader.reflogPath(
                    commonDirectory: commonDirectory, remote: remote, branch: remoteBranch)
                errors.append(RepoError(stage: .reflog, message: "\(file): \(Self.describe(error))"))
            }
        }

        // Stage 7 — PRs, and only if asked. PLAN.md §3: `gh` runs when the repo is expanded or in
        // the 5 most recently active, and the cache exists "for latency, not quota".
        var pr = PRStage()
        var entry: PRCacheEntry? = cachedPRs
        let cacheIsFresh = cachedPRs.map { now.timeIntervalSince($0.fetchedAt) < policy.prCacheTTL } ?? false

        if let cachedPRs, cacheIsFresh {
            // `prCacheWithinTTLIssuesNoGhCalls`: a warm entry answers outright. The heads that
            // fetch asked about are carried in the entry, so a branch it asked about and found
            // nothing for still reads `none`; a branch it never asked about still reads
            // `notChecked`. Serving a fetched answer while forgetting what was fetched would
            // downgrade every `none` to `notChecked` the moment the cache went warm.
            pr.pullRequests = cachedPRs.prs
            pr.authored = cachedPRs.authorPRs
            pr.fetchedAt = cachedPRs.fetchedAt
            // `queriedHeads` are the heads a `--head` query asked about, which answers for every
            // owner; the recent-100 list is re-read out of `prs` and answers only for the owners
            // it named (codex round 2, MAJOR 4).
            pr.coverage = PRQueryCoverage(anyOwnerHeads: Set(cachedPRs.queriedHeads))
            for entry in cachedPRs.prs { pr.coverage.record(entry) }
            pr.loadState = .loaded
        } else if wantsPullRequests {
            await runPullRequestStage(
                into: &pr,
                errors: &errors,
                branchRefs: branchRefs,
                remoteURL: remoteURL,
                slug: slug,
                remoteOwners: remoteOwners,
                now: now)
            // Only a fetch that reached the recent-100 list is worth keeping; a failed one would
            // cache a blank answer as if GitHub had given it.
            if let fetchedAt = pr.fetchedAt {
                entry = PRCacheEntry(
                    fetchedAt: fetchedAt,
                    prs: pr.pullRequests,
                    authorPRs: pr.authored,
                    queriedHeads: pr.coverage.anyOwnerHeads.sorted())
            }
        } else if let cachedPRs {
            // Not eager, and the entry is past its TTL: show what was last known rather than
            // blanking the pills, and say it is stale.
            pr.pullRequests = cachedPRs.prs
            pr.authored = cachedPRs.authorPRs
            pr.fetchedAt = cachedPRs.fetchedAt
            pr.loadState = .stale
        }

        var repo = RepoAssembler.assemble(RepoAssembler.Inputs(
            id: discovered.id,
            path: path,
            remoteURL: remoteURL,
            branchRefs: branchRefs,
            remoteRefs: remoteRefs,
            worktrees: worktrees,
            worktreesEnumerated: worktreesEnumerated,
            fetchHeadObservedAt: fetchHeadObservedAt,
            pushObservations: observations,
            pullRequests: pr.pullRequests,
            authoredOpenPullRequests: pr.authored,
            queryCoverage: pr.coverage,
            remoteOwners: remoteOwners,
            prAvailability: pr.availability,
            prFetchedAt: pr.fetchedAt,
            prLoadState: pr.loadState,
            errors: errors,
            isStale: false,
            refreshedAt: now))

        // The lookup above resolved these to key the PR match; the shell needs the same answer to
        // say which repository a row was counted against, and rebuilding it from the PRs that
        // happened to match gets a branch tracking a fork with no PR wrong every time (F11).
        repo.remoteOwners = remoteOwners

        return LoadResult(repo: repo, prCache: entry)
    }

    // MARK: - The `gh` stage

    /// What the PR stage produced, gathered in one value so `load` reads as seven stages rather
    /// than seven mutable locals.
    private struct PRStage {
        var pullRequests: [PRInfo] = []
        var authored: [PRInfo] = []
        var coverage = PRQueryCoverage()
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
        remoteOwners: [String: String],
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
            // One (owner, head) pair per PR, not one head name: the list answered for the heads it
            // named and for nobody else's (codex round 2, MAJOR 4).
            for entry in recent { pr.coverage.record(entry) }
        }

        // The per-head fallback, capped per repo per refresh by `GHClient`. The cap is spent
        // most-recently-active first, because that is where a live PR is: branches past it render
        // `notChecked`, never `none` (`unqueriedBranchIsNotCheckedNeverNone`).
        let coverage = pr.coverage
        let unmatched = branchRefs
            .filter { $0.refName.hasPrefix("refs/heads/") }
            .sorted { $0.committerDate > $1.committerDate }
            .filter { row in
                let upstream = ForEachRefParser.upstream(from: row)
                let owner = RepoAssembler.upstreamOwnerLogin(
                    upstream: upstream, slug: slug, remoteOwners: remoteOwners)
                let claimed = (upstream != nil && owner == nil) ? nil : (owner ?? slug.owner)
                return !coverage.covers(headRefName: row.branchName, ownerLogin: claimed)
            }
            .map(\.branchName)

        if !unmatched.isEmpty {
            for (head, prs) in await gh.pullRequests(slug: slug, unmatchedHeads: unmatched) {
                // `--head <name>` filters on the head branch and not on its owner, so it answers
                // for every owner of that head.
                pr.coverage.recordAnyOwner(head: head)
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

    /// Distinct `%(upstream:remotename)` values across the `refs/heads` rows, in first-seen order.
    /// One lookup per remote, however many branches track it.
    static func upstreamRemoteNames(of branchRefs: [ParsedBranchRef]) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for row in branchRefs where row.refName.hasPrefix("refs/heads/") {
            guard let remote = ForEachRefParser.upstream(from: row)?.remote, !remote.isEmpty else { continue }
            if seen.insert(remote).inserted { names.append(remote) }
        }
        return names
    }

    /// `git -C <path> config --get remote.<name>.url`, the same invocation `GitClient` runs for
    /// origin, in the same frozen shape and environment. An unset key is nil and not an error, as
    /// it is for origin; the URL is sanitized before it can reach a log or the cache, because an
    /// HTTPS remote can carry a token as its user info (codex MAJOR 1).
    private func configuredRemoteURL(forRemote name: String, at path: String) async throws -> String? {
        guard let runner, let gitPath else { return nil }
        let output = try await runner.run(GitClient.command(
            gitPath: gitPath,
            arguments: ["config", "--get", "remote.\(name).url"],
            at: path,
            timeout: policy.gitTimeout))
        let url = output.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty {
            // Exit 1 with nothing on stdout is "the key is unset"; anything else is a failure.
            if output.exitCode != 0 && output.exitCode != 1 {
                throw CommandError.nonZeroExit(
                    exitCode: output.exitCode,
                    standardError: output.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }
        guard output.exitCode == 0 else {
            throw CommandError.nonZeroExit(
                exitCode: output.exitCode,
                standardError: output.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return GitClient.sanitize(remoteURL: url)
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
            // Packet F3 / codex MAJOR 15: the one line this file needs for the new seam case.
            case .outputTooLarge(let stream, let limit):
                return "\(stream.rawValue) exceeded \(limit / (1024 * 1024)) MB and the child was terminated"
            // Packet F6 / codex round 2, MINOR 2: a pipe read that failed partway is not a short
            // answer; the partial output is discarded and this is what the log says instead.
            case .readFailed(let stream, let message):
                return "could not read \(stream.rawValue): \(message)"
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
        case .forbidden(let repo): name = "forbidden(\(repo))"
        case .timedOut: name = "timedOut"
        case .commandFailed: name = "commandFailed"
        }
        guard let detail, !detail.isEmpty else { return name }
        return "\(name): \(detail)"
    }
}
