import Foundation
import Testing

@testable import BranchBarCore

// Packet F6 — codex round 2, MAJOR 10 and MINOR 4.
//
// A repository owns its own directory name, its branch names, and its paths, and both of the
// app's plain-text outputs printed them verbatim: `branchbar-cli`'s table and the file log. A
// directory called `main\n[2026-01-01T00:00:00.000Z] everything is fine` forges a log entry; one
// carrying ESC forges table rows, erases output already printed, or retitles the terminal.
//
// JSON keeps exact values, because that is what a machine reads. Everything a human reads goes
// through `SafeText`, and the log file is capped so a machine that refreshes all day cannot fill
// a disk with it.

@Suite("Repository-controlled text cannot forge a line a human reads")
struct SafeTextTests {

    /// Every C0 scalar, DEL, and every C1 scalar is escaped; ordinary text, including non-ASCII
    /// and emoji, is untouched.
    @Test("escapingControlScalarsLeavesOrdinaryTextAlone")
    func escapingLeavesOrdinaryTextAlone() {
        for text in ["main", "feature/nested name", "café-ünïcode", "repo 🌱", "a-b_c.d"] {
            #expect(SafeText.escapingControlScalars(text) == text)
        }
    }

    @Test("escapingControlScalarsEscapesC0C1AndESC")
    func escapingEscapesControls() {
        #expect(SafeText.escapingControlScalars("a\nb") == "a\\nb")
        #expect(SafeText.escapingControlScalars("a\rb") == "a\\rb")
        #expect(SafeText.escapingControlScalars("a\tb") == "a\\tb")
        #expect(SafeText.escapingControlScalars("a\u{1b}[2Jb") == "a\\u{1B}[2Jb")
        #expect(SafeText.escapingControlScalars("a\u{0}b") == "a\\u{00}b")
        #expect(SafeText.escapingControlScalars("a\u{7f}b") == "a\\u{7F}b")
        // C1: `\u{9b}` is a one-scalar CSI, which some terminals honour exactly like ESC-[.
        #expect(SafeText.escapingControlScalars("a\u{9b}2Jb") == "a\\u{9B}2Jb")

        // The escape is total: nothing that survives is a control scalar.
        let hostile = "\u{1b}]0;pwned\u{7}\n\r\u{9b}"
        #expect(SafeText.escapingControlScalars(hostile).unicodeScalars.allSatisfy {
            !SafeText.isControlScalar($0)
        })
    }

    /// codex MAJOR 10. The table is the CLI's human-readable output, so a cell holding a newline
    /// must not become two rows and a cell holding ESC must not reach the terminal.
    @Test("cliTableEscapesControlCharacters")
    func cliTableEscapesControlCharacters() {
        let rendered = SafeText.table(
            header: ["REPO", "BRANCH"],
            rows: [
                ["evil\n dotfiles  main  —  —  —", "main"],
                ["quiet", "\u{1b}[2K\u{1b}[1Gforged"],
            ])

        let lines = rendered.components(separatedBy: "\n")
        // Header, rule, two rows — and not one line more, whatever the cells contain.
        #expect(lines.count == 4, "a cell forged \(lines.count - 4) extra row(s)")
        // The row separators are the renderer's own newlines; nothing inside a line is a control.
        //
        // The bidi isolates the renderer itself adds are the one exception, and they arrived with
        // the rule they belong to (codex round 3, MINOR 4): each cell is wrapped in FSI…PDI so a
        // right-to-left name cannot reorder the cells beside it, and those two scalars are
        // `isControlScalar` precisely so a *cell* can never carry one of its own.
        for line in lines {
            #expect(!line.unicodeScalars.contains {
                SafeText.isControlScalar($0) && !SafeText.isBidiControlScalar($0)
            }, "a control scalar reached the terminal in: \(line.debugDescription)")
        }
        #expect(rendered.contains("evil\\n dotfiles"))
        #expect(rendered.contains("\\u{1B}[2K"))

        // Columns still line up on the escaped width, so the table stays readable.
        #expect(lines[0].hasPrefix("REPO"))
        #expect(lines[1].hasPrefix("----"))
    }

    /// MINOR 4. The log's own grammar is "one line per entry, starting with a timestamp", so a
    /// message carrying a newline used to be able to write an entry of its own.
    @Test("logLineWithNewlineCannotForgeAnEntry")
    func logLineWithNewlineCannotForgeAnEntry() {
        let hostile = "scan finished\n[2026-01-01T00:00:00.000Z] launch at login enabled"
        let line = Log.line(hostile, at: Date(timeIntervalSince1970: 1_788_400_000))

        #expect(line.hasSuffix("\n"))
        #expect(line.dropLast().components(separatedBy: "\n").count == 1,
                "a message forged a second entry: \(line)")
        #expect(line.contains("scan finished\\n[2026-01-01"))
        #expect(line.hasPrefix("["))
    }

    /// MINOR 4, the other half: the file "grows without limit". A menu-bar app that refreshes all
    /// day writes forever, so past the cap the oldest bytes go and the newest survive.
    @Test("logFileIsCappedByKeepingItsNewestBytes")
    func logFileIsCapped() throws {
        let temp = try Packet25TempDir()
        defer { temp.remove() }
        let file = temp.file("BranchBar.log")

        // Under the cap: untouched, byte for byte.
        let small = Data(String(repeating: "a", count: 1024).utf8)
        try small.write(to: file)
        Log.capIfNeeded(at: file)
        #expect(try Data(contentsOf: file) == small)

        // Over the cap: only the tail survives, and it is the *end* of what was there.
        var big = Data(repeating: 0x61, count: Log.maximumFileBytes + 4096)
        big.replaceSubrange((big.count - 6)..<big.count, with: Data("NEWEST".utf8))
        try big.write(to: file)
        Log.capIfNeeded(at: file)

        let kept = try Data(contentsOf: file)
        #expect(kept.count <= Log.retainedFileBytes)
        #expect(kept.count > 0)
        #expect(String(decoding: kept.suffix(6), as: UTF8.self) == "NEWEST")
    }
}

