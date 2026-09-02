#!/bin/bash
# Assemble dist/BranchBar.app from a release SwiftPM build.
#
# Order (PLAN.md §5b): build -> layout -> Info.plist -> PkgInfo -> icns -> ad-hoc sign
# -> verify. `make zip` adds the ditto archive and its sha256 on top of this.
#
# Two executables land in Contents/MacOS. BranchBar is the app; branchbar-cli is the discovery
# helper the app spawns (codex round 2, BLOCKER 1): a walk already inside open()/readdir() cannot
# be cancelled, but a process can be killed, so the scan runs there and the scan deadline is a
# SIGTERM/SIGKILL to it. `HelperProcessScanRunner.helperExecutableURL` looks for it beside the
# running executable, which is why it goes in Contents/MacOS and not Contents/Resources.
#
#   ARCHS="arm64"            # default, the handout arch
#   ARCHS="arm64 x86_64"     # universal; slices are lipo'd together
#
# Signing is LAST. codesign seals the bundle, so anything written into BranchBar.app
# after `codesign` invalidates the signature.
set -euo pipefail

cd "$(dirname "$0")/.."

ARCHS="${ARCHS:-arm64}"
APP="dist/BranchBar.app"
DEPLOY_TARGET="13.0"
BUNDLE_ID="com.hannahstulberg.branchbar"

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUILD="${BUILD:-1}"

echo "==> BranchBar $VERSION (build $BUILD), archs: $ARCHS"

# --- build each slice -------------------------------------------------------
slices=()
helper_slices=()
for arch in $ARCHS; do
  triple="${arch}-apple-macosx${DEPLOY_TARGET}"
  echo "==> swift build --triple $triple"
  swift build -c release --product BranchBar --triple "$triple"
  swift build -c release --product branchbar-cli --triple "$triple"
  bin_path="$(swift build -c release --product BranchBar --triple "$triple" --show-bin-path)"
  bin="$bin_path/BranchBar"
  helper="$bin_path/branchbar-cli"
  [ -f "$bin" ] || { echo "missing product for $triple at $bin" >&2; exit 1; }
  [ -f "$helper" ] || { echo "missing helper for $triple at $helper" >&2; exit 1; }
  slices+=("$bin")
  helper_slices+=("$helper")
done

# --- assemble the bundle ----------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "${#slices[@]}" -gt 1 ]; then
  lipo -create "${slices[@]}" -output "$APP/Contents/MacOS/BranchBar"
  lipo -create "${helper_slices[@]}" -output "$APP/Contents/MacOS/branchbar-cli"
else
  cp "${slices[0]}" "$APP/Contents/MacOS/BranchBar"
  cp "${helper_slices[0]}" "$APP/Contents/MacOS/branchbar-cli"
fi
chmod +x "$APP/Contents/MacOS/BranchBar" "$APP/Contents/MacOS/branchbar-cli"

sed -e "s/__VERSION__/$VERSION/g" \
    -e "s/__BUILD__/$BUILD/g" \
    Resources/Info.plist.template > "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- app icon ---------------------------------------------------------------
# Must land before codesign: the signature seals Contents/Resources, so an icns
# copied in afterwards invalidates it. Info.plist's CFBundleIconFile names AppIcon.
scripts/make-icns.sh
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# --- sign last, then verify -------------------------------------------------
# The nested executable is signed first and with its own identifier: signing the bundle seals
# Contents/MacOS, so a helper signed afterwards would invalidate the app's signature, and an
# unsigned Mach-O inside a signed bundle fails `codesign --verify --strict`.
codesign --force --sign - --identifier "$BUNDLE_ID.cli" "$APP/Contents/MacOS/branchbar-cli"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign --verify --strict --verbose=2 "$APP/Contents/MacOS/branchbar-cli"

# --- report -----------------------------------------------------------------
echo "==> lipo -info"
lipo -info "$APP/Contents/MacOS/BranchBar"
lipo -info "$APP/Contents/MacOS/branchbar-cli"
echo "==> LC_BUILD_VERSION minos (one line per slice)"
otool -l "$APP/Contents/MacOS/BranchBar" | grep -A4 LC_BUILD_VERSION | grep minos

echo "==> built $APP"
