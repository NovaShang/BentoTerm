#!/usr/bin/env bash
# Launch Bento with the keystroke-latency profiler armed, then follow its report.
#
# Performance is only meaningful in Release (Debug loads an unoptimized dylib),
# so this builds Release by default.
#
#   scripts/profile-input.sh              # build Release, launch, follow report
#   scripts/profile-input.sh --no-build   # skip the build, use the last one
#   scripts/profile-input.sh --signpost   # also emit os_signpost for Instruments
#
# Type in the app for 20–30 seconds, ideally reproducing the stutter (open a busy
# agent pane, or run `seq 1 3000000` in a background window while typing). The
# report at /tmp/bento-input-profile.txt rewrites every 2s.
set -euo pipefail

cd "$(dirname "$0")/.."

DD="build/dd-profile"
OUT="${BENTO_PROFILE_OUT:-/tmp/bento-input-profile.txt}"
BUILD=1
SIGNPOST=0

for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --signpost) SIGNPOST=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

if [[ $BUILD -eq 1 ]]; then
  echo "==> building BentoMenubar (Release)…"
  xcodebuild -project Bento.xcodeproj -scheme BentoMenubar \
    -configuration Release -destination 'platform=macOS,arch=arm64' \
    CODE_SIGNING_ALLOWED=NO -derivedDataPath "$DD" build \
    >/tmp/bento-profile-build.log 2>&1 || {
      echo "build failed — see /tmp/bento-profile-build.log" >&2
      tail -30 /tmp/bento-profile-build.log >&2
      exit 1
    }
fi

APP="$DD/Build/Products/Release/Bento.app"
BIN="$APP/Contents/MacOS/Bento"
[[ -x "$BIN" ]] || { echo "no binary at $BIN — build first" >&2; exit 1; }

# A Debug package sneaking into the bundle would invalidate every number here.
if ls "$APP/Contents/MacOS/" | grep -q 'debug.dylib'; then
  echo "WARNING: bundle contains a debug dylib — these numbers are not Release numbers." >&2
fi

# One instance only; a second copy fights over the same tmux sessions. Match on
# the macOS bundle path, NOT the process name — a Bento running in the iOS
# simulator is also called "Bento" and must not be caught by this.
pkill -f 'Build/Products/Release/Bento.app/Contents/MacOS/Bento' 2>/dev/null || true
sleep 1

rm -f "$OUT"
export BENTO_PROFILE=1
export BENTO_PROFILE_OUT="$OUT"
[[ $SIGNPOST -eq 1 ]] && export BENTO_PROFILE_SIGNPOST=1

echo "==> launching $BIN with BENTO_PROFILE=1"
"$BIN" >/tmp/bento-profile-stdout.log 2>&1 &
APP_PID=$!
echo "    pid $APP_PID   report: $OUT"
echo
echo "Now go type in a Bento window for 20–30s (reproduce the stutter)."
echo "Ctrl-C here when done; the app keeps running."
echo

# Wait for the first report, then follow it.
for _ in $(seq 1 40); do
  [[ -f "$OUT" ]] && break
  sleep 0.5
done

while kill -0 "$APP_PID" 2>/dev/null; do
  clear
  cat "$OUT" 2>/dev/null || echo "(waiting for first report…)"
  sleep 2
done
