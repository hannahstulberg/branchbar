import Foundation

/// Pure decoder over `gh pr list --json …` stdout.
///
/// Two shapes are frozen by PLAN.md §2 and verified against gh 2.89: `headRepositoryOwner` is an
/// object (`{id, login, name}`), so the model flattens it to `.login`; `reviewDecision` is `""`
/// rather than null when undecided, so an empty string is not a decision.
public enum PRListDecoder {

    /// OWNER: packet 2.2 — decode the JSON array into `[PRInfo]`, flattening
    /// `headRepositoryOwner.login` and `mergeCommit.oid`, parsing `mergedAt` and `updatedAt` as
    /// ISO-8601, and returning the rows sorted by `updatedAt` descending regardless of input
    /// order; an empty array decodes to an empty list, never an error.
    public static func decode(_ data: Data) throws -> [PRInfo] {
        fatalError("OWNER: packet 2.2 — decode `gh pr list --json` output into [PRInfo] sorted by updatedAt descending, flattening headRepositoryOwner.login and mergeCommit.oid.")
    }
}
