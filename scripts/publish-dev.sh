#!/usr/bin/env bash
# publish-dev.sh — build the working tree as a signed dev BentoTerm.app and
# serve it to the owner's other Macs over Tailscale.
#
# Runs on the home Mac. Output goes to ~/.bento-term-dev/ (override with
# BENTO_DEV_DIR), which Tailscale Serve exposes tailnet-only at /bento-term.
# Another Mac on the tailnet then installs it with:
#   curl -fsSL https://<this-mac>.<tailnet>.ts.net/bento-term/install-dev.sh | bash
#
# The build is stamped so it can never be mistaken for a release:
#   CFBundleShortVersionString  <marketing>-dev.<shortsha>[-dirty]
#                               so About says which commit is running
#   CFBundleVersion             100000 + commit count, far above any stable
#                               build number, so Sparkle (which compares
#                               CFBundleVersion) never offers the stable
#                               release as an "update" over a dev build
#
# Signed with Developer ID, not notarized: install-dev.sh downloads with curl,
# which sets no quarantine flag, so Gatekeeper never assesses the app. The
# signing recipe mirrors .github/workflows/release.yml; keep them in step.
#
# Never touches the other Tailscale Serve mappings on this machine (they
# belong to other projects): it only adds /bento-term when it's missing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${BENTO_DEV_DIR:-$HOME/.bento-term-dev}"
SERVE_PATH="/bento-term"
IDENTITY="Developer ID Application: Chi On Ho (7M23245ZBD)"
TEAM="7M23245ZBD"
DD="$ROOT/build/dd-dev"
APP="$DD/Build/Products/Release/BentoTerm.app"
ENTITLEMENTS="$ROOT/BentoTermMac/Resources/BentoTermMac.entitlements"