// MARK: - Packet F13 — codex round 3, MINOR 4

/// codex round 3, MINOR 4: "`SafeText` escapes C0/C1 controls but leaves Unicode bidi controls
/// intact." A hostile branch or folder name carrying U+202E can make the text printed after it
/// read backwards, which is a row saying something other than what the bytes say — in output whose
/// whole job is to be believed.
@Suite("Bidi formatting cannot reorder a CLI table or a log line")
struct SafeTextBidiTests {

    private static let override = "\u{202E}"
    private static let isolate = "\u{2066}"

    @Test("bidiControlsAreEscapedLikeEveryOtherControlScalar")
    func bidiControlsAreEscapedLikeEveryOtherControlScalar() {
        let hostile = "main\(Self.override)gnp.txt"
        let escaped = SafeText.escapingControlScalars(hostile)

        #expect(escaped == "main\\u{202E}gnp.txt")
        #expect(!escaped.unicodeScalars.contains { SafeText.isBidiControlScalar($0) })

        // All nine scalars, the five embeddings/overrides and the four isolates.
        for value in [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069] {
            let scalar = Unicode.Scalar(UInt32(value))!
            #expect(SafeText.isBidiControlScalar(scalar))
            #expect(SafeText.isControlScalar(scalar))
            #expect(!SafeText.escapingControlScalars(String(scalar)).unicodeScalars.contains(scalar))
        }

        // Ordinary non-ASCII text is untouched: the rule is about formatting scalars, not about
        // scripts.
        #expect(SafeText.escapingControlScalars("café — ✅") == "café — ✅")
    }

    /// Escaping stops a cell from carrying a control. It does not stop a cell whose text is
    /// genuinely right-to-left from reordering the cells beside it, which is the same lie by
    /// another route, so each displayed cell is wrapped in FSI…PDI.
    @Test("everyDisplayedCellIsIsolated")
    func everyDisplayedCellIsIsolated() {
        let rendered = SafeText.table(
            header: ["REPO", "BRANCH"],
            rows: [["مشروع", "main"], ["plain", "ascii"]])

        let lines = rendered.components(separatedBy: "\n")
        #expect(lines.count == 4)
        #expect(lines[2].hasPrefix(SafeText.isolatePrefix), "a right-to-left cell was printed unisolated")
        #expect(lines[2].contains(SafeText.isolateSuffix))
        // An all-ASCII row is unchanged, so every byte-for-byte expectation elsewhere still holds.
        #expect(lines[3].hasPrefix("plain"))
        #expect(!lines[3].unicodeScalars.contains { SafeText.isBidiControlScalar($0) })
        // The rule line is the renderer's own and needs no isolate.
        #expect(lines[1].hasPrefix("-"))

        // Columns are still measured on the escaped text, so the two zero-width scalars do not
        // each eat a space of padding.
        #expect(SafeText.table(header: ["A", "B"], rows: [["مش", "x"], ["abcd", "y"]])
            .components(separatedBy: "\n")[3].hasPrefix("abcd  y"))

        #expect(SafeText.displayCell("main\(Self.override)x")
                == "main\\u{202E}x", "an escaped cell is pure ASCII and needs no isolate")
        #expect(SafeText.displayCell("مشروع") == SafeText.isolatePrefix + "مشروع" + SafeText.isolateSuffix)
    }

    /// The log has the same grammar problem: one entry per line, and a name that reorders the text
    /// after it can make an entry read as something else.
    @Test("logLinesEscapeBidiControlsToo")
    func logLinesEscapeBidiControlsToo() {
        let line = Log.line("scanned \(Self.override)repo\(Self.isolate)", at: Date(timeIntervalSince1970: 0))
        #expect(!line.unicodeScalars.contains { SafeText.isBidiControlScalar($0) })
        #expect(line.contains("\\u{202E}"))
        #expect(line.contains("\\u{2066}"))
    }
}
