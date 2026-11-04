#!/bin/sh
# Renders the README screenshots from the demo library (made-up meetings, no real data, no AI calls)
# into ../docs/screenshots as <name>-light.webp and <name>-dark.webp.
# Needs a display (the app opens its window for a minute) and cwebp: brew install webp.
set -e
cd "$(dirname "$0")"
command -v cwebp >/dev/null || { echo "cwebp not found: brew install webp" >&2; exit 1; }
swift build
OUT=../docs/screenshots
TMP=$(mktemp -d)
DYLD_FALLBACK_LIBRARY_PATH=/usr/lib/swift .build/debug/MeetNotes --demo --screenshots "$TMP" -AppleLanguages "(en)"
mkdir -p "$OUT"
for f in "$TMP"/*.png; do
  cwebp -quiet -q 88 -alpha_q 100 "$f" -o "$OUT/$(basename "${f%.png}").webp"
done
rm -rf "$TMP"
ls -l "$OUT"
