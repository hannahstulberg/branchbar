import Foundation

/// Pure parser over `git worktree list --porcelain -z` stdout.
///
/// Fields are NUL-terminated and a record ends with an empty field, so the input is
/// `line \0 line \0 … \0` per record. Each field is `key` or `key value`. Keys seen in the
/// wild: `worktree`, `HEAD`, `branch`, `bare`, `detached`, `locked` (optionally with a reason),
/// `prunable` (optionally with a reason). Paths can contain spaces, so only the first space
/// separates key from value — and they can contain newlines and tabs, which is why the input is
/// `Data` split on NUL rather than a `String` split on "\n" (codex MAJOR 12).
public enum WorktreeListParser {

    /// A record the porcelain cannot have produced. Recoverable, like the for-each-ref errors:
    /// `RepoLoader` reports it as a `RepoError(stage: .worktrees)`.
    public enum ParseError: Error, Hashable, Sendable, CustomStringConvertible {
        case recordWithoutWorktreePath(record: String)

        public var description: String {
            switch self {
            case let .recordWithoutWorktreePath(record):
                return "worktree porcelain record carries no `worktree` line: \(record)"
            }
        }
    }

    /// Parse the porcelain into one `Worktree` per record. The first record git prints is the
    /// primary worktree; `detached` and `bare` records carry no branch, so the join rules
    /// (PLAN.md §5) can never attach them to a branch row.
    ///
    /// The split is on the NUL byte and nothing else: a field's own bytes — a newline in a path, a
    /// tab in a branch name — cannot end it, which is the whole reason the invocation carries
    /// `-z`. Each field is decoded as UTF-8 afterwards, so a path git wrote is reproduced verbatim.
    public static func parse(_ output: Data) throws -> [Worktree] {
        var worktrees: [Worktree] = []
        var record: [String] = []

        func flush() throws {
            defer { record = [] }
            guard !record.isEmpty else { return }
            worktrees.append(try worktree(from: record, isPrimary: worktrees.isEmpty))
        }

        // `split(separator:omittingEmptySubsequences: false)` keeps the empty field that ends a
        // record, which is the only record boundary `-z` prints.
        for field in output.split(separator: 0, omittingEmptySubsequences: false) {
            let line = String(decoding: field, as: UTF8.self)
            if line.isEmpty {
                try flush()
            } else {
                record.append(line)
            }
        }
        try flush()

        return worktrees
    }

    private static func worktree(from record: [String], isPrimary: Bool) throws -> Worktree {
        var path: String?
        var headSHA = ""
        var branch: String?
        var isBare = false
        var isLocked = false
        var lockReason: String?
        var isPrunable = false

        for line in record {
            let (key, value) = split(line)
            switch key {
            case "worktree":
                path = value
            case "HEAD":
                headSHA = value ?? ""
            case "branch":
                branch = value
            case "bare":
                isBare = true
            case "detached":
                // A detached checkout names no branch; the row reads "at commit abc1234 (no branch)".
                branch = nil
            case "locked":
                isLocked = true
                lockReason = value
            case "prunable":
                isPrunable = true
            default:
                continue
            }
        }

        guard let path else {
            throw ParseError.recordWithoutWorktreePath(record: record.joined(separator: "\n"))
        }

        return Worktree(
            path: path,
            headSHA: headSHA,
            branch: branch,
            isPrimary: isPrimary,
            isBare: isBare,
            isLocked: isLocked,
            lockReason: lockReason,
            isPrunable: isPrunable
        )
    }

    /// Only the **first** space separates key from value, because paths and branch names carry
    /// spaces (`pathWithSpacesParses`). A bare key has no value at all, which is how `locked`
    /// with a reason and `locked` without one stay distinguishable.
    private static func split(_ line: String) -> (key: String, value: String?) {
        guard let space = line.firstIndex(of: " ") else { return (line, nil) }
        let value = String(line[line.index(after: space)...])
        return (String(line[line.startIndex..<space]), value.isEmpty ? nil : value)
    }
}
