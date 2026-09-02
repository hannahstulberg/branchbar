import Foundation

/// Every git invocation PLAN.md §5 freezes, and nothing else. Owns the environment
/// (`LC_ALL=C`, `GIT_OPTIONAL_LOCKS=0`) and the `-C <repo>` form, and hands raw stdout to the
/// pure parsers so the parsers stay testable without a process.
public struct GitClient: Sendable {
    private let runner: CommandRunner
    private let gitPath: String
    private let timeout: TimeInterval

    /// PLAN.md §5. `LC_ALL=C` keeps the output parseable; `GIT_OPTIONAL_LOCKS=0` stops a read
    /// from taking `index.lock` while the user is mid-commit in another tool;
    /// `GIT_NO_LAZY_FETCH=1` stops a partial clone from reaching the network behind a read that
    /// is contracted never to fetch, and stops the fetch helper that read would spawn from
    /// outliving cancellation (codex MAJOR 13, the git half).
    public static let frozenEnvironment: [String: String] = [
        "LC_ALL": "C",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_NO_LAZY_FETCH": "1",
    ]

    /// The seven `for-each-ref` atoms of the refs/heads format, in the frozen order. `%1f` is the
    /// for-each-ref atom for U+001F; `reflog show` needs `%x1f` instead, which is why the two
    /// formats do not share a constant.
    static let headsFormat =
        "--format=%(refname)%1f%(objectname)%1f%(committerdate:unix)%1f%(upstream:short)%1f%(upstream:remotename)%1f%(upstream:track,nobracket)%1f%(HEAD)"
    static let remotesFormat = "--format=%(refname)%1f%(objectname)%1f%(committerdate:unix)"
    static let reflogFormat = "--format=%gd%x1f%gs%x1f%H"

    /// `gitPath` is resolved outside this type; the GUI PATH has no Homebrew.
    // depends on ToolLocator (packet 0.3)
    public init(runner: CommandRunner, gitPath: String, timeout: TimeInterval = RefreshPolicy.default.gitTimeout) {
        self.runner = runner
        self.gitPath = gitPath
        self.timeout = timeout
    }

    /// Run `git -C <path> rev-parse --path-format=absolute --git-common-dir --show-toplevel` and
    /// return the two absolute paths it prints, in that order. Without `--path-format=absolute`
    /// git prints a relative common dir and the reflog path breaks.
    public func identity(at path: String) async throws -> (commonDirectory: String, topLevel: String) {
        let output = try await run(
            ["rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel"], at: path)
        let lines = Self.lines(output)
        guard lines.count >= 2 else {
            throw CommandError.nonZeroExit(
                exitCode: output.exitCode,
                standardError: "rev-parse printed \(lines.count) path(s), expected 2")
        }
        return (commonDirectory: lines[0], topLevel: lines[1])
    }

    /// Run `git -C <path> config --get remote.origin.url`. An unset key is git exit 1 with empty
    /// stdout, which is `PRUnavailableReason.noRemote` — an answer, not a command failure.
    ///
    /// The URL is sanitized here, before it can reach `Repo.remoteURL`, `cache.json`, or a log
    /// line: an HTTPS remote can carry a personal access token as its user info, and PLAN.md §6
    /// promises BranchBar stores no secret (codex MAJOR 1).
    public func remoteOriginURL(at path: String) async throws -> String? {
        let command = Self.command(gitPath: gitPath, arguments: ["config", "--get", "remote.origin.url"],
                                   at: path, timeout: timeout)
        let output = try await runner.run(command)
        let url = output.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)

