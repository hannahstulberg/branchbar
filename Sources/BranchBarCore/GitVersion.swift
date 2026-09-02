import Foundation

/// The version `git --version` printed, parsed into something comparable.
///
/// PLAN.md §5: `ToolLocator` "records `git --version`; below 2.39 → tool notice". 2.39 is the
/// floor because that is what `/usr/bin/git` reports on a stock managed Mac (PLAN.md §1, "what
/// NYT will have") and every frozen invocation in §5 was recorded against it. Parsing lives in
/// its own type rather than inside `ToolLocator` so the comparison is numeric — `2.9` is older
/// than `2.39`, which string comparison gets backwards — and so the probe stays testable
/// without running git.
public struct GitVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// What git printed after `git version `, verbatim — `2.39.5 (Apple Git-154)`. This is the
    /// string `ToolStatus.gitVersion` carries and the tool notice shows, because "Apple Git-154"
    /// is the part that tells someone which git they actually have.
    public let raw: String

    public init(major: Int, minor: Int, patch: Int, raw: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.raw = raw ?? "\(major).\(minor).\(patch)"
    }

    /// PLAN.md §5. Below this, the app shows the "git older than 2.39" notice from §5a item 1.
    public static let minimumSupported = GitVersion(major: 2, minor: 39, patch: 0)

    public var isBelowMinimumSupported: Bool { self < Self.minimumSupported }

    public var description: String { "\(major).\(minor).\(patch)" }

    /// Parses `git version 2.39.5 (Apple Git-154)`, `git version 2.52.0`, and the bare
    /// `2.39.5` form. Anything without at least `major.minor` is nil rather than a guess: a
    /// missing git prints an `xcrun:` error on the same channel, and treating that as version 0
    /// would raise the wrong notice.
    public static func parse(_ output: String) -> GitVersion? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "git version ", options: [.caseInsensitive, .anchored]) {
            text = String(text[range.upperBound...])
        }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = raw.split(separator: " ").first else { return nil }

        // `2.43.0.windows.1` parses on its leading numeric components and stops at `windows`.
        var numbers: [Int] = []
        for component in first.split(separator: ".", omittingEmptySubsequences: false) {
            guard let value = Int(component), value >= 0 else { break }
            numbers.append(value)
            if numbers.count == 3 { break }
        }
        guard numbers.count >= 2 else { return nil }

        return GitVersion(
            major: numbers[0],
            minor: numbers[1],
            patch: numbers.count > 2 ? numbers[2] : 0,
            raw: raw
        )
    }

    /// The one invocation this type reads, so a caller does not invent its own argument list.
    /// `ToolLocator` (packet 0.3) owns running it and putting the result in `ToolStatus`.
    public static func probeCommand(gitPath: String, timeout: TimeInterval = 10) -> Command {
        Command(
            executable: gitPath,
            arguments: ["--version"],
            environment: GitClient.frozenEnvironment,
            timeout: timeout
        )
    }

    /// Equality and ordering are about the version, not the string git wrapped it in, so two
    /// builds that report 2.39.5 compare equal whatever their vendor suffix says.
    public static func == (lhs: GitVersion, rhs: GitVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) == (rhs.major, rhs.minor, rhs.patch)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
    }

    public static func < (lhs: GitVersion, rhs: GitVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
