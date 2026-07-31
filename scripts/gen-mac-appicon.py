#!/usr/bin/env python3
"""Generate the macOS app-icon PNGs from docs/bento-icon.svg.

macOS app icons must bake the rounded-square (squircle) shape AND the standard
canvas margin into the artwork. macOS 26 (Tahoe) auto-masks a full-bleed icon
into a squircle, but older macOS does NOT — it renders a full-bleed square as a
hard rectangle. So we render the art into the Apple icon grid: an 824x824 body
(squircle-masked) centered on a 1024 transparent canvas (100px margin), then
downscale to every size the asset catalog needs.

Squircle = n=5 superellipse, supersampled for clean anti-aliasing. Pure PIL +
math (no numpy). Requires rsvg-convert for the SVG render.

Usage: python3 scripts/gen-mac-appicon.py
"""
import math
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SVG = ROOT / "docs" / "bento-icon.svg"
OUT = ROOT / "BentoTermMac" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"

CANVAS = 1024          # full icon canvas
BODY = 824             # Apple icon-grid body (≈80% of canvas)
MARGIN = (CANVAS - BODY) // 2   # 100px each side
SUPERELLIPSE_N = 5.0   # squircle exponent (iOS/macOS-like continuous corners)
SS = 4                 # supersample factor for the mask
# Asset-catalog filenames → pixel size (see Contents.json).
SIZES = {1024: "icon_1024.png", 512: "icon_512.png", 256: "icon_256.png",
         128: "icon_128.png", 64: "icon_64.png", 32: "icon_32.png", 16: "icon_16.png"}


def squircle_mask(size: int) -> Image.Image:
    """An anti-aliased n=5 superellipse mask ('L'), white inside."""
    hi = size * SS
    mask = Image.new("L", (hi, hi), 0)
    r = hi / 2.0
    pts = []
    steps = 720
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = r + r * math.copysign(abs(ct) ** (2.0 / SUPERELLIPSE_N), ct)
        y = r + r * math.copysign(abs(st) ** (2.0 / SUPERELLIPSE_N), st)
        pts.append((x, y))
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def main() -> int:
    if not SVG.exists():
        print(f"missing source: {SVG}", file=sys.stderr)
        return 1
    art_png = Path("/tmp/bento-art-body.png")
    subprocess.run(["rsvg-convert", "-w", str(BODY), "-h", str(BODY),
                    str(SVG), "-o", str(art_png)], check=True)

    art = Image.open(art_png).convert("RGBA")
    art.putalpha(squircle_mask(BODY))

    base = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    base.alpha_composite(art, (MARGIN, MARGIN))

    for px, name in SIZES.items():
        img = base if px == CANVAS else base.resize((px, px), Image.LANCZOS)
        img.save(OUT / name)
        print(f"wrote {name} ({px}x{px})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
