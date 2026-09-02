import BranchBarCore
import Foundation

/// Whether a path a row is about to hand to another program is, at this instant, a real directory.
///
/// codex round 3, BLOCKER 1. Every row action takes a path that came from a repository or from
/// `cache.json`, and neither is trusted input: a crafted `.git/worktrees` record can report
/// `/tmp/payload.command` as a branch's worktree, and a tampered cache can carry the same path
/// straight into the row before any refresh has revalidated it. The editor chain's last step is
/// `open -a Terminal <path>`, and Terminal *executes* a `.command` document — that behaviour is
/// what the `gh` sign-in action deliberately relies on — so a row whose payload was a regular file
/// used to be one click from running it.
///
/// The decision belongs to Core: `FileSystem.isDirectoryNoFollow` is the same check
/// `SnapshotPresenter` uses to decide whether a row gets an action at all, and asking it here is
/// what keeps the click and the row agreeing. `O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK |
/// O_CLOEXEC` is its shape: `O_DIRECTORY` refuses a regular file, a FIFO, a socket, or a device in
/// `open()` itself; `O_NOFOLLOW` refuses a symlink, because a row points at a folder rather than at
/// a forwarding address whose target can be swapped; `O_NONBLOCK` keeps a FIFO at that path from
/// parking the call in the kernel, which nothing above it could then end (ARCHITECTURE.md §8).
///
/// What this file adds is the *reason*, which a `Bool` cannot carry and a log line needs. The
/// refusal path opens once more purely to read `errno`, so nothing that decides anything lives
/// here twice.
///
/// The answer is asked at click time rather than taken from the model, because the model is
/// exactly what may be lying. A path that passes and is replaced a microsecond later is a race
/// `open -a` cannot close; what this removes is the case where the row was always a file and
/// nobody looked.
enum ActionPaths {

    /// Why a path was refused, in the words the log line uses. `.directory` is the only verdict an
    /// action proceeds on.
    enum Verdict: Equatable {
        case directory
        case refused(String)

        var isDirectory: Bool { self == .directory }
    }

    static func isDirectory(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        return RealFileSystem().isDirectoryNoFollow(atPath: path)
    }

    /// Answers only for absolute paths: every payload the presenter builds is absolute, and a
    /// relative one would be resolved against a working directory this app never set.
    static func verdict(for path: String) -> Verdict {
        guard path.hasPrefix("/") else { return .refused("not an absolute path") }
        guard !isDirectory(path) else { return .directory }
        return .refused(reasonItIsNotADirectory(path))
    }

    /// The same `open` Core just made, kept only long enough to name why it failed. A path that
    /// has become a directory between the two calls is reported as the ordinary refusal it was.
    private static func reasonItIsNotADirectory(_ path: String) -> String {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor < 0 else {
            close(descriptor)
            return "it was not a folder a moment ago"
        }
        let code = errno
        return "\(String(cString: strerror(code))) (errno \(code))"
    }

    /// The form every action uses: true when the action may go ahead, and one log line naming the
    /// action, the path, and the reason when it may not.
    static func allows(_ path: String, action: String) -> Bool {
        switch verdict(for: path) {
        case .directory:
            return true
        case .refused(let reason):
            Log.info("action: \(action) refused, \(path) is not a folder BranchBar will open (\(reason))")
            return false
        }
    }
}
