#!/usr/bin/env bash
# ios-dev.sh — self-contained iOS simulator build/drive/observe loop for Bento.
#
# The loop that lets Claude self-validate iOS fixes without the user retesting:
#   build → install (keeps data, so the saved host persists) → relaunch → drive → observe
#
# The SSH host is added ONCE by the user. Reinstalling over the same bundle id
# preserves the app's data container (Documents/, Preferences/), so hosts.json and the
# saved host survive every rebuild. Never re-add the host; never attach to session `main`.
#
# Usage:
#   scripts/ios-dev.sh doctor              # print sim/app/host state
#   scripts/ios-dev.sh build               # incremental Debug build → .dd-ios
#   scripts/ios-dev.sh install             # install built .app onto the sim
#   scripts/ios-dev.sh relaunch            # terminate + launch (fresh debug.log)
#   scripts/ios-dev.sh run                 # build + install + relaunch  (the main verb)
#   scripts/ios-dev.sh log [N]             # last N lines of debug.log (spam-filtered)
#   scripts/ios-dev.sh log -f              # follow debug.log live
#   scripts/ios-dev.sh oslog [category]    # stream os_log (subsystem com.novashang.bento)
#   scripts/ios-dev.sh shot [path]         # screenshot → /tmp/bento_shot.png
#   scripts/ios-dev.sh maestro <flow.yaml> # run a Maestro flow against the sim
#   scripts/ios-dev.sh attach [session]    # Maestro-navigate into a session terminal
#   scripts/ios-dev.sh send <cmd…>         # inject a line into the test tmux session (Mac side)
#   scripts/ios-dev.sh pane                # dump the test tmux pane (rendering ground truth)
#   scripts/ios-dev.sh container           # print app data container path
#
# The saved host IS this machine, so the throwaway `bentotest` tmux session can be
# driven deterministically from here (`send`/`pane`) while the app renders it — far more
# reliable than typing into the terminal via Maestro (custom UITextInput, no soft keyboard).
#
# Env:
#   SIM=<udid>       override target sim (default: first booted, else iPad Air 11 M4)
#   SESSION=<name>   test tmux session for send/pane/attach (default: bentotest; `main` refused)
#   BENTO_VERBOSE=1  stream full xcodebuild output instead of the tail summary
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

DD="$REPO/.dd-ios"
APP_ID="com.bento.term.app"
SCHEME="BentoTermiOS"
MAESTRO="$HOME/.maestro/bin/maestro"
FALLBACK_SIM="FD4977E4-DBF4-4A39-B4FB-BE81B4017856"   # iPad Air 11-inch (M4)
LA_SPAM='Failed to start aggregate Live Activity'      # sim-only noise, filtered by default
TEST_SESSION="${SESSION:-bentotest}"                    # throwaway tmux session for input/observe

# ---- target simulator ------------------------------------------------------
resolve_sim() {
  if [[ -n "${SIM:-}" ]]; then echo "$SIM"; return; fi
  local booted
  booted=$(xcrun simctl list devices booted -j 2>/dev/null | python3 -c \
    'import sys,json; d=json.load(sys.stdin)["devices"]; ids=[x["udid"] for v in d.values() for x in v if x.get("state")=="Booted"]; print(ids[0] if ids else "")' 2>/dev/null || true)
  echo "${booted:-$FALLBACK_SIM}"
}
SIM_ID="$(resolve_sim)"

app_path()  { echo "$DD/Build/Products/Debug-iphonesimulator/BentoTerm.app"; }
container() { xcrun simctl get_app_container "$SIM_ID" "$APP_ID" data 2>/dev/null; }
log_file()  { echo "$(container)/Documents/debug.log"; }

need_boot() {
  local state
  state=$(xcrun simctl list devices -j | python3 -c \
    "import sys,json; d=json.load(sys.stdin)['devices']; print(next((x['state'] for v in d.values() for x in v if x['udid']=='$SIM_ID'),'missing'))")
  if [[ "$state" != "Booted" ]]; then
    echo "→ booting $SIM_ID ($state)…"
    xcrun simctl boot "$SIM_ID" 2>/dev/null || true
    open -a Simulator
  fi
}

# ---- commands --------------------------------------------------------------
cmd_doctor() {
  echo "sim        : $SIM_ID"
  xcrun simctl list devices -j | python3 -c \
    "import sys,json; d=json.load(sys.stdin)['devices']; m=next((x for v in d.values() for x in v if x['udid']=='$SIM_ID'),None); print('device     :', (m['name']+' ['+m['state']+']') if m else 'MISSING')"
  local c; c="$(container || true)"
  echo "installed  : $([[ -n "$c" ]] && echo yes || echo 'NO (run: install)')"
  if [[ -n "$c" ]]; then
    echo "container  : $c"
    local p="$c/Documents/hosts.json"
    if [[ -f "$p" ]]; then
      python3 -c "import json;d=json.load(open('$p'));print('hosts      :', ', '.join(x.get('label') or x.get('name') or '?' for x in d) or 'none')"
    else
      echo "hosts      : NO hosts.json (user must add an SSH host once)"
    fi
    echo "debug.log  : $([[ -f "$(log_file)" ]] && echo "$(wc -l < "$(log_file)" | tr -d ' ') lines" || echo missing)"
  fi
  echo "app build  : $([[ -d "$(app_path)" ]] && echo "$(app_path)" || echo 'not built')"
}

