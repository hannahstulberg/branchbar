import Foundation
import Testing

@testable import BranchBarCore

// codex BLOCKER 1 / REVIEW CR-01. The `gh` sign-in action writes an executable `.command` file and
// hands it to `open -a Terminal`, so that file is the one place in BranchBar where a string becomes
// shell source. `SignInScript.render(ghPath:)` is that file's whole body, and it is fixed text: the
// only variable the script reads is a hostname, taken from a sibling `gh-sign-in.host` file and
// re-checked in zsh against the same grammar `GitHubSlug.isValidHostname` enforces in Swift.
//
// It lives in Core rather than in `Actions.swift` so the script can be rendered and *executed* in a
// test — the shell half of the fix is the half that has to be proven, and the app target is not
// testable under Swift Testing on Command Line Tools.

@Suite("The gh sign-in script never carries a host into shell source")
struct SignInScriptTests {

    // MARK: - The rendered text

    @Test("The script interpolates no hostname anywhere in its body")
    func scriptCarriesNoInterpolatedHost() {
        let script = SignInScript.render(ghPath: "/opt/homebrew/bin/gh")
        #expect(!script.contains("github.com"))
        #expect(!script.contains("--hostname github"))
        // The host arrives as one argv element read from a file, never as script text.
        #expect(script.contains(SignInScript.hostFileName))
        #expect(script.contains("--hostname \"$host\""))
    }

    @Test("The script re-validates the hostname in zsh against the same grammar")
    func scriptCarriesTheRegexGuard() {
        let script = SignInScript.render(ghPath: "/opt/homebrew/bin/gh")
        #expect(script.contains("'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$'"))
    }

    @Test("The resolved gh path is a single-quoted literal, not bare script text")
    func ghPathIsQuoted() {
        let script = SignInScript.render(ghPath: "/opt/homebrew/bin/gh")
        #expect(script.contains("gh='/opt/homebrew/bin/gh'"))
        #expect(script.contains("exec \"$gh\" auth login --hostname \"$host\""))
    }

    @Test("A gh path holding a quote is escaped rather than closing the literal")
    func ghPathWithAQuoteIsEscaped() {
        let script = SignInScript.render(ghPath: "/tmp/g'h")
        #expect(script.contains("gh='/tmp/g'\\''h'"))
    }

    // MARK: - Running it

    /// `$(touch …)` in the host file is the codex blocker's own payload. The script must exit
    /// non-zero, run no `gh`, and leave no file behind.
    @Test("A hostile hostname file exits non-zero and executes nothing")
    func hostileHostFileIsRefused() throws {
        let harness = try ScriptHarness()
        defer { harness.tearDown() }

        let pwned = harness.directory.appendingPathComponent("pwned").path
        try harness.writeHostFile("$(touch \(pwned))")

        let result = harness.run()
        #expect(result.status != 0, "the script accepted a hostname that is shell syntax")
        #expect(!FileManager.default.fileExists(atPath: pwned), "the host file's command substitution ran")
        #expect(harness.ghArgv() == nil, "gh ran for a hostname that is not a hostname")
    }

    @Test("Every shell metacharacter in the host file is refused", arguments: [
        "github.com;id",
        "github.com && id",
        "`id`",
        "a b.com",
        "-leading.com",
        "github..com",
        "",
    ])
    func hostileHostnamesAreRefused(_ host: String) throws {
        let harness = try ScriptHarness()
        defer { harness.tearDown() }
        try harness.writeHostFile(host)

        #expect(harness.run().status != 0, "\(host) was accepted")
        #expect(harness.ghArgv() == nil, "gh ran for \(host)")
    }

    @Test("A missing host file exits non-zero rather than signing in to nothing")
    func missingHostFileIsRefused() throws {
        let harness = try ScriptHarness()
        defer { harness.tearDown() }

        #expect(harness.run().status != 0)
        #expect(harness.ghArgv() == nil)
    }

    /// The other half: a real hostname reaches `gh` as exactly one argv element.
    @Test("A valid hostname reaches gh as one argument", arguments: ["github.com", "github.nytimes.com"])
    func validHostnameReachesGhAsOneArgument(_ host: String) throws {
        let harness = try ScriptHarness()
        defer { harness.tearDown() }
        try harness.writeHostFile(host)

        let result = harness.run()
        #expect(result.status == 0, "the script refused \(host): \(result.output)")
        #expect(harness.ghArgv() == ["auth", "login", "--hostname", host])
    }

    // MARK: - Harness

    /// A temp directory holding the rendered script, its host file, and a fake `gh` that writes its
    /// own argv one line per element, so "one argv element" is observable rather than asserted.
    private struct ScriptHarness {
        let directory: URL
        let scriptURL: URL
        let ghURL: URL
        let argvURL: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("branchbar-signin-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            scriptURL = directory.appendingPathComponent(SignInScript.scriptFileName)
            ghURL = directory.appendingPathComponent("fake-gh")
            argvURL = directory.appendingPathComponent("argv")

            let shim = """
                #!/bin/zsh
                printf '%s\\n' "$@" > \(argvURL.path)

                """
            try shim.write(to: ghURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ghURL.path)

            try SignInScript.render(ghPath: ghURL.path)
                .write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        }

        func writeHostFile(_ contents: String) throws {
            try (contents + "\n").write(
                to: directory.appendingPathComponent(SignInScript.hostFileName),
                atomically: true,
                encoding: .utf8)
        }

        func run() -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return (-1, "could not run zsh: \(error)")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }

        /// The argv the fake `gh` saw, or nil when it never ran.
        func ghArgv() -> [String]? {
            guard let text = try? String(contentsOf: argvURL, encoding: .utf8) else { return nil }
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .dropLast()
                .map(String.init)
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
