import Foundation
import Testing

// Structural guards from PLAN.md §7. They read the source tree off disk rather than the
// built module, so they catch an import the compiler is happy with. Paths resolve from
// `#filePath` because PLAN.md §5b forbids a `resources:` declaration in Package.swift.

/// `<repo root>` derived from this file: Tests/BranchBarCoreTests/GuardTests.swift.
enum RepoRoot {
    static let url: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // BranchBarCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // <repo root>

    static var path: String { url.path }

    /// Every `.swift` file under `<repo root>/<relative>`, sorted for stable failure output.
    static func swiftFiles(under relative: String) -> [URL] {
        let base = url.appendingPathComponent(relative, isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }
}

@Suite("Structural guards over the source tree")
struct GuardTests {

    // PLAN.md §4: "BranchBarCore (library, no AppKit/SwiftUI, fully tested)".
    // Core has to stay usable from `branchbar-cli` (packet 3.2), which is the Gate 0b fallback.
    @Test("noAppKitOrSwiftUIImportInCore")
    func noAppKitOrSwiftUIImportInCore() throws {
        let banned = ["AppKit", "SwiftUI", "Cocoa"]
        var offenders: [String] = []

        for file in RepoRoot.swiftFiles(under: "Sources/BranchBarCore") {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let module = trimmed.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
                if banned.contains(module) {
                    offenders.append("\(file.lastPathComponent):\(index + 1): import \(module)")
                }
            }
        }

        #expect(offenders.isEmpty, "BranchBarCore must not import AppKit or SwiftUI: \(offenders)")
    }

    // PLAN.md §5b: "Tests: Swift Testing only ... `import XCTest` banned (grep test)."
    // XCTest is absent under Command Line Tools, so an XCTest import compiles only on a
    // machine with full Xcode (CI job A) and then fails on Hannah's machine and job B.
    @Test("noXCTestImportAnywhere")
    func noXCTestImportAnywhere() throws {
        var offenders: [String] = []

        for relative in ["Sources", "Tests"] {
            for file in RepoRoot.swiftFiles(under: relative) {
                let source = try String(contentsOf: file, encoding: .utf8)
                for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed == "import XCTest" || trimmed.hasPrefix("import XCTest ") {
                        offenders.append("\(relative)/\(file.lastPathComponent):\(index + 1)")
                    }
                }
            }
        }

        #expect(offenders.isEmpty, "XCTest is banned; Swift Testing only: \(offenders)")
    }

    // PLAN.md §3: "Fixtures are recorded, not transcribed." A test that names a fixture which
    // was never recorded fails at `Fixture.text` with a runtime error deep inside a parser suite;
    // this fails once, up front, naming every missing file.
    @Test("everyFixtureReferencedByATestExists")
    func everyFixtureReferencedByATestExists() throws {
        let fixturesDirectory = RepoRoot.url
            .appendingPathComponent("Tests/BranchBarCoreTests/Fixtures", isDirectory: true)

        var referenced: Set<String> = []
        for file in RepoRoot.swiftFiles(under: "Tests") {
            // The guard itself names no fixture; skipping it keeps the regex literals below
            // from being read back as references.
            if file.lastPathComponent == "GuardTests.swift" { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            referenced.formUnion(Self.fixtureNames(in: source))
        }

        let missing = referenced
            .filter { !FileManager.default.fileExists(atPath: fixturesDirectory.appendingPathComponent($0).path) }
            .sorted()

        #expect(missing.isEmpty, "tests reference fixtures that do not exist: \(missing)")
    }

    /// Literal arguments of the fixture loader's two entry points, ignoring `//` comment lines
    /// so a doc comment that shows the call shape is not read back as a reference.
    static func fixtureNames(in source: String) -> [String] {
        let code = source
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        let pattern = #"Fixture\.(?:text|data)\(\s*"([^"]+)"\s*[,)]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: code) else { return nil }
            return String(code[r])
        }
    }
}