cmd_build() {
  need_boot
  echo "→ building $SCHEME (Debug) for $SIM_ID …"
  local logf="$DD/last-build.log"
  set +e
  if [[ "${BENTO_VERBOSE:-}" == "1" ]]; then
    xcodebuild -project BentoTerm.xcodeproj -scheme "$SCHEME" -configuration Debug \
      -destination "id=$SIM_ID" -derivedDataPath "$DD" build "$@" | tee "$logf"
    local rc=${PIPESTATUS[0]}
  else
    xcodebuild -project BentoTerm.xcodeproj -scheme "$SCHEME" -configuration Debug \
      -destination "id=$SIM_ID" -derivedDataPath "$DD" build "$@" > "$logf" 2>&1
    local rc=$?
  fi
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "✗ BUILD FAILED (rc=$rc). Errors:"
    grep -nE "error:|fatal error|── ERROR|The following build commands failed" "$logf" | head -40
    echo "  (full log: $logf)"
    return $rc
  fi
  echo "✓ BUILD OK → $(app_path)"
}

cmd_install() {
  need_boot
  local a; a="$(app_path)"
  [[ -d "$a" ]] || { echo "✗ no built app; run: build"; return 1; }
  echo "→ installing $a (data container preserved → saved host kept)"
  xcrun simctl install "$SIM_ID" "$a"
  echo "✓ installed $APP_ID"
}

cmd_relaunch() {
  need_boot
  xcrun simctl terminate "$SIM_ID" "$APP_ID" 2>/dev/null || true
  local pid; pid=$(xcrun simctl launch "$SIM_ID" "$APP_ID")
  echo "✓ launched: $pid"
}

cmd_run() { cmd_build "$@"; cmd_install; cmd_relaunch; }

cmd_log() {
  local f; f="$(log_file)"
  [[ -f "$f" ]] || { echo "✗ no debug.log at $f (app not run yet?)"; return 1; }
  if [[ "${1:-}" == "-f" ]]; then
    tail -f "$f" | grep --line-buffered -v "$LA_SPAM"
  elif [[ "${1:-}" == "--all" ]]; then
    tail -n "${2:-80}" "$f"
  else
    grep -v "$LA_SPAM" "$f" | tail -n "${1:-60}"
  fi
}

cmd_oslog() {
  local pred="subsystem == \"com.novashang.bento\" OR subsystem == \"com.bento.terminalcore\""
  [[ -n "${1:-}" ]] && pred="$pred AND category == \"$1\""
  echo "→ streaming os_log ($pred)  — ctrl-c to stop"
  xcrun simctl spawn "$SIM_ID" log stream --style compact --predicate "$pred"
}

cmd_shot() {
  local out="${1:-/tmp/bento_shot.png}"
  xcrun simctl io "$SIM_ID" screenshot "$out" >/dev/null 2>&1
  echo "✓ $out"
}

cmd_maestro() {
  [[ -n "${1:-}" ]] || { echo "usage: maestro <flow.yaml>"; return 1; }
  "$MAESTRO" --device "$SIM_ID" test "$1"
}

cmd_attach() {
  local s="${1:-$TEST_SESSION}"
  [[ "$s" == "main" ]] && { echo "✗ refusing to attach to 'main' (user's live session)"; return 1; }
  "$MAESTRO" --device "$SIM_ID" test -e "SESSION=$s" "$REPO/tests/maestro/attach.yaml"
}

cmd_send() {
  [[ "$TEST_SESSION" == "main" ]] && { echo "✗ refusing to send to 'main'"; return 1; }
  tmux has-session -t "$TEST_SESSION" 2>/dev/null || { echo "✗ no tmux session '$TEST_SESSION' (create via: maestro tests/maestro/new-session.yaml)"; return 1; }
  tmux send-keys -t "$TEST_SESSION" "$*" Enter
  echo "→ sent to $TEST_SESSION: $*"
}

cmd_pane() {
  tmux has-session -t "$TEST_SESSION" 2>/dev/null || { echo "✗ no tmux session '$TEST_SESSION'"; return 1; }
  tmux capture-pane -t "$TEST_SESSION" -p
}

cmd_container() { container; }

# ---- dispatch --------------------------------------------------------------
cmd="${1:-doctor}"; shift || true
case "$cmd" in
  doctor|build|install|relaunch|run|log|oslog|shot|maestro|attach|send|pane|container) "cmd_$cmd" "$@";;
  *) echo "unknown: $cmd"; sed -n '2,44p' "$0"; exit 1;;
esac
