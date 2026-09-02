import Foundation
import Testing

@testable import BranchBarCore

/// PLAN.md §5: `ToolLocator` "records `git --version`; below 2.39 → tool notice". The version
/// string it records is whatever git printed, so the comparison lives here as a parse of that
/// string rather than as string matching at the call site.
///
/// 2.39 is the floor because that is what `/usr/bin/git` on a stock managed Mac reports
/// (PLAN.md §1: `/usr/bin/git` 2.39.5, "what NYT will have"), and every frozen invocation in
/// §5 was recorded against it.
@Suite("GitVersion parses git --version and flags anything below 2.39")
struct GitVersionTests {

    @Test("gitVersionParsesAppleGitString")
    func gitVersionParsesAppleGitString() throws {
        let version = try #require(GitVersion.parse("git version 2.39.5 (Apple Git-154)"))

        #expect(version.major == 2)
        #expect(version.minor == 39)
        #expect(version.patch == 5)
        // The raw string is what the tool notice and the Snapshot's `ToolStatus.gitVersion` show.
        #expect(version.raw == "2.39.5 (Apple Git-154)")
        #expect(version.description == "2.39.5")
    }

    @Test("Parses the plain Homebrew string, a trailing newline, and a two-component version")
    func parsesOtherRealStrings() throws {
        let homebrew = try #require(GitVersion.parse("git version 2.52.0\n"))
        #expect((homebrew.major, homebrew.minor, homebrew.patch) == (2, 52, 0))
        #expect(homebrew.raw == "2.52.0")

        // Some builds print only two components; the missing patch is 0, not a parse failure.
        let short = try #require(GitVersion.parse("git version 2.30"))
        #expect((short.major, short.minor, short.patch) == (2, 30, 0))

        // A four-component Windows-style string parses on its first three.
        let windows = try #require(GitVersion.parse("git version 2.43.0.windows.1"))
        #expect((windows.major, windows.minor, windows.patch) == (2, 43, 0))
    }

    @Test("Anything that is not a version string is nil rather than a wrong version")
    func unparseableStringsAreNil() {
        #expect(GitVersion.parse("") == nil)
        #expect(GitVersion.parse("xcrun: error: invalid active developer path") == nil)
        #expect(GitVersion.parse("git version") == nil)
        #expect(GitVersion.parse("git version banana") == nil)
    }

    @Test("flagsBelow239")
    func flagsBelow239() throws {
        #expect(GitVersion.minimumSupported == GitVersion(major: 2, minor: 39, patch: 0))

        // Below the floor.
        #expect(try #require(GitVersion.parse("git version 2.38.5")).isBelowMinimumSupported)
        #expect(try #require(GitVersion.parse("git version 2.30")).isBelowMinimumSupported)
        #expect(try #require(GitVersion.parse("git version 1.99.99")).isBelowMinimumSupported)

        // The floor itself, and everything above it.
        #expect(!(try #require(GitVersion.parse("git version 2.39.0")).isBelowMinimumSupported))
        #expect(!(try #require(GitVersion.parse("git version 2.39.5 (Apple Git-154)")).isBelowMinimumSupported))
        #expect(!(try #require(GitVersion.parse("git version 2.52.0")).isBelowMinimumSupported))
        #expect(!(try #require(GitVersion.parse("git version 3.0.0")).isBelowMinimumSupported))
    }

    /// Ordering is numeric, not lexicographic: 2.9 is older than 2.39, which string comparison
    /// gets backwards.
    @Test("Comparison is numeric per component")
    func comparesNumericallyNotLexicographically() throws {
        let old = try #require(GitVersion.parse("git version 2.9.5"))
        let new = try #require(GitVersion.parse("git version 2.39.5"))

        #expect(old < new)
        #expect(old.isBelowMinimumSupported)
        #expect(GitVersion(major: 2, minor: 39, patch: 0) < GitVersion(major: 2, minor: 39, patch: 1))
        #expect(GitVersion(major: 2, minor: 39, patch: 5) == GitVersion(major: 2, minor: 39, patch: 5))
    }

    /// The one frozen invocation this type reads. `ToolLocator` (packet 0.3) owns running it;
    /// this keeps the argument list in one place so a future caller does not invent its own.
    @Test("The probe command is `git --version` with the frozen git environment")
    func probeCommandIsFrozen() {
        let command = GitVersion.probeCommand(gitPath: "/usr/bin/git")

        #expect(command.executable == "/usr/bin/git")
        #expect(command.arguments == ["--version"])
        #expect(command.environment == GitClient.frozenEnvironment)
        #expect(command.displayString == "git --version")
    }
}