say() { printf '\033[1;35m▸\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

cd "$ROOT"

# ---- preflight -------------------------------------------------------------
security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\"" \
  || die "钥匙串里没有签名证书「${IDENTITY}」。"
command -v tailscale >/dev/null 2>&1 || die "找不到 tailscale 命令。"

sha="$(git rev-parse --short=7 HEAD)"
full_sha="$(git rev-parse HEAD)"
subject="$(git log -1 --format=%s HEAD)"
dirty=""
[ -z "$(git status --porcelain)" ] || dirty="-dirty"
build_number=$((100000 + $(git rev-list --count HEAD)))

# ---- bundled tmux ----------------------------------------------------------
# The build's postCompileScript copies it into the app but only warns when
# it's missing; an app without it can't start a session on a Mac with no
# system tmux, so fetch it here and assert after the build.
scripts/fetch-bundled-tmux.sh
[ -x bundled-tmux/tmux-darwin-arm64 ] || die "bundled tmux 没下载到（scripts/fetch-bundled-tmux.sh 要 gh 已登录）。"

# ---- build -----------------------------------------------------------------
say "构建 Release（$sha${dirty}）…"
xcodebuild -project BentoTerm.xcodeproj -scheme BentoTermMac \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DD" \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  build -quiet

[ -x "$APP/Contents/MacOS/helpers/tmux" ] || die "$APP 里没有 helpers/tmux。"

# ---- stamp -----------------------------------------------------------------
# Into the BUILT Info.plist, before the re-seal below makes it part of the
# signature. (Not as xcodebuild overrides: those would hit every target.)
plist="$APP/Contents/Info.plist"
marketing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
marketing="${marketing%%-dev.*}"   # incremental builds keep the last stamp
version="${marketing}-dev.${sha}${dirty}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$plist"

# ---- sign (inside-out, same recipe as release.yml) -------------------------
say "签名 ${version}（${build_number}）…"
sign() { codesign --force --options=runtime --timestamp --sign "$IDENTITY" "$@"; }

# Sparkle's nested code arrives ad-hoc signed and Xcode only re-signs the
# framework wrapper. Versions/Current is a symlink, so skip the duplicates.
fw="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$fw" ]; then
  for nested in \
    "$fw/Versions/"*/XPCServices/*.xpc \
    "$fw/Versions/"*/Autoupdate \
    "$fw/Versions/"*/Updater.app \
    "$fw"; do
    [ -e "$nested" ] || continue
    case "$nested" in */Versions/Current/*) continue ;; esac
    sign "$nested"
  done
fi
for f in "$APP/Contents/MacOS/helpers/"*; do
  [ -f "$f" ] || continue
  sign "$f"
done
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP" || die "签名校验没通过。"

# ---- package (atomic: a download mid-publish sees the old pair or the new) --
mkdir -p "$OUT"
zip_tmp="$(mktemp "$OUT/.BentoTerm-dev.zip.XXXXXX")"
trap 'rm -f "$zip_tmp" "$zip_tmp.sha256" "$zip_tmp.txt" "$zip_tmp.sh"' EXIT
rm -f "$zip_tmp"   # ditto won't write over the placeholder mktemp made
ditto -c -k --sequesterRsrc --keepParent "$APP" "$zip_tmp"
printf '%s  BentoTerm-dev.zip\n' "$(shasum -a 256 "$zip_tmp" | awk '{print $1}')" > "$zip_tmp.sha256"
{
  echo "version: $version"
  echo "build:   $build_number"
  echo "commit:  $full_sha$dirty"
  echo "subject: $subject"
  echo "built:   $(date '+%Y-%m-%d %H:%M:%S %z')"
} > "$zip_tmp.txt"
cp "$ROOT/install-dev.sh" "$zip_tmp.sh"
chmod 644 "$zip_tmp" "$zip_tmp.sha256" "$zip_tmp.txt" "$zip_tmp.sh"

mv -f "$zip_tmp" "$OUT/BentoTerm-dev.zip"
mv -f "$zip_tmp.sha256" "$OUT/BentoTerm-dev.zip.sha256"
mv -f "$zip_tmp.txt" "$OUT/version.txt"
mv -f "$zip_tmp.sh" "$OUT/install-dev.sh"
say "已发布到 $OUT"

# ---- tailscale serve -------------------------------------------------------
# Reads `serve status --json`, finds this node's :443 web handlers, and
# reports one of: ok (already serving OUT), other:<target> (the path is taken
# by something else), funnel (443 is public), missing.
serve_state() {
  tailscale serve status --json 2>/dev/null | python3 -c '
import json, os, sys
want_path, want_dir = sys.argv[1], os.path.realpath(sys.argv[2])
try:
    cfg = json.load(sys.stdin) or {}
except ValueError:
    cfg = {}
web = cfg.get("Web") or {}
host = next((k for k in web if k.endswith(":443")), None)
if host and (cfg.get("AllowFunnel") or {}).get(host):
    print("funnel"); sys.exit()
h = ((web.get(host) or {}).get("Handlers") or {}).get(want_path) if host else None
if not h:
    print("missing")
elif h.get("Path") and os.path.realpath(h["Path"].rstrip("/")) == want_dir:
    print("ok")
else:
    print("other:" + (h.get("Path") or h.get("Proxy") or json.dumps(h)))
' "$SERVE_PATH" "$OUT"
}

state="$(serve_state)"
case "$state" in
  ok) ;;
  funnel) die "这台机器的 443 开着 Funnel（公网可达），不把 dev 构建挂上去。" ;;
  other:*) die "Tailscale 的 $SERVE_PATH 已经指向别处（${state#other:}），没动它。" ;;
  missing)
    say "Tailscale Serve 加上 $SERVE_PATH → ${OUT}（仅 tailnet）…"
    tailscale serve --bg --set-path "$SERVE_PATH" "$OUT" \
      || die "tailscale serve 没加上（这个 Tailscale 版本可能不支持直接挂目录）。"
    [ "$(serve_state)" = ok ] || die "加完之后 tailscale serve status 里还是没有 ${SERVE_PATH}。"
    ;;
  *) die "看不懂 tailscale serve status 的输出：$state" ;;
esac

dns="$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"
say "$version 可以装了。在另一台 Mac 上跑："
echo
echo "  curl -fsSL https://$dns$SERVE_PATH/install-dev.sh | bash"
echo
