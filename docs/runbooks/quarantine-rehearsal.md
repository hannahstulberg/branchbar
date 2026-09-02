# Runbook — Gatekeeper quarantine rehearsal

Rehearses what an NYT tester sees the first time they open the zipped `.app`. BranchBar is
ad-hoc signed with no Developer ID and no notarization, so Gatekeeper rejects it by policy;
the install note in the README (packet 5.2) has to name the exact dialog and the exact click.

Recorded on macOS 15.5 (24F74), arm64, packet 0.2.

## The one command that always tells the truth

```bash
spctl -a -t exec -vv /Applications/BranchBar.app
```

```
/Applications/BranchBar.app: rejected
```

Exit code 3. This says `rejected` on a Mac that has already run the app and on one that never
has, before and after the quarantine attribute is applied. It is the Gatekeeper verdict that
produces the first-run dialog and it is the assertion CI and this runbook should check —
never "did it launch".

## What this rehearsal can and cannot prove

It **cannot** reproduce the first-run block on a Mac that has already run BranchBar.
Verified three ways on 2026-09-01, all of which launched the app with no dialog:

| Attempt | Result |
|---|---|
| `xattr -w com.apple.quarantine "0083;…"` on the bundle root, then `open` | launched, no dialog |
| `xattr -w -r com.apple.quarantine "0081;…"` (unapproved-download flags, recursive), then `open` | launched, no dialog |
| `ditto` to a path that had never been launched, quarantine, then `open` | launched, no dialog |

LaunchServices keys its Gatekeeper approval to the code-signing identity, not the path, so once
this Mac has approved the binary it keeps approving it. **The real first-run experience is only
observable on a Mac that has never run BranchBar** — which is exactly what Gate 5's NYT tester
provides. Treat their report, not this runbook, as the source for the README's screenshots.

## What the rehearsal did prove: app translocation

With the quarantine attribute set, macOS ran the app from a randomized read-only mount:

```
$ ps -o comm= -p 203
/private/var/folders/yf/…/T/AppTranslocation/7C101962-…/d/BranchBar.app/Contents/MacOS/BranchBar
```

This happened **even from `/Applications`**. Removing the attribute from the bundle root is
enough to stop it; the app then runs from its real path:

```
$ xattr -d com.apple.quarantine /Applications/BranchBar.app
$ open /Applications/BranchBar.app
$ ps -o comm= -p 598
/Applications/BranchBar.app/Contents/MacOS/BranchBar
```

Consequences BranchBar has to respect:

- Anything derived from `Bundle.main.bundlePath` or `bundleURL` is a random temp path on a
  quarantined first run. Never persist it, never show it, never register it.
- `SMAppService` (spike item 5, packet 4.2) must not be registered from a translocated bundle.
  Check the bundle path against `/Applications` before offering the launch-at-login toggle.
- The dialog the user clicks through is what clears the attribute, which is what ends
  translocation. The README's install steps therefore have to be followed in order.

## Rehearse it (on a Mac that has never run BranchBar)

```bash
# 1. Verdict before anything else
spctl -a -t exec -vv /Applications/BranchBar.app        # expect: rejected

# 2. Mark it the way a browser download would
xattr -w com.apple.quarantine "0081;00000000;Safari;" /Applications/BranchBar.app
xattr -p com.apple.quarantine /Applications/BranchBar.app

# 3. Open it and watch the screen
open /Applications/BranchBar.app

# 4. Confirm which path it actually ran from
ps -o comm= -p "$(pgrep -x BranchBar)"

# 5. Undo
pkill -x BranchBar
xattr -d -r com.apple.quarantine /Applications/BranchBar.app
xattr -r -l /Applications/BranchBar.app | grep -c quarantine   # expect: 0
```

`xattr -w -r` writes the attribute to every file inside the bundle, so undo with `xattr -d -r`.
Deleting it from the root alone stops translocation but leaves 8 attributes on inner files.

## What a human should expect to click on macOS 15

macOS 15 removed the old right-click-Open bypass. The sequence is:

1. Double-click `BranchBar.app`. A dialog says Apple could not verify BranchBar is free of
   malware, with **Done** as the only real button. The app does not open.
2. Open **System Settings → Privacy & Security**, scroll to the **Security** section. A line
   reads that BranchBar was blocked, with an **Open Anyway** button beside it. The button is
   only there for about an hour after the blocked launch; if it is gone, repeat step 1.
3. Click **Open Anyway**. Authenticate with Touch ID or the login password.
4. A second dialog confirms opening BranchBar. Click **Open**.
5. The menu bar icon appears. Subsequent launches never prompt again.

Every step above is from Apple's documented macOS 15 flow, **not** observed on this machine —
this Mac cannot reach step 1. Gate 5's tester confirms the wording and supplies the screenshots
for the README.