        if url.isEmpty {
            // Exit 1 with nothing on stdout is "the key is unset"; any other non-zero exit is a
            // real failure and still throws.
            if output.exitCode != 0 && output.exitCode != 1 { try Self.check(output) }
            return nil
        }
        try Self.check(output)
        return Self.sanitize(remoteURL: url)
    }

    /// Strips user info, query, and fragment from a remote URL, leaving the part that identifies
    /// the repository. Both remote shapes git writes are handled: `scheme://[user[:pass]@]host…`
    /// and the scp-like `[user@]host:owner/name`.
    ///
    /// All user info goes, not only a `user:password` pair, because a GitHub token is written as
    /// bare user info (`https://<token>@github.com/o/r.git`) and is indistinguishable from a
    /// username by shape. Nothing renders `Repo.remoteURL`, so the loss is invisible to the user
    /// and `GitHubSlug` parses the sanitized form identically.
    static func sanitize(remoteURL: String) -> String {
        var url = remoteURL
        // A query or fragment is never part of a git remote's identity and is where a token
        // arrives in `?access_token=…` style URLs.
        if let cut = url.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            url = String(url[url.startIndex..<cut])
        }

        if let schemeRange = url.range(of: "://") {
            let head = String(url[url.startIndex..<schemeRange.upperBound])
            let rest = String(url[schemeRange.upperBound...])
            let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
            let authority = String(rest[rest.startIndex..<authorityEnd])
            guard let at = authority.lastIndex(of: "@") else { return url }
            let stripped = String(authority[authority.index(after: at)...])
            return head + stripped + String(rest[authorityEnd...])
        }

        // scp-like: everything before the first colon is `[user@]host`.
        guard !url.hasPrefix("/"), let colon = url.firstIndex(of: ":") else { return url }
        let authority = String(url[url.startIndex..<colon])
        guard let at = authority.lastIndex(of: "@") else { return url }
        return String(authority[authority.index(after: at)...]) + String(url[colon...])
    }

    /// The frozen `for-each-ref … -- refs/heads` invocation. `--` is used here because git was
    /// verified to accept it on `for-each-ref`, and nowhere else.
    public func branchRefs(at path: String) async throws -> [ParsedBranchRef] {
        let output = try await run(["for-each-ref", Self.headsFormat, "--", "refs/heads"], at: path)
        return try ForEachRefParser.parseBranches(output.standardOutputText)
    }

    /// The frozen `for-each-ref … -- refs/remotes/` invocation; the trailing slash is part of the
    /// frozen pattern.
    public func remoteRefs(at path: String) async throws -> [ParsedRemoteRef] {
        let output = try await run(["for-each-ref", Self.remotesFormat, "--", "refs/remotes/"], at: path)
        return try ForEachRefParser.parseRemoteRefs(output.standardOutputText)
    }

    /// `git -C <path> worktree list --porcelain -z` — NUL-delimited, no separator.
    ///
    /// `-z` is not a preference. Without it git 2.39.5 prints a worktree path containing a newline
    /// raw, so one record splits into several, the whole stage throws, and the repo loses every
    /// worktree it has — which quietly moves a checked-out merged branch into the Merged group
    /// (codex MAJOR 12). The stdout goes to the parser as bytes, because a path is bytes.
    public func worktrees(at path: String) async throws -> [Worktree] {
        let output = try await run(["worktree", "list", "--porcelain", "-z"], at: path)
        return try WorktreeListParser.parse(output.standardOutput)
    }

    /// `git -C <path> reflog show --date=unix --format=%gd%x1f%gs%x1f%H <ref>` with **no** `--`
    /// separator: with one, git returns zero rows and exit 0 on 2.39.5 and 2.52, so every branch
    /// would silently read "never pushed". Empty stdout with exit 0 is an empty list, not an error.
    public func reflogShow(at path: String, ref: String) async throws -> [ReflogShowEntry] {
        let output = try await run(["reflog", "show", "--date=unix", Self.reflogFormat, ref], at: path)
        return try ReflogParser.parse(output.standardOutputText)
    }

    // MARK: The frozen shape

    /// `-C <repo>` leads every invocation, the repo is the working directory, the environment is
    /// exactly the frozen two, and the timeout is PLAN.md §5's 10 s for git.
    static func command(gitPath: String, arguments: [String], at path: String, timeout: TimeInterval) -> Command {
        Command(
            executable: gitPath,
            arguments: ["-C", path] + arguments,
            workingDirectory: path,
            environment: frozenEnvironment,
            timeout: timeout
        )
    }

    private func run(_ arguments: [String], at path: String) async throws -> CommandOutput {
        let output = try await runner.run(
            Self.command(gitPath: gitPath, arguments: arguments, at: path, timeout: timeout))
        try Self.check(output)
        return output
    }

    private static func check(_ output: CommandOutput) throws {
        guard output.exitCode != 0 else { return }
        throw CommandError.nonZeroExit(
            exitCode: output.exitCode,
            standardError: output.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func lines(_ output: CommandOutput) -> [String] {
        output.standardOutputText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
