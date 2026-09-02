#!/bin/bash
# One PNG per recorded §5a state, from the fixtures, with no git and no gh.
#
#   scripts/screenshot-states.sh                 # every fixture
#   scripts/screenshot-states.sh pr-open in-sync # named fixtures only
#   BRANCHBAR_APPEARANCE=light scripts/screenshot-states.sh   # the light half of Gate 4
#
# For each Tests/BranchBarCoreTests/Fixtures/states/<state>.json it launches the bundled app with
# BRANCHBAR_STATE_FIXTURE set, waits for the app's own `rendered state <state>` log line, captures
# the window it drew, writes dist/screens/<state>.png, and quits.
#
# Why not click the status item: the 0.2 spike established that `screencapture` cannot see a status
# item and that clicking one from a script needs an Accessibility grant. So the app draws the same
# RootView in an ordinary window when the fixture variable is set, and that window is what gets
# captured. `--status-item` still tries the osascript route for one state, for the record.
#
# `screencapture -l` is tried first. Its fallback is NOT CGWindowListCreateImage, which PLAN.md §5b
# planned for: that call is obsoleted in the macOS 15 SDK and no longer compiles. The fallback is
# BRANCHBAR_STATE_SHOT, which makes the app draw its own window into a PNG through `cacheDisplay` —
# no Screen Recording grant needed, so this script works on a Mac that has granted nothing.
set -uo pipefail

cd "$(dirname "$0")/.."

APP="dist/BranchBar.app"
BIN="$APP/Contents/MacOS/BranchBar"
FIXTURES="Tests/BranchBarCoreTests/Fixtures/states"
OUT="dist/screens"
LOG="$HOME/Library/Logs/BranchBar/BranchBar.log"
TRY_STATUS_ITEM=0

if [ "${1:-}" = "--status-item" ]; then
  TRY_STATUS_ITEM=1
  shift
fi

[ -x "$BIN" ] || { echo "no bundle at $BIN — run: ARCHS=arm64 scripts/bundle.sh" >&2; exit 2; }
mkdir -p "$OUT"

if [ "$#" -gt 0 ]; then
  states=("$@")
else
  states=()
  for file in "$FIXTURES"/*.json; do
    name="$(basename "$file" .json)"
    states+=("$name")
  done
fi

rendered=0
captured=0
failed_render=()
failed_capture=()

for state in "${states[@]}"; do
  fixture="$FIXTURES/$state.json"
  if [ ! -f "$fixture" ]; then
    echo "== $state: no fixture at $fixture" >&2
    failed_render+=("$state")
    continue
  fi

  pkill -x BranchBar 2>/dev/null
  # A marker line, so the wait below reads only this launch's output.
  mark="$(date +%s%N)"
  printf '[screenshot-states] %s %s\n' "$mark" "$state" >> "$LOG"

  # `open` does not forward the shell environment (the reason ToolLocator exists), so the bundle's
  # executable is launched directly; it still reads the bundle's Info.plist, so LSUIElement holds.
  BRANCHBAR_STATE_FIXTURE="$PWD/$fixture" BRANCHBAR_STATE_SHOT="$PWD/$OUT/$state-app.png" \
    "$BIN" >/dev/null 2>&1 &
  app_pid=$!

  ok=0
  for _ in $(seq 1 60); do
    if awk -v m="$mark" 'index($0, m) { seen = 1; next } seen' "$LOG" 2>/dev/null \
        | grep -q "rendered state $state\$\|rendered state $state "; then
      ok=1
      break
    fi
    kill -0 "$app_pid" 2>/dev/null || break
    sleep 0.25
  done

  if [ "$ok" -ne 1 ]; then
    echo "== $state: never logged 'rendered state'" >&2
    failed_render+=("$state")
    kill "$app_pid" 2>/dev/null
    continue
  fi
  rendered=$((rendered + 1))

  if [ "$TRY_STATUS_ITEM" -eq 1 ]; then
    # For the record: the menu bar route. Needs an Accessibility grant for the calling terminal.
    osascript -e 'tell application "System Events" to tell process "BranchBar" to click menu bar item 1 of menu bar 2' \
      >/dev/null 2>&1 || echo "== $state: osascript could not click the status item" >&2
    sleep 0.6
  fi

  window="$(swift scripts/windowid.swift find "BranchBar" 2>/dev/null | head -n1)"
  if [ -z "$window" ]; then
    echo "== $state: no BranchBar window on screen" >&2
    failed_capture+=("$state")
    kill "$app_pid" 2>/dev/null
    continue
  fi

  png="$OUT/$state.png"
  rm -f "$png"
  screencapture -x -o -l "$window" "$png" 2>/dev/null
  size=0
  [ -f "$png" ] && size="$(stat -f%z "$png")"

  if [ ! -f "$png" ] || [ "$size" -lt 2000 ]; then
    echo "== $state: screencapture -l produced ${size} bytes; using the app's own cacheDisplay PNG" >&2
    rm -f "$png"
    if [ -f "$OUT/$state-app.png" ]; then
      mv "$OUT/$state-app.png" "$png"
      size="$(stat -f%z "$png")"
    else
      size=0
    fi
  fi
  rm -f "$OUT/$state-app.png"

  if [ -f "$png" ] && [ "$size" -ge 2000 ]; then
    echo "== $state: $png (${size} bytes, window $window)"
    captured=$((captured + 1))
  else
    echo "== $state: capture failed (grant Screen Recording to the calling terminal)" >&2
    failed_capture+=("$state")
  fi

  kill "$app_pid" 2>/dev/null
  wait "$app_pid" 2>/dev/null
done

pkill -x BranchBar 2>/dev/null

echo ""
echo "states asked for: ${#states[@]} · rendered: $rendered · captured: $captured"
[ "${#failed_render[@]}" -gt 0 ] && echo "did not render: ${failed_render[*]}"
[ "${#failed_capture[@]}" -gt 0 ] && echo "did not capture: ${failed_capture[*]}"
[ "$captured" -gt 0 ] || exit 1
exit 0
