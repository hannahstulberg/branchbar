import Foundation

/// The only place a user-facing string is produced. PLAN.md §3: "Strings are code" — every
/// literal lives in `Strings.swift` (packet 4.0) and this type assembles them, so a wording
/// invariant such as `observedPushLabelSaysFromThisMacNeverYouPushed` is a unit test over a
/// value rather than a screenshot review.
///
/// It renders `Branch.group` and never recomputes it; grouping belongs to `RepoAssembler`.
// depends on Strings.swift (packet 4.0)
public struct SnapshotPresenter: Sendable {
    public init() {}

    /// OWNER: packet 2.2 — turn a `Snapshot` into a `SnapshotVM`: one `RepoSectionVM` per repo in
    /// the snapshot's order with its four groups filled from `Branch.group`, a `prNotice` naming
    /// the one action for the repo's `PRAvailability` or the not-loaded / not-checked wording, a
    /// `notScannedNotice` carrying the unreadable folders and the skipped-categories summary from
    /// `scanResult`, per-row push copy that says "Pushed from this Mac" for a reflog observation
    /// and "Last push unknown · newest commit dated …" for the tip-date fallback, and a
    /// `FooterVM` with the relative updated label, the version, the scan roots, and any tool
    /// notice; and an `EmptyStateVM` instead of sections when there are no repos.
    public func present(
        _ snapshot: Snapshot,
        refreshState: RefreshState,
        collapsedRepoIDs: Set<RepoID>,
        scanResult: ScanResult?,
        appVersion: String,
        now: Date
    ) -> SnapshotVM {
        fatalError("OWNER: packet 2.2 — render a Snapshot into a SnapshotVM using Strings.swift, four groups per repo from Branch.group, honest push wording, notices per PRAvailability, and a footer.")
    }
}
