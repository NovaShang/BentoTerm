#!/usr/bin/env bash
#
# Build the distributable .dmg: the app on the left, an Applications alias on
# the right, and a background that says which way to drag.
#
#   scripts/dmg/make-dmg.sh <BentoTerm.app> <out.dmg> [volume name]
#
# Uses appdmg, which writes the window's .DS_Store programmatically. The usual
# alternative — driving Finder over AppleScript — needs a logged-in GUI session
# and is exactly the step that breaks on a CI runner.
#
# The layout numbers here must match scripts/dmg/make-background.py: the icons
# are positioned onto the wells drawn in the background image.
set -euo pipefail

APP="${1:?usage: make-dmg.sh <app> <out.dmg> [volume name]}"
OUT="${2:?usage: make-dmg.sh <app> <out.dmg> [volume name]}"
VOLNAME="${3:-BentoTerm}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }

# One multi-resolution background so Retina gets the 2x image instead of an
# upscale of the 1x. tiffutil ships with macOS; no extra dependency.
tiffutil -cathidpicheck "$HERE/background.png" "$HERE/background@2x.png" \
    -out "$WORK/background.tiff" >/dev/null

ICON_ARG=""
if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
    cp "$APP/Contents/Resources/AppIcon.icns" "$WORK/volume.icns"
    ICON_ARG="\"icon\": \"$WORK/volume.icns\","
fi

cat > "$WORK/appdmg.json" <<JSON
{
  "title": "$VOLNAME",
  $ICON_ARG
  "background": "$WORK/background.tiff",
  "icon-size": 112,
  "window": { "size": { "width": 660, "height": 400 } },
  "contents": [
    { "x": 165, "y": 190, "type": "file", "path": "$APP" },
    { "x": 495, "y": 190, "type": "link", "path": "/Applications" }
  ]
}
JSON

rm -f "$OUT"
npx --yes appdmg@0.6.6 "$WORK/appdmg.json" "$OUT"

# Sign the disk image itself when an identity is available. Gatekeeper checks
# the app inside either way, but a signed image is what notarization staples
# to, and an unsigned one shows the "unidentified developer" sheet before the
# user ever reaches the app.
if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" \
        ${KEYCHAIN_PATH:+--keychain "$KEYCHAIN_PATH"} "$OUT"
    codesign --verify --strict --verbose=1 "$OUT"
fi

echo "built $OUT"
