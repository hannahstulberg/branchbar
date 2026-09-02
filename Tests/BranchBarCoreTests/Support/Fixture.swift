import Foundation
import Testing

/// Loads a file from `Tests/BranchBarCoreTests/Fixtures/`.
///
/// PLAN.md §5b forbids a `resources:` declaration in `Package.swift` (it breaks the `.app`
/// layout), so fixtures resolve from `#filePath` instead of `Bundle.module`. The guard test
/// `everyFixtureReferencedByATestExists` greps every `Fixture.text("…")` and `Fixture.data("…")`
/// literal in the test sources, so a name typed here that was never recorded fails once, up
/// front, instead of deep inside a parser suite.
public enum Fixture {

    /// `Tests/BranchBarCoreTests/Fixtures/`.
    public static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Support
        .deletingLastPathComponent()   // BranchBarCoreTests
        .appendingPathComponent("Fixtures", isDirectory: true)

    public static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: false)
    }

    /// Contents as UTF-8 text, byte for byte as recorded — no trimming, because a trailing
    /// newline and an empty file are two different fixtures here.
    public static func text(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) -> String {
        String(decoding: data(name, sourceLocation: sourceLocation), as: UTF8.self)
    }

    public static func data(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) -> Data {
        guard let data = FileManager.default.contents(atPath: url(name).path) else {
            Issue.record(
                "fixture \(name) not found at \(url(name).path); run `make record-fixtures` or add the synthetic file",
                sourceLocation: sourceLocation
            )
            return Data()
        }
        return data
    }

    /// Every fixture on disk, for inventory assertions.
    public static func allNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.sorted() ?? []
    }
}
