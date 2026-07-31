#!/usr/bin/env bash
# fetch-bundled-tmux.sh — downloads the prebuilt tmux for the host OS/arch
# from the GitHub release pinned in scripts/bundled-tmux.version. Intended
# for everyday use (CI + local dev); building from source is the rare path.
#
# Idempotent: if the right version is already present, exits 0 silently.
# Missing release (e.g. version bumped but the build workflow hasn't run
# yet) prints a clear message and exits 0 — the runtime resolver will fall
# back to system tmux, so a missing bundle is not a hard build failure.
#
# Environment overrides:
#   BUNDLED_TMUX_DIR   where to write the binary (default: bundled-tmux/)
#   GITHUB_REPO        which repo to fetch from (default: derived from `git remote`)
#   GH                 path to gh CLI (default: `gh` on PATH)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/bundled-tmux.version"

OUT_DIR="${BUNDLED_TMUX_DIR:-$ROOT/bundled-tmux}"
GH_BIN="${GH:-gh}"

# Detect host os/arch and map to the asset name format the release uses.
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "$arch" in
  arm64|aarch64) arch="arm64" ;;
  x86_64|amd64)  arch="x86_64" ;;
  *) echo "fetch-bundled-tmux: unsupported arch $arch — skipping" >&2; exit 0 ;;
esac
case "$os" in
  darwin|linux) ;;
  *) echo "fetch-bundled-tmux: unsupported os $os — skipping" >&2; exit 0 ;;
esac

ASSET="tmux-$os-$arch"
SUM_ASSET="$ASSET.sha256"
DEST="$OUT_DIR/$ASSET"
VERSION_MARKER="$OUT_DIR/.version-$RELEASE_TAG-$os-$arch"

mkdir -p "$OUT_DIR"

# Already have the right version? Done.
if [ -f "$DEST" ] && [ -f "$VERSION_MARKER" ]; then
  exit 0
fi

# Locate gh — if it's missing, we don't try to install it; CI knows to set
# it up, and devs without gh can still build (resolver will use system tmux).
if ! command -v "$GH_BIN" >/dev/null 2>&1; then
  echo "fetch-bundled-tmux: gh CLI not installed — skipping (system tmux will be used)" >&2
  exit 0
fi

# Need a repo to query. `gh release download` infers it from the current
# git checkout's origin remote; if that's missing we accept GITHUB_REPO.
# Use a string + word-splitting (rather than a bash array) so this stays
# happy under `set -u` even when the override isn't set.
repo_flag=""
if [ -n "${GITHUB_REPO:-}" ]; then
  repo_flag="--repo $GITHUB_REPO"
fi

echo "fetch-bundled-tmux: downloading $ASSET from $RELEASE_TAG"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# shellcheck disable=SC2086  # intentional word-splitting of repo_flag
if ! "$GH_BIN" release download "$RELEASE_TAG" $repo_flag \
       --pattern "$ASSET" --pattern "$SUM_ASSET" --dir "$tmp" 2>/tmp/fetch-bundled-tmux.err; then
  echo "fetch-bundled-tmux: release $RELEASE_TAG not found or assets missing — falling back to system tmux at runtime" >&2
  cat /tmp/fetch-bundled-tmux.err >&2 || true
  exit 0
fi

# Verify checksum if present. Missing checksum file is a soft warning so
# we don't block first-bring-up of a new release tag.
if [ -f "$tmp/$SUM_ASSET" ]; then
  ( cd "$tmp" && shasum -a 256 -c "$SUM_ASSET" ) >/dev/null
else
  echo "fetch-bundled-tmux: warning — no checksum file in release, skipping verification" >&2
fi

mv "$tmp/$ASSET" "$DEST"
chmod +x "$DEST"

# Wipe stale version markers so only one is ever present per slot.
find "$OUT_DIR" -maxdepth 1 -name ".version-*-$os-$arch" -delete 2>/dev/null || true
touch "$VERSION_MARKER"

echo "fetch-bundled-tmux: installed $DEST ($("$DEST" -V 2>/dev/null || echo '?'))"
