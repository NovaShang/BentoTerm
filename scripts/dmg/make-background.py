#!/usr/bin/env python3
"""Draw the disk-image window background: two icon wells and an arrow between.

The .dmg window is a plain Finder window; the only thing telling a first-time
user what to do is what is painted behind the icons. So the background carries
the whole instruction — app on the left, Applications on the right, an arrow
pointing from one to the other.

Written as a script rather than a checked-in binary so the geometry stays in
step with `appdmg.json`: the icon coordinates there and the wells here are the
same numbers, and a change to one that is not made to the other is visible in
the diff.

    python3 scripts/dmg/make-background.py scripts/dmg

writes background.png (1x) and background@2x.png; the release workflow folds
them into a multi-resolution background.tiff with `tiffutil -cathidpicheck`, so
the window is crisp on Retina without shipping a soft upscale.
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

# Must match window.size and contents[].x/y in appdmg.json.
W, H = 660, 400
ICON_Y = 190          # centre of both icons
APP_X, LINK_X = 165, 495

PAPER = (247, 247, 249)
WELL = (238, 238, 241)
ARROW = (150, 150, 158)
TEXT = (120, 120, 128)


def draw(scale: int) -> Image.Image:
    s = scale
    img = Image.new("RGB", (W * s, H * s), PAPER)
    d = ImageDraw.Draw(img)

    # Wells: a faint rounded square behind each icon, so the two drop points
    # read as a pair even before the icons load.
    r = 62 * s
    for cx in (APP_X, LINK_X):
        box = (cx * s - r, ICON_Y * s - r, cx * s + r, ICON_Y * s + r)
        d.rounded_rectangle(box, radius=18 * s, fill=WELL)

    # Arrow between the wells.
    y = ICON_Y * s
    x0, x1 = (APP_X + 80) * s, (LINK_X - 80) * s
    d.line((x0, y, x1, y), fill=ARROW, width=max(2, 2 * s))
    head = 11 * s
    d.polygon([(x1, y), (x1 - head, y - head * 0.62), (x1 - head, y + head * 0.62)], fill=ARROW)

    # One line of plain instruction under the icons.
    caption = "Drag BentoTerm to your Applications folder"
    size = 14 * s
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    except OSError:
        font = ImageFont.load_default(size)
    tw = d.textlength(caption, font=font)
    d.text(((W * s - tw) / 2, (ICON_Y + 92) * s), caption, font=font, fill=TEXT)
    return img


def main() -> None:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    out.mkdir(parents=True, exist_ok=True)
    draw(1).save(out / "background.png")
    draw(2).save(out / "background@2x.png")
    print(f"wrote {out}/background.png and background@2x.png")


if __name__ == "__main__":
    main()
