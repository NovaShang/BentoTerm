#!/usr/bin/env bash
# fetch-sherpa-onnx.sh — builds Modules/SherpaOnnxKit/SherpaOnnx.xcframework
# (the sherpa-onnx C library behind the on-device SenseVoice speech engine)
# from the official k2-fsa/sherpa-onnx release zips. Run before any build;
# CI, the release workflows and scripts/verify.sh all call it.
#
# Why a fetch script and not a url binaryTarget like GhosttyKit: sherpa-onnx's
# Apple xcframeworks are static libraries with `Headers/module.modulemap` at
# the top level, and so is GhosttyKit's. Xcode copies every static
# xcframework's Headers/ into one shared Build/Products/<cfg>/include/, so two
# of them both shipping include/module.modulemap is a hard "Multiple commands
# produce …/include/module.modulemap" build error. This script re-wraps the
# same official binaries (checksum-verified, bytes untouched) with the
# headers one level down — Headers/SherpaOnnxC/ — where clang still finds the
# module map, and merges iOS device, iOS simulator and macOS into one
# xcframework. ~95 MB on disk, gitignored, never committed.
#
# onnxruntime is not here: it's a framework-style xcframework (no top-level
# headers), so it stays a plain url binaryTarget in Modules/SherpaOnnxKit.
#
# Idempotent: exits 0 at once when the pinned version is already in place.

set -euo pipefail

VERSION="1.13.4"
IOS_ZIP="sherpa-onnx-v${VERSION}-ios-no-tts.xcframework.zip"
IOS_SHA="74306ad04310d921ce0ba9b356a349a2020a0eb79994da33e356e67f303e42c6"
MAC_ZIP="sherpa-onnx-v${VERSION}-macos.xcframework.zip"
MAC_SHA="4325d8aed99b94be58969005b19f9626f3f3afc4ebd42378b0aad2b84e233552"
BASE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Modules/SherpaOnnxKit/SherpaOnnx.xcframework"
MARKER="$ROOT/Modules/SherpaOnnxKit/.sherpa-onnx-version"
CACHE="${SHERPA_ONNX_CACHE:-$HOME/Library/Caches/bento-sherpa-onnx}"

if [ -d "$OUT" ] && [ "$(cat "$MARKER" 2>/dev/null)" = "$VERSION" ]; then
  exit 0
fi

mkdir -p "$CACHE"
fetch() {
  local name="$1" sha="$2" dest="$CACHE/$1"
  if [ -f "$dest" ] && [ "$(shasum -a 256 "$dest" | cut -d' ' -f1)" = "$sha" ]; then
    return 0
  fi
  echo "fetch-sherpa-onnx: downloading $name"
  curl -fsSL --retry 3 -o "$dest.tmp" "$BASE_URL/$name"
  local got
  got="$(shasum -a 256 "$dest.tmp" | cut -d' ' -f1)"
  if [ "$got" != "$sha" ]; then
    rm -f "$dest.tmp"
    echo "fetch-sherpa-onnx: checksum mismatch for $name (got $got)" >&2
    exit 1
  fi
  mv "$dest.tmp" "$dest"
}
fetch "$IOS_ZIP" "$IOS_SHA"
fetch "$MAC_ZIP" "$MAC_SHA"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
unzip -q "$CACHE/$IOS_ZIP" -d "$work/ios"
unzip -q "$CACHE/$MAC_ZIP" -d "$work/mac"

# One header dir for all slices (the headers are identical across them):
# c-api.h + a module map, one level below Headers/.
mkdir -p "$work/headers/SherpaOnnxC"
cp "$work/mac/sherpa-onnx.xcframework/macos-arm64_x86_64/Headers/c-api.h" "$work/headers/SherpaOnnxC/"
cat > "$work/headers/SherpaOnnxC/module.modulemap" <<'EOF'
module SherpaOnnxC {
  header "c-api.h"
  export *
}
EOF

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$work/ios/sherpa-onnx.xcframework/ios-arm64/sherpa-onnx.a" -headers "$work/headers" \
  -library "$work/ios/sherpa-onnx.xcframework/ios-arm64_x86_64-simulator/sherpa-onnx.a" -headers "$work/headers" \
  -library "$work/mac/sherpa-onnx.xcframework/macos-arm64_x86_64/libsherpa-onnx.a" -headers "$work/headers" \
  -output "$OUT" >/dev/null
echo "$VERSION" > "$MARKER"
echo "fetch-sherpa-onnx: built $OUT (sherpa-onnx v$VERSION)"
