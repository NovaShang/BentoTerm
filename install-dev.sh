#!/usr/bin/env bash
# BentoTerm dev build, one line (from a Mac on the owner's tailnet):
#   curl -fsSL https://shangs-macbook-air.tail4abc9b.ts.net/bento-term/install-dev.sh | bash
#
# Installs the newest build published by scripts/publish-dev.sh on the home
# Mac, which Tailscale Serve exposes tailnet-only at /bento-term. Replaces
# /Applications/BentoTerm.app; the previous app is kept at
# /tmp/BentoTerm-prev.app.
#
# The dev build is Developer ID signed but not notarized. That is fine here
# because curl sets no quarantine flag, so Gatekeeper never assesses it; we
# strip the flag anyway in case something upstream added one.
#
# Overrides (for testing the script without touching the real install):
#   BENTO_DEV_URL       where BentoTerm-dev.zip + .sha256 live
#   BENTO_INSTALL_DIR   where BentoTerm.app goes (default /Applications)
#   BENTO_NO_OPEN=1     don't launch the app afterwards
set -euo pipefail

ASSET="BentoTerm-dev.zip"
BASE_URL="${BENTO_DEV_URL:-https://shangs-macbook-air.tail4abc9b.ts.net/bento-term}"
BASE_URL="${BASE_URL%/}"
INSTALL_DIR="${BENTO_INSTALL_DIR:-/Applications}"
APP="$INSTALL_DIR/BentoTerm.app"
PREV="/tmp/BentoTerm-prev.app"

say() { printf '\033[1;35m▸\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# fetch <file> <curl progress flag>: download $BASE_URL/<file> into $tmp and
# turn a curl failure into what to check. The connection-level failures
# (can't resolve, can't connect, timed out, TLS) all mean the same thing
# here: this Mac isn't on the tailnet, or the home Mac is asleep.
fetch() {
  local rc=0
  curl -fL --connect-timeout 10 "$2" -o "$tmp/$1" "$BASE_URL/$1" || rc=$?
  case "$rc" in
    0) ;;
    6|7|28|35)
      die "连不上 ${BASE_URL}。检查：这台 Mac 登录了同一个 Tailscale 网络，家里那台 Mac 开着、没睡。" ;;
    22)
      die "${BASE_URL}/$1 不存在。先在家里那台 Mac 上跑一次 scripts/publish-dev.sh。" ;;
    *)
      die "下载 ${BASE_URL}/$1 失败（curl 退出码 ${rc}）。" ;;
  esac
}

# Everything runs from main(), called on the last line: with `curl | bash`
# bash reads the script from stdin as it goes, so wrapping it means the whole
# file is parsed before anything runs (a truncated download fails to parse
# instead of running half an install).
main() {
  # 1. this Mac
  [ "$(uname -s)" = Darwin ] || die "BentoTerm 只有 Mac 版。"
  # hw.optional.arm64 rather than `uname -m`: a shell running under Rosetta
  # reports x86_64 on an Apple Silicon Mac.
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] \
    || die "BentoTerm 只支持 Apple Silicon（M 系列芯片）的 Mac。"
  os="$(sw_vers -productVersion)"
  [ "${os%%.*}" -ge 27 ] || die "需要 macOS 27 或更新，这台是 ${os}。"

  # 2. download + verify
  tmp="$(mktemp -d -t bento-dev)"
  trap 'rm -rf "$tmp"' EXIT
  say "从 $BASE_URL 下载最新 dev 构建…"
  fetch "$ASSET" --progress-bar
  fetch "$ASSET.sha256" --silent
  (cd "$tmp" && shasum -a 256 -c "$ASSET.sha256" >/dev/null 2>&1) \
    || die "校验和对不上，下载可能不完整，重跑一次试试。"

  ditto -x -k "$tmp/$ASSET" "$tmp/x"
  new="$tmp/x/BentoTerm.app"
  [ -d "$new" ] || die "压缩包里没有 BentoTerm.app。"
  xattr -dr com.apple.quarantine "$new" 2>/dev/null || true
  codesign --verify --deep --strict "$new" 2>/dev/null \
    || die "签名校验没通过，不装。"
  # Captured, not piped into `grep -q`: grep quitting early would SIGPIPE
  # codesign, and pipefail would report that as "not signed".
  sig="$(codesign -dvv "$new" 2>&1 || true)"
  case "$sig" in
    *"Authority=Developer ID Application"*) ;;
    *) die "不是 Developer ID 签名的包，不装。" ;;
  esac

  # 3. permission: brew and drag-install both leave /Applications writable for
  # an admin user; only fall back to sudo when it really isn't.
  SUDO=""
  if [ ! -w "$INSTALL_DIR" ] || { [ -e "$APP" ] && [ ! -w "$APP" ]; }; then
    say "$INSTALL_DIR 当前用户写不了，需要管理员密码来替换 BentoTerm.app。"
    SUDO="sudo"
  fi

  # 4. quit the running copy (only the one at the path we're replacing)
  if pgrep -f "^$APP/Contents/MacOS/BentoTerm" >/dev/null 2>&1; then
    say "退出正在运行的 BentoTerm（tmux 会话在独立的 tmux server 里，不受影响）…"
    osascript -e "tell application \"$APP\" to quit" >/dev/null 2>&1 </dev/null || true
    for _ in $(seq 1 20); do
      pgrep -f "^$APP/Contents/MacOS/BentoTerm" >/dev/null 2>&1 || break
      sleep 0.5
    done
    if pgrep -f "^$APP/Contents/MacOS/BentoTerm" >/dev/null 2>&1; then
      die "BentoTerm 10 秒内没退出（可能停在确认对话框上）。手动退出后再跑一次。"
    fi
  fi

  # 5. swap
  if [ -e "$APP" ]; then
    $SUDO rm -rf "$PREV"
    $SUDO mv "$APP" "$PREV"
  fi
  $SUDO ditto "$new" "$APP"
  $SUDO xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  codesign --verify --deep --strict "$APP" 2>/dev/null \
    || die "装好后签名校验没通过；旧版在 ${PREV}。"

  plist="$APP/Contents/Info.plist"
  ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
  say "已装好 BentoTerm ${ver}（${build}）→ $APP"
  [ -e "$PREV" ] && say "上一个版本留在 $PREV"
  say "dev 版不会自动升到正式版；回正式版：brew reinstall --cask NovaShang/tap/bento-term"

  if [ "${BENTO_NO_OPEN:-}" != 1 ]; then
    open "$APP"
  fi
}

main "$@"
