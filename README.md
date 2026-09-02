# BranchBar

A small macOS menu bar app that shows every repo on your Mac, the branches and worktrees inside each one, whether each branch has a pull request open, and when each branch last went out to GitHub.

## Who made this and what it does with your Mac

BranchBar was written by Hannah Stulberg for the Claude Code workshop, and all of its source code is public at [github.com/hannahstulberg/branchbar](https://github.com/hannahstulberg/branchbar). It stores no passwords and no tokens: everything it knows about GitHub comes from the GitHub CLI you already signed in to, and it only reads what that tool prints back. It runs two programs and no others, `git` and `gh`, and it never changes anything in your repos. It makes no connections of its own to anywhere, so the only traffic it causes is the GitHub CLI answering its own questions. What it keeps on disk is a list of the repos it found and the last thing it showed you, in `~/Library/Application Support/BranchBar/`.

## Install

Takes about five minutes. You do not need an admin password.

1. Download `BranchBar-<version>-mac.zip` from the [latest release](https://github.com/hannahstulberg/branchbar/releases/latest).
2. Double-click the zip. A file called **BranchBar** appears.
3. Drag **BranchBar** into your **Applications** folder.
4. Double-click **BranchBar** in Applications.
5. A box appears saying macOS could not verify BranchBar. Click **Done** with the mouse.
   **Do not press Return.** The highlighted button is **Move to Trash**, so Return deletes the app.

   `<SCREENSHOT: the "BranchBar" Not Opened box, with the Done and Move to Trash buttons visible>`
6. Open **System Settings**, then **Privacy & Security**, and scroll down. There is a line saying BranchBar was blocked, with an **Open Anyway** button. Click it, click **Open Anyway** again in the box that follows, and enter your Mac password if you are asked for it.

   `<SCREENSHOT: the Privacy & Security pane showing the BranchBar line and the Open Anyway button>`
7. Look at the top right of your screen, near the clock. A small branch-shaped icon appears. Click it.

   `<SCREENSHOT: the BranchBar icon in the menu bar>`
8. macOS asks whether BranchBar may look in folders like Desktop, Documents, and Downloads. Click **Allow** for each one. Saying no is fine and nothing breaks: those folders show up in the list as **Not scanned**, with an **Allow access** button that asks again whenever you want.

   `<SCREENSHOT: the macOS folder access box for Documents>`
9. The first look through your home folder takes a few seconds. After that BranchBar remembers what it found and only checks again when you ask.

**Updates ask for folder access again.** Every build is signed fresh, and macOS treats a freshly signed copy as a new app, so after you replace BranchBar with a newer version it asks about your folders once more. Click **Allow** again, or use the **Allow access** button in the list.

## Requirements

- macOS 13 or newer.
- `git`. Apple's copy is enough. If you have never installed it, run `xcode-select --install`.
- The GitHub CLI, signed in. Run `gh auth login` in Terminal once and pick GitHub.com. Without it, BranchBar still shows repos, branches, worktrees, and pushes; only the pull request labels are missing, and the app says so in place of them.
- A GitHub token set only in a shell startup file, such as `GH_TOKEN` in `.zshrc`, does not work. An app opened from the Finder never sees it. Sign in with `gh auth login` instead, which stores the sign-in where the app can reach it.

## What it shows

Click the icon and you get one section per repo, most recently worked in first. Inside a repo there are up to four groups.

- **Branches and worktrees.** Everything you have on this Mac, with a marker on the ones checked out in a worktree folder.
- **Open PRs not on this Mac.** Your own open pull requests whose branch is not on this computer, for the work you left on your laptop.
- **Merged.** Branches whose pull request was merged with no newer commits of yours on top.
- **Closed without merging.** Branches whose pull request was closed, which may still hold work that never landed.

Each branch line says when it last went out. The wording is exact on purpose, because the app can only report what this Mac saw.

- **"Pushed from this Mac 2 days ago"** means this computer watched that push leave. Pushes you made from another computer are invisible here, and the line will not claim otherwise.
- **"Last push unknown, newest commit dated 2 days ago"** means there is no record of the branch going out from this Mac, so what you are reading is the date of the newest commit instead.
- **"Never pushed from this Mac"** means the branch has no matching branch on GitHub yet.

**Last-known origin** appears wherever the app compares your work to GitHub, in lines like "2 ahead of last-known origin". BranchBar never fetches, so the only picture it has of GitHub is the one your last `git fetch`, `git pull`, or `git push` left behind. Saying "last-known origin" is how the app admits that GitHub may have moved since. When it can tell that it did move, the line adds "origin has moved since".

## Verify the download

Every release carries the zip and a `.sha256` file beside it. Download both into the same folder and check them:

```bash
cd ~/Downloads
shasum -a 256 -c BranchBar-1.0.0-mac.zip.sha256   # use the version you downloaded
```

The answer should end in `OK`. Anything else means the download is not the file that was published, and you should not open it.

## Uninstall

Drag **BranchBar** from Applications to the Trash. To remove what it kept as well:

```bash
rm -rf ~/Library/Logs/BranchBar ~/Library/"Application Support"/BranchBar
```

Nothing else is left behind, and nothing in your repos is touched.

## For builders

`CLAUDE.md` is the front door for anyone working on BranchBar: how to build, test, run, and ship it, plus the map of every other document. `ARCHITECTURE.md` holds how it works today.

---

<sup>If step 5 or 6 gives you no way through and the app still refuses to open, `xattr -d com.apple.quarantine /Applications/BranchBar.app` in Terminal clears the download marker macOS attached. Try the normal steps first, and tell Hannah what you saw, since a Mac managed by IT that blocks step 6 is worth knowing about.</sup>
