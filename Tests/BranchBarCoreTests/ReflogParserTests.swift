import Foundation
import Testing

@testable import BranchBarCore

/// Acceptance tests for `ReflogParser`, packet 2.1, written from the frozen contract (PLAN.md §5
/// invocation, §7 named invariants, and the OWNER comments on the stub) by an agent that does not
/// write the implementation.
///
/// The secondary fallback:
///
/// ```
/// git reflog show --date=unix --format='%gd%x1f%gs%x1f%H' refs/remotes/<upstream>
/// ```
///
/// Two frozen footguns: the separator atom is `%x1f`, because `%1f` is a `for-each-ref` atom that
/// `reflog show` prints literally, and the invocation carries **no** `--`, because `reflog show`
/// silently returns zero rows and exit 0 when one is present.
@Suite("ReflogParser — the `git reflog show` fallback")
struct ReflogParserTests {

    private static let zeroOID = String(repeating: "0", count: 40)

    private static func entry(_ unixTime: Int, _ message: String, _ oid: String,
                              ref: String = "origin/main") -> ReflogShowEntry {
        ReflogShowEntry(selector: "\(ref)@{\(unixTime)}", message: message, objectName: oid)
    }

    // MARK: Splitting

    /// PLAN.md §7. Rows split on U+001F, one control character, and never on the four literal
    /// characters `%1f`: a parser that split on the text would return one field per row and a
    /// selector with the whole line in it.
    @Test("reflogFieldsSplitOnUnitSeparatorNotLiteralPercent1f")
    func reflogFieldsSplitOnUnitSeparatorNotLiteralPercent1f() throws {
        let output = Fixture.text("recorded-branchbar-reflog-show-origin-main.txt")
        #expect(!output.contains("%1f"), "the recorded fixture holds real separators, not the atom's text")
        #expect(!output.contains("%x1f"))

        let entries = try ReflogParser.parse(output)
        #expect(entries.count == 4, "the recorded fixture holds four rows")

        let newest = try #require(entries.first)
        #expect(newest.selector == "origin/main@{1788317856}", "field 1 is %gd, whole, braces included")
        #expect(newest.message == "update by push", "field 2 is %gs")
        #expect(newest.objectName == "9c866eb0614a34c48edd29a4cb3cdf0358a1ac69", "field 3 is %H")

        #expect(entries.allSatisfy { !$0.selector.contains("\u{1F}") }, "no field may still hold a separator")
        #expect(entries.allSatisfy { !$0.message.contains("%") }, "a format atom must never survive into a field")
        #expect(entries.allSatisfy { $0.objectName.count == 40 })

        // `reflog show` prints newest first, and the parser preserves git's order.
        #expect(entries.map(\.selector) == [
            "origin/main@{1788317856}",
            "origin/main@{1788317853}",
            "origin/main@{1788316926}",
            "origin/main@{1788316077}",
        ])

        // Three fields is the contract; anything else is a thrown error, never a trap.
        #expect(throws: (any Error).self) {
            _ = try ReflogParser.parse("origin/main@{1788317856}\u{1F}update by push\n")
        }
    }

    // MARK: The observation

    /// `%gd` under `--date=unix` is `origin/main@{<unixtime>}`; the timestamp lives **inside the
    /// braces**, and nothing else on the row carries a date.
    @Test("reflogShowTimestampParsedFromUnixSelector")
    func reflogShowTimestampParsedFromUnixSelector() throws {
        let entries = try ReflogParser.parse(
            Fixture.text("recorded-branchbar-reflog-show-origin-main.txt"))
        let observation = try #require(ReflogParser.observation(from: entries))

        #expect(observation.pushedAt == Date(timeIntervalSince1970: 1_788_317_856),
                "read from between the braces of origin/main@{1788317856}")
        #expect(observation.newOID == "9c866eb0614a34c48edd29a4cb3cdf0358a1ac69")

        // A ref whose own name carries slashes and digits still yields the timestamp in braces.
        let nested = [Self.entry(1_788_100_000, "update by push",
                                 String(repeating: "e", count: 40),
                                 ref: "origin/feature/2026-09")]
        let nestedObservation = try #require(ReflogParser.observation(from: nested))
        #expect(nestedObservation.pushedAt == Date(timeIntervalSince1970: 1_788_100_000))
    }

    /// `reflog show` prints newest first, so the first `update by push` in the list is the newest
    /// one — and non-push rows above it (a fetch, a branch update) are skipped rather than
    /// reported with their own dates.
    @Test("reflogShowNewestUpdateByPushWins")
    func reflogShowNewestUpdateByPushWins() throws {
        let entries = [
            Self.entry(1_788_400_000, "fetch origin: fast-forward", String(repeating: "f", count: 40)),
            Self.entry(1_788_317_856, "update by push", "9c866eb0614a34c48edd29a4cb3cdf0358a1ac69"),
            Self.entry(1_788_317_853, "update by push", "6f3dc4f4bee55283be83172ed686d64b95319a15"),
        ]

        let observation = try #require(ReflogParser.observation(from: entries))
        #expect(observation.pushedAt == Date(timeIntervalSince1970: 1_788_317_856),
                "the newest push, not the newest row and not the oldest push")
        #expect(observation.newOID == "9c866eb0614a34c48edd29a4cb3cdf0358a1ac69")

        // Fetch-only history is no observation at all, the same as the file reader's answer.
        let fetchesOnly = [
            Self.entry(1_788_400_000, "fetch origin: fast-forward", String(repeating: "f", count: 40)),
            Self.entry(1_788_300_000, "pull: fast-forward", String(repeating: "e", count: 40)),
        ]
        #expect(ReflogParser.observation(from: fetchesOnly) == nil)
        #expect(ReflogParser.observation(from: []) == nil)
    }

    /// The same deletion-boundary rule the file reader applies: `git push --delete` leaves a row
    /// whose OID is all zeros and whose message still says `update by push`. Above it, nothing;
    /// below it, a branch that no longer exists.
    @Test("deletionBoundaryStopsTheReflogShowWalk")
    func deletionBoundaryStopsTheReflogShowWalk() throws {
        let deletionNewest = [
            Self.entry(1_788_400_000, "update by push", Self.zeroOID),
            Self.entry(1_788_300_000, "update by push", String(repeating: "b", count: 40)),
        ]
        #expect(ReflogParser.observation(from: deletionNewest) == nil,
                "an all-zero OID is a deletion, and the walk stops there")

        // Push, deletion, then a push of a new incarnation: the recreated branch's own push wins,
        // and the pre-deletion push is never attributed to it.
        let recreated = [
            Self.entry(1_788_500_000, "update by push", String(repeating: "d", count: 40)),
            Self.entry(1_788_400_000, "update by push", Self.zeroOID),
            Self.entry(1_788_300_000, "update by push", String(repeating: "a", count: 40)),
        ]
        let observation = try #require(ReflogParser.observation(from: recreated))
        #expect(observation.pushedAt == Date(timeIntervalSince1970: 1_788_500_000))
        #expect(observation.newOID == String(repeating: "d", count: 40))
        #expect(observation.newOID != String(repeating: "a", count: 40))
    }

    // MARK: Every recorded fixture

    /// PLAN.md §3: recorded fixtures are ground truth from `/usr/bin/git` 2.39.5 run with the
    /// frozen format and no `--`. Every one must parse to three fields per row and reduce to an
    /// observation the file reader would agree with.
    @Test("everyRecordedFixtureParsesWithoutError")
    func everyRecordedFixtureParsesWithoutError() throws {
        let names = Fixture.allNames().filter {
            $0.hasPrefix("recorded-") && $0.contains("-reflog-show-") && $0.hasSuffix(".txt")
        }
        #expect(names.count >= 2, "the inventory records reflog show for two repos")

        for name in names {
            let entries = try ReflogParser.parse(Fixture.text(name))
            #expect(!entries.isEmpty, "\(name) parsed to no rows")
            #expect(entries.allSatisfy { $0.selector.contains("@{") && $0.selector.hasSuffix("}") },
                    "\(name) yielded a selector without a unix-time brace")
            #expect(entries.allSatisfy { $0.objectName.count == 40 }, "\(name) yielded a malformed OID")

            let observation = try #require(ReflogParser.observation(from: entries),
                                           "\(name) holds push rows but reduced to no observation")
            #expect(observation.pushedAt.timeIntervalSince1970 > 1_700_000_000)
            #expect(observation.newOID == entries.first(where: { $0.message.hasPrefix("update by push") })?.objectName,
                    "\(name) did not report its newest push row")
        }
    }
}
