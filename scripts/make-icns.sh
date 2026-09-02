#!/bin/bash
# Build .build/AppIcon.icns from Resources/icon-1024.png (PLAN.md §5b).
#
#   scripts/make-icns.sh                       # default in/out
#   scripts/make-icns.sh path/to/master.png    # alternate master
#
# sips downsamples the 1024 master into the ten sizes an .iconset needs and
# iconutil packs them. Both ship with macOS, so this needs no toolchain beyond
# the Command Line Tools the rest of the build already assumes.
#
# The iconset lives under .build/ (gitignored) alongside SwiftPM's output —
# only the PNG master is version controlled. bundle.sh calls this before it
# signs, because codesign seals Contents/Resources.
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="${1:-Resources/icon-1024.png}"
ICONSET=".build/AppIcon.iconset"
ICNS=".build/AppIcon.icns"

[ -f "$SRC" ] || {
  echo "make-icns: missing $SRC — run: swift scripts/render-icon.swift $SRC" >&2
  exit 1
}

# Fail loudly if the master is not 1024x1024: every size below is a downsample,
# and an undersized master silently ships a blurry 512@2x.
dims="$(sips -g pixelWidth -g pixelHeight "$SRC" | awk '/pixel(Width|Height)/ {printf "%s ", $2}')"
[ "$dims" = "1024 1024 " ] || {
  echo "make-icns: $SRC is ${dims}px; the master must be 1024 1024" >&2
  exit 1
}

rm -rf "$ICONSET" "$ICNS"
mkdir -p "$ICONSET"

# name                      pixels
# The ten entries Apple's iconset format defines: five logical sizes at 1x and 2x.
sizes="
icon_16x16.png:16
icon_16x16@2x.png:32
icon_32x32.png:32
icon_32x32@2x.png:64
icon_128x128.png:128
icon_128x128@2x.png:256
icon_256x256.png:256
icon_256x256@2x.png:512
icon_512x512.png:512
icon_512x512@2x.png:1024
"

for entry in $sizes; do
  name="${entry%%:*}"
  px="${entry##*:}"
  sips -z "$px" "$px" "$SRC" --out "$ICONSET/$name" >/dev/null
done

count="$(find "$ICONSET" -name '*.png' | wc -l | tr -d '[:space:]')"
[ "$count" = "10" ] || { echo "make-icns: expected 10 iconset members, got $count" >&2; exit 1; }

iconutil -c icns "$ICONSET" -o "$ICNS"
[ -f "$ICNS" ] || { echo "make-icns: iconutil produced no $ICNS" >&2; exit 1; }

echo "==> $ICNS ($(wc -c < "$ICNS" | tr -d '[:space:]') bytes, $count sizes from $SRC)"
