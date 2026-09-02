import Foundation

/// Pure decoder over `gh pr list --json …` stdout.
///
/// Two shapes are frozen by PLAN.md §2 and verified against gh 2.89: `headRepositoryOwner` is an
/// object (`{id, login, name}`), so the model flattens it to `.login`; `reviewDecision` is `""`
/// rather than null when undecided, so an empty string is not a decision.
public enum PRListDecoder {

    /// One row exactly as `gh` writes it, before the two objects are flattened.
    private struct Row: Decodable {
        struct Owner: Decodable { var login: String }
        struct MergeCommit: Decodable { var oid: String }

        var number: Int
        var url: String
        var state: String
        var isDraft: Bool
        /// `gh` writes `""`, never null, when nothing has been decided.
        var reviewDecision: String?
        var mergedAt: Date?
        var updatedAt: Date
        var baseRefName: String
        var headRefName: String
        var headRefOid: String
        /// Null once the head repository is deleted; the login is then unknown, not a login of "".
        var headRepositoryOwner: Owner?
        var mergeCommit: MergeCommit?
    }

    /// RFC 3339 in UTC, which is the one shape `gh` prints. Fractional seconds are accepted too
    /// so a future gh that starts printing them does not turn a whole repo into `commandFailed`.
    private static func date(from text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// Decodes the JSON array into `[PRInfo]`, flattening `headRepositoryOwner.login` and
    /// `mergeCommit.oid`, parsing `mergedAt` and `updatedAt` as ISO-8601, and returning the rows
    /// sorted by `updatedAt` descending regardless of input order; an empty array decodes to an
    /// empty list, never an error.
    public static func decode(_ data: Data) throws -> [PRInfo] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { inner in
            let text = try inner.singleValueContainer().decode(String.self)
            guard let parsed = Self.date(from: text) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: inner.codingPath,
                        debugDescription: "not an ISO-8601 timestamp: \(text)"
                    )
                )
            }
            return parsed
        }

        let rows = try decoder.decode([Row].self, from: data)

        return rows
            .map { row in
                PRInfo(
                    number: row.number,
                    url: row.url,
                    state: row.state,
                    isDraft: row.isDraft,
                    reviewDecision: row.reviewDecision ?? "",
                    mergedAt: row.mergedAt,
                    updatedAt: row.updatedAt,
                    baseRefName: row.baseRefName,
                    headRefName: row.headRefName,
                    headRefOid: row.headRefOid,
                    headRepositoryOwnerLogin: row.headRepositoryOwner?.login ?? "",
                    mergeCommitOid: row.mergeCommit?.oid
                )
            }
            // Newest first. The PR number breaks a tie so the order is total and the same on
            // every run — `Array.sorted` is not a stable sort.
            .sorted { left, right in
                if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
                return left.number > right.number
            }
    }
}
