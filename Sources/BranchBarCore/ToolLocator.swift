import Foundation

/// Which external binary is being looked for. `git` and `gh` are the only two BranchBar runs
/// (PLAN.md §5), and only `git` has the Command Line Tools fallback.
public enum Tool: String, Sendable, Hashable, CaseIterable {
    case git
    case gh

    /// The file name searched for inside each candidate directory.
    public var executableName: String { rawValue }

    /// An explicit escape hatch, checked before every directory. Also how Gate 3 pins the
    /// harness to `/usr/bin/git`.
    public var overrideEnvironmentKey: String {
        switch self {
        case .git: return "BRANCHBAR_GIT"
        case .gh: return "BRANCHBAR_GH"
        }
    }
}

/// The result of one lookup: where the tool is, and every path that was inspected getting there.
///
/// `searched` is a user-facing diagnostic, not a debug aid — when `path` is `nil` the app shows
/// the list so someone can see that BranchBar looked in `/opt/homebrew/bin` and the tool is not
/// there. Searching stops at the first hit, so a successful lookup carries a short list.
public struct ToolLocation: Sendable, Hashable {
    public let tool: Tool
    public let path: String?
    public let searched: [String]

    public init(tool: Tool, path: String?, searched: [String]) {
        self.tool = tool
        self.path = path
        self.searched = searched
    }

    public var isFound: Bool { path != nil }
}

/// Finds `git` and `gh` for a process that does not have the user's shell PATH.
///
/// A GUI-launched `.app` inherits launchd's environment, which on a stock Mac is
/// `/usr/bin:/bin:/usr/sbin:/sbin` — Homebrew is not on it, so `gh` is invisible to a naive
/// `Process` launch even though the user's terminal finds it instantly (PLAN.md §9, "gh not
/// found from GUI PATH"). Hence the fixed directory list ahead of PATH.
///
/// Order (PLAN.md §5): `BRANCHBAR_GIT`/`BRANCHBAR_GH` → `/opt/homebrew/bin` → `/usr/local/bin`
/// → `~/.local/bin` → `/opt/local/bin` → each PATH entry in order → `/usr/bin/git`, and only
/// `git`, and only when `xcode-select -p` resolves.
///
/// Every external dependency arrives as an injected closure, so the whole search order is
/// unit-testable without touching the filesystem.
public struct ToolLocator: Sendable {
    /// The `FileSystem.isExecutableFile` seam, narrowed to the one question this type asks.
    public typealias ExecutableCheck = @Sendable (String) -> Bool

    /// Searched in this order, ahead of PATH. `~/.local/bin` is expanded against the injected
    /// home directory rather than `NSHomeDirectory()` so tests can pin it.
    public static let fixedDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "~/.local/bin",
        "/opt/local/bin",
    ]

    private let environment: [String: String]
    private let homeDirectory: String
    private let commandLineToolsPresent: @Sendable () -> Bool
    private let isExecutable: ExecutableCheck

    public init(
        environment: [String: String],
        homeDirectory: String,
        commandLineToolsPresent: @escaping @Sendable () -> Bool,
        isExecutable: @escaping ExecutableCheck
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.commandLineToolsPresent = commandLineToolsPresent
        self.isExecutable = isExecutable
    }

    /// The production locator: real environment, real home, real `xcode-select`, real filesystem.
    public init() {
        self.init(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            commandLineToolsPresent: ToolLocator.xcodeSelectResolves,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }

    public func locate(_ tool: Tool) -> ToolLocation {
        var searched: [String] = []
        var seen: Set<String> = []

        /// Returns the path when it is executable; records it as searched either way.
        func consider(_ path: String) -> String? {
            guard seen.insert(path).inserted else { return nil }
            searched.append(path)
            return isExecutable(path) ? path : nil
        }

        // 1. Explicit override. A broken override falls through rather than failing the lookup,
        //    but it stays in `searched` so the user can see it was tried.
        if let override = environment[tool.overrideEnvironmentKey], !override.isEmpty {
            if let hit = consider(override) {
                return ToolLocation(tool: tool, path: hit, searched: searched)
            }
        }

        // 2. The fixed directories, then 3. PATH in its own order.
        let directories = Self.fixedDirectories.map(expandTilde) + pathDirectories()
        for directory in directories {
            let candidate = (directory as NSString).appendingPathComponent(tool.executableName)
            if let hit = consider(candidate) {
                return ToolLocation(tool: tool, path: hit, searched: searched)
            }
        }

        // 4. `/usr/bin/git` last, and only when the Command Line Tools shim will actually resolve
        //    to a git. Without them `/usr/bin/git` exists but prompts to install Xcode instead of
        //    running, which would look to BranchBar like a git that hangs.
        if tool == .git, commandLineToolsPresent() {
            if let hit = consider("/usr/bin/git") {
                return ToolLocation(tool: tool, path: hit, searched: searched)
            }
        }

        return ToolLocation(tool: tool, path: nil, searched: searched)
    }

    private func expandTilde(_ directory: String) -> String {
        guard directory == "~" || directory.hasPrefix("~/") else { return directory }
        return homeDirectory + String(directory.dropFirst(1))
    }

    private func pathDirectories() -> [String] {
        (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { expandTilde(String($0)) }
    }

    /// `xcode-select -p` exits 0 and prints a developer directory when Command Line Tools (or
    /// Xcode) are installed; it exits non-zero otherwise.
    private static func xcodeSelectResolves() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !output.isEmpty
    }
}
