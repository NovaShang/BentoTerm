#!/usr/bin/env bash
# build-bundled-tmux.sh — produces the tmux binary that ships inside bento.
#
# What this does
#   Downloads tmux + libevent source tarballs, builds tmux statically linked
#   against libevent (libevent is the only awkward dep — ncurses is stable
#   enough across distros and macOS that we link it dynamically). Outputs:
#       bundled-tmux/tmux-<os>-<arch>
#
# Why static libevent
#   libevent versioning varies between distros (Ubuntu LTS lags Homebrew by
#   years), so linking it dynamically would mean the bundled tmux works on
#   one machine and not another. Static libevent makes the binary portable
#   inside a major-OS/arch slot.
#
# When to run
#   Not part of every dev build. Run once per release, commit the resulting
#   binaries to a release artifact and have CI + dev builds fetch them with
#   scripts/fetch-bundled-tmux.sh. The Mac app's postCompile script copies
#   the host-slot binary into BentoTerm.app/Contents/MacOS/helpers/tmux.
#
# Cross-compiling
#   This script only builds for the *host* OS/arch. To produce all targets
#   (macOS arm64+x86_64, Linux arm64+x86_64), run this on each platform —
#   the simplest setup is GitHub Actions with a matrix.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Versions live in one file so build + fetch + release tag never drift.
# shellcheck disable=SC1091
source "$ROOT/scripts/bundled-tmux.version"
OUT_DIR="$ROOT/bundled-tmux"
WORK_DIR="${WORK_DIR:-$ROOT/.build/tmux}"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "$arch" in
  arm64|aarch64) arch="arm64" ;;
  x86_64|amd64)  arch="x86_64" ;;
  *) echo "unsupported arch: $arch" >&2; exit 1 ;;
esac
case "$os" in
  darwin|linux) ;;
  *) echo "unsupported os: $os" >&2; exit 1 ;;
esac

OUT="$OUT_DIR/tmux-$os-$arch"
mkdir -p "$OUT_DIR" "$WORK_DIR"
cd "$WORK_DIR"

echo "==> Building tmux $TMUX_VERSION (libevent $LIBEVENT_VERSION) → $OUT"

# --- libevent (static) ---
if [ ! -f "libevent-$LIBEVENT_VERSION/.built" ]; then
  if [ ! -f "libevent-$LIBEVENT_VERSION.tar.gz" ]; then
    curl -fsSL -o "libevent-$LIBEVENT_VERSION.tar.gz" \
      "https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VERSION/libevent-$LIBEVENT_VERSION.tar.gz"
  fi
  rm -rf "libevent-$LIBEVENT_VERSION"
  tar xzf "libevent-$LIBEVENT_VERSION.tar.gz"
  (
    cd "libevent-$LIBEVENT_VERSION"
    # --disable-openssl: we don't need TLS-aware bufferevents for tmux IPC,
    # and dropping it removes a fat dep that varies wildly across systems.
    ./configure --prefix="$WORK_DIR/install" --disable-shared --enable-static \
      --disable-openssl --disable-samples --disable-debug-mode >/dev/null
    make -j"$(getconf _NPROCESSORS_ONLN)" >/dev/null
    make install >/dev/null
    touch .built
  )
fi

# --- tmux ---
if [ ! -f "tmux-$TMUX_VERSION.tar.gz" ]; then
  curl -fsSL -o "tmux-$TMUX_VERSION.tar.gz" \
    "https://github.com/tmux/tmux/releases/download/$TMUX_VERSION/tmux-$TMUX_VERSION.tar.gz"
fi
rm -rf "tmux-$TMUX_VERSION"
tar xzf "tmux-$TMUX_VERSION.tar.gz"
(
  cd "tmux-$TMUX_VERSION"
  # PKG_CONFIG_PATH points at our static libevent. We deliberately do NOT
  # try to also static-link ncurses: it requires a terminfo database at
  # runtime that must match the host, so dynamic linking against the OS
  # ncurses is the only sane choice.
  #
  # --enable-static is Linux-only — macOS rejects it because Apple doesn't
  # ship static system libs. On macOS we still get static libevent (the
  # only awkward dep) via PKG_CONFIG_PATH preferring the .a we just built;
  # the remaining links (libSystem, ncurses) hit stable OS libs and are
  # fine to resolve dynamically.
  #
  # --disable-utf8proc: tmux 3.5+ requires an explicit yes/no here. We say
  # no because the bundle should stay dep-free; wide-char/grapheme width
  # handling is done client-side, not by tmux itself. Revisit if direct
  # local tmux use needs better CJK width.
  configure_flags="--disable-utf8proc"
  if [ "$os" = "linux" ]; then
    configure_flags="$configure_flags --enable-static"
  fi
  PKG_CONFIG_PATH="$WORK_DIR/install/lib/pkgconfig" \
    ./configure $configure_flags >/dev/null
  make -j"$(getconf _NPROCESSORS_ONLN)" >/dev/null
)

cp "tmux-$TMUX_VERSION/tmux" "$OUT"
chmod +x "$OUT"

# Verify it actually runs (catches dynamic-link surprises).
"$OUT" -V

# Emit a sha256 sidecar — uploaded alongside the binary to the GH release
# so fetch-bundled-tmux.sh can verify integrity.
( cd "$OUT_DIR" && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256" )

echo "==> Done: $OUT"
echo "    size: $(du -h "$OUT" | cut -f1)"
echo "    sha256: $(cat "$OUT.sha256")"
