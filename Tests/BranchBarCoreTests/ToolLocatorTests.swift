import Foundation
import Testing

@testable import BranchBarCore

/// `ToolLocator` exists because a GUI-launched app does not inherit the user's shell PATH
/// (PLAN.md §5, §9 "gh not found from GUI PATH"). Every case below drives the locator through
/// injected closures, so nothing here touches the real filesystem or `xcode-select`.

/// Convenience: a locator whose only executables are the paths in `present`.
private func locator(
    path: String,
    home: String = "/Users/tester",
    commandLineTools: Bool = true,
    overrides: [String: String] = [:],
    present: Set<String>
) -> ToolLocator {
    var environment = overrides
    environment["PATH"] = path
    return ToolLocator(
        environment: environment,
        homeDirectory: home,
        commandLineToolsPresent: { commandLineTools },
        isExecutable: { present.contains($0) }
    )
}

@Test("Homebrew gh wins over a gh that is also on PATH")
func prefersHomebrewGhOverPath() {
    let found = locator(
        path: "/Users/tester/bin:/usr/bin:/bin",
        present: ["/opt/homebrew/bin/gh", "/Users/tester/bin/gh"]
    ).locate(.gh)

    #expect(found.path == "/opt/homebrew/bin/gh")
    // Searching stops at the first hit, so the diagnostic list is short when gh is found.
    #expect(found.searched == ["/opt/homebrew/bin/gh"])
}

@Test("An explicit BRANCHBAR_GH override outranks Homebrew")
func environmentOverrideOutranksEverything() {
    let found = locator(
        path: "/usr/bin",
        overrides: ["BRANCHBAR_GH": "/tmp/fake/gh"],
        present: ["/tmp/fake/gh", "/opt/homebrew/bin/gh"]
    ).locate(.gh)

    #expect(found.path == "/tmp/fake/gh")
    #expect(found.searched.first == "/tmp/fake/gh")
}

@Test("gh absent: nil path plus the full ordered list of everywhere it looked")
func returnsNilAndSearchedListWhenGhAbsent() {
    // PATH repeats /opt/homebrew/bin on purpose: the searched list is deduped, because it is
    // shown to a user who is trying to work out where to install gh.
    let found = locator(
        path: "/opt/homebrew/bin:/usr/bin:/bin",
        present: []
    ).locate(.gh)

    #expect(found.path == nil)
    #expect(
        found.searched == [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/Users/tester/.local/bin/gh",
            "/opt/local/bin/gh",
            // /usr/bin/gh only because PATH names /usr/bin. The Command Line Tools rule below
            // is a git-only fallback and never adds /usr/bin/gh on its own.
            "/usr/bin/gh",
            "/bin/gh",
        ]
    )
}

@Test("/usr/bin/git is only a fallback when xcode-select resolves")
func usrBinGitIgnoredWhenCommandLineToolsMissing() {
    // /usr/bin is deliberately not on PATH, so /usr/bin/git can only be reached by the
    // Command Line Tools fallback.
    let withoutCLT = locator(
        path: "/nowhere",
        commandLineTools: false,
        present: ["/usr/bin/git"]
    ).locate(.git)

    #expect(withoutCLT.path == nil)
    #expect(withoutCLT.searched.contains("/usr/bin/git") == false)

    let withCLT = locator(
        path: "/nowhere",
        commandLineTools: true,
        present: ["/usr/bin/git"]
    ).locate(.git)

    #expect(withCLT.path == "/usr/bin/git")
    #expect(withCLT.searched.last == "/usr/bin/git")
}
