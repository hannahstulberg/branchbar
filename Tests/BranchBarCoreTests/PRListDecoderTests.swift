import Foundation
import Testing

@testable import BranchBarCore

// Acceptance tests for the pure decoder over `gh pr list --json …` stdout, written before the
// implementation. Two shapes are frozen by PLAN.md §2 against gh 2.89 and easy to get wrong from
// memory: `headRepositoryOwner` is an object, so the model carries `.login`; `reviewDecision` is
// `""` rather than null when undecided.

/// The one date format `gh` writes: RFC 3339 in UTC, no fractional seconds. Built per call
/// because `ISO8601DateFormatter` is not `Sendable` and Core is compiled in Swift 6 mode.
private func iso(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
}

@Suite("PRListDecoder decodes what gh writes, in the order the UI needs")
struct PRListDecoderTests {

    /// PLAN.md §5 sorts client-side: `gh` returns rows in its own order, and the fixture is
    /// deliberately unsorted, so a decoder that passes the array through fails here.
    @Test("prListDecoderSortsByUpdatedAtDescendingRegardlessOfInputOrder")
    func prListDecoderSortsByUpdatedAtDescendingRegardlessOfInputOrder() throws {
        let data = Fixture.data("synthetic-gh-pr-list-mixed.json")
        let asWritten = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(asWritten.compactMap { $0["number"] as? Int } == [101, 102, 103, 104, 105, 106, 107, 108, 109, 110],
                "the fixture is in gh's order, not updatedAt order")

        let decoded = try PRListDecoder.decode(data)

        #expect(decoded.map(\.number) == [110, 105, 109, 103, 102, 101, 104, 106, 107, 108])
        let dates = decoded.map(\.updatedAt)
        #expect(zip(dates, dates.dropFirst()).allSatisfy { $0 >= $1 }, "newest updatedAt first, throughout")
    }

    /// The two footguns CLAUDE.md records: the owner is an object and `mergeCommit` is an object
    /// or null. The model flattens both.
    @Test("decoderFlattensHeadRepositoryOwnerLoginAndMergeCommitOid")
    func decoderFlattensHeadRepositoryOwnerLoginAndMergeCommitOid() throws {
        let decoded = try PRListDecoder.decode(Fixture.data("synthetic-gh-pr-list-mixed.json"))

        let merged = try #require(decoded.first { $0.number == 106 })
        #expect(merged.mergeCommitOid == "9999999999999999999999999999999999999999")
        #expect(merged.headRepositoryOwnerLogin == "tester")

        let openDraft = try #require(decoded.first { $0.number == 101 })
        #expect(openDraft.mergeCommitOid == nil, "a null mergeCommit is nil, not an empty string")
        #expect(openDraft.isDraft)
    }

    @Test("decoderParsesISO8601DatesForMergedAtAndUpdatedAt")
    func decoderParsesISO8601DatesForMergedAtAndUpdatedAt() throws {
        let decoded = try PRListDecoder.decode(Fixture.data("synthetic-gh-pr-list-mixed.json"))
        let merged = try #require(decoded.first { $0.number == 106 })

        let expected = try #require(iso("2026-08-15T09:00:00Z"))
        #expect(merged.mergedAt == expected)
        #expect(merged.updatedAt == expected)

        let closedUnmerged = try #require(decoded.first { $0.number == 107 })
        #expect(closedUnmerged.mergedAt == nil, "a closed unmerged PR has no mergedAt")
    }

    /// PLAN.md §5: `reviewDecision` is an empty string when undecided, and the decoder must carry
    /// it through as written — the emptiness is the signal `PRStatusMapper` reads.
    @Test("emptyReviewDecisionStringSurvivesDecodingAsAnEmptyString")
    func emptyReviewDecisionStringSurvivesDecodingAsAnEmptyString() throws {
        let decoded = try PRListDecoder.decode(Fixture.data("synthetic-gh-pr-list-mixed.json"))

        let undecided = try #require(decoded.first { $0.number == 103 })
        let pending = try #require(decoded.first { $0.number == 102 })
        let approved = try #require(decoded.first { $0.number == 105 })
        let changes = try #require(decoded.first { $0.number == 104 })

        #expect(undecided.reviewDecision == "")
        #expect(pending.reviewDecision == "REVIEW_REQUIRED")
        #expect(approved.reviewDecision == "APPROVED")
        #expect(changes.reviewDecision == "CHANGES_REQUESTED")
    }

    /// A fork PR is a normal row to the decoder. Dropping it here would make
    /// `forkOriginatedPRStillMatchesItsLocalBranch` unwinnable downstream.
    @Test("forkOriginatedPRSurvivesDecodingWithItsOwnHeadOwner")
    func forkOriginatedPRSurvivesDecodingWithItsOwnHeadOwner() throws {
        let decoded = try PRListDecoder.decode(Fixture.data("synthetic-gh-pr-list-mixed.json"))
        let fork = try #require(decoded.first { $0.number == 110 })

        #expect(fork.headRepositoryOwnerLogin == "contributor")
        #expect(fork.headRefName == "fork-feature")
        #expect(decoded.count == 10, "no row is filtered out by the decoder")
    }

    @Test("emptyArrayDecodesToAnEmptyListNeverAnError")
    func emptyArrayDecodesToAnEmptyListNeverAnError() throws {
        #expect(try PRListDecoder.decode(Fixture.data("synthetic-gh-pr-list-empty.json")).isEmpty)
        #expect(try PRListDecoder.decode(
            Fixture.data("recorded-gh-pr-list-author-me-hannah-personal-agent.json")).isEmpty)
    }

    /// The recorded list from a real repo: 17 rows, every `reviewDecision` empty, one closed PR
    /// with a null `mergeCommit`.
    @Test("recordedGhListDecodesEveryRowWithTheShapeGhWrites")
    func recordedGhListDecodesEveryRowWithTheShapeGhWrites() throws {
        let decoded = try PRListDecoder.decode(Fixture.data("recorded-gh-pr-list-hannah-personal-agent.json"))

        #expect(decoded.count == 17)
        #expect(decoded.allSatisfy { $0.reviewDecision == "" })
        #expect(decoded.allSatisfy { $0.headRepositoryOwnerLogin == "hannahstulberg" })
        #expect(decoded.first?.number == 17, "sorted by updatedAt descending, the newest is PR 17")
        let closed = try #require(decoded.first { $0.number == 1 })
        #expect(closed.state == "CLOSED")
        #expect(closed.mergeCommitOid == nil)
        #expect(decoded.contains { $0.headRefName == "allison-bachelorette-itinerary-pdf" })
    }

    /// Backs `malformedJSONIsCommandFailed`: the decoder throws, so `GHClient` has something to
    /// classify instead of returning a partial list as the truth.
    @Test("malformedJSONThrowsRatherThanReturningPartialRows")
    func malformedJSONThrowsRatherThanReturningPartialRows() {
        #expect(throws: (any Error).self) {
            _ = try PRListDecoder.decode(Fixture.data("synthetic-gh-pr-list-malformed.json"))
        }
    }
}
