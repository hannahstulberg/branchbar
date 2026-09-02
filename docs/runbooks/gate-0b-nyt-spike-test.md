# BranchBar test build — install note

Thanks for trying this. It is a small test build, not a finished app, and takes about five minutes.

BranchBar is a tiny menu bar app that does almost nothing on purpose: it checks whether the GitHub
command line tool works when an app runs it, and whether picking a folder lets the app see the
projects inside. Both behave differently on a work Mac than on a personal one, which is why a real
person has to try it.

You do not need an admin password or anything else installed. The app only reads: it changes no
files and sends nothing anywhere. It will ask macOS for permission to read a folder you choose.

**Download:** `<RELEASE_URL_PLACEHOLDER>`

Your Mac will probably warn you that the app is from an unidentified developer. That is expected;
the steps below get past it. If your Mac blocks it with no way through, stop and tell me exactly
what the message said — that is the main thing this test is looking for.

At the end, press **Copy report** and paste the result back to me, with anything that was confusing
or alarming.

---

## Checklist

- [ ] 1. Download the zip from the link above.
- [ ] 2. Double-click the zip. A file called **BranchBar** appears.
- [ ] 3. Drag **BranchBar** into your **Applications** folder.
- [ ] 4. Double-click **BranchBar** in Applications.
- [ ] 5. A box appears titled **"BranchBar" Not Opened**, saying Apple could not verify BranchBar
      is free of malware. Click **Done**.
      - **Do not press Return, and do not click Move to Trash.** Move to Trash is the highlighted
        button, so the Return key would delete the app. Click **Done** with the mouse.
- [ ] 6. Open **System Settings** → **Privacy & Security**. Scroll down. There should be a line
      about BranchBar being blocked, with an **Open Anyway** button. Click it, then click **Open
      Anyway** again in the box that appears. Enter your Mac password if asked.
      - **If there is no Open Anyway button, or the button does nothing:** stop here. Write down
        exactly what you see and send me a screenshot. This is the answer I need most.
- [ ] 7. Look at the top-right of your screen, in the menu bar near the clock. There should be a
      small branch-shaped icon. Click it.
- [ ] 8. Click **Check GitHub CLI**. Wait a few seconds for text to appear.
- [ ] 9. Click **Add folder…**. Choose your **Documents** folder and click **Add folder**. If macOS
      asks whether BranchBar can access Documents, click **Allow** (or **OK**).
- [ ] 10. Click **Copy report**, then paste it into your reply to me.
- [ ] 11. Restart your Mac.
- [ ] 12. After restarting, open BranchBar again from Applications. Note whether it opened straight
      away, or warned you again.
- [ ] 13. Download the zip a second time from the same link, unzip it, and drag it into
      Applications, replacing the old one. Open it. Note whether it opened straight away, or
      warned you again.
- [ ] 14. Reply with: the pasted report, what happened at steps 5–6, and what happened at steps 12
      and 13.

## To remove it

Drag **BranchBar** from Applications to the Trash. Nothing else is left behind except a log file
at `~/Library/Logs/BranchBar/`.

---

## Notes for the maintainer (not for the tester)

- The report the tester pastes carries the app version, macOS version, chip, the `gh` path that was
  found and every path that was searched, the `gh auth status` exit code and output, and the folder
  they picked with the repos found inside it.
- **Step 5's dialog was observed firsthand** on 2026-09-01, macOS 15.5 (24F74), from a
  freshly-signed `dist/BranchBar.app` carrying `com.apple.quarantine 0083;00000000;Safari;`. The
  0.2 rehearsal could not reproduce it because it launched `/Applications/BranchBar.app`, whose
  signing identity LaunchServices had already approved. Verbatim, from the accessibility tree:

  > "BranchBar" Not Opened
  > Apple could not verify "BranchBar" is free of malware that may harm your Mac or compromise
  > your privacy.

  Buttons: **Done**, **Move to Trash**. Move to Trash is the highlighted default, which is why the
  checklist warns against Return.
- **The app is held before it runs.** While that dialog is up, the process exists and is already
  app-translocated (`/private/var/folders/…/AppTranslocation/…/BranchBar.app`), but
  `applicationDidFinishLaunching` never fires and the log file stays empty. So the log fallback
  below is worthless until the tester gets past Gatekeeper — if they send an empty log, they are
  stuck at step 5 or 6, not at step 8.
- Step 6's click path is Apple's documented macOS 15 flow and is still unobserved; this Mac had
  already approved the identity, so it went straight from Done to a working launch.
  `docs/runbooks/quarantine-rehearsal.md` holds the expected sequence to check the report against.
- `spctl -a -t exec -vv` says `rejected`, exit 3, identically before quarantine, under quarantine,
  and after `xattr -d` — the ad-hoc signature is the reason, not the attribute.
- Step 12 tests relaunch after reboot; step 13 tests a rebuilt zip (a fresh ad-hoc signature),
  which is also spike item 9 — whether the folder permission has to be granted again.
- A blocked step 6 with no IT allow-list path is the stop decision in PLAN.md §3: the menu bar app
  ends and the workshop falls back to `branchbar-cli snapshot`.
- If a tester cannot describe what they saw, the log at `~/Library/Logs/BranchBar/BranchBar.log`
  carries every action. `BRANCHBAR_SPIKE_AUTORUN=1`, set with `launchctl setenv`, makes the app run
  the `gh` check at launch and write the report there without any clicking.
