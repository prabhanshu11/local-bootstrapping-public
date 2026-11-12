#!/usr/bin/env -S uv run --quiet --script
# /// script
# dependencies = ["pillow>=10"]
# requires-python = ">=3.11"
# ///
"""make-moon-icon.py — the VDI bar icon: a real photo of the Moon with the crater contrast boosted.

His words (2026-11-01): "change my moonshot icon on top bar so that its visible, make it a realistic
photo of the moon, inclease the contrast of the craters . And club moonlight and sunshine icons."

Source (public domain, NASA/JPL): PIA00405, Galileo spacecraft, 1992-12-07,
https://images-assets.nasa.gov/image/PIA00405/PIA00405~orig.jpg  — kept beside this script as
moon-source-PIA00405.jpg (the untouched original).

Outputs (next to this script, each PNG carries tEXt provenance: source, pipeline, created, params):
  moon-22.png   bar icon, normal mode (22 px)
  moon-32.png   bar icon, touch mode (32 px)
  moon-96.png   intro screen tile / about

Run:  dotfiles/waybar/icons/make-moon-icon.py        (uv fetches pillow into its cache; no env touched)
"""
import datetime, os
from PIL import Image, ImageEnhance, ImageFilter, ImageOps, ImageDraw
from PIL.PngImagePlugin import PngInfo

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "moon-source-PIA00405.jpg")
SRC_URL = "https://images-assets.nasa.gov/image/PIA00405/PIA00405~orig.jpg"
PIPELINE = "local-bootstrapping/dotfiles/waybar/icons/make-moon-icon.py"
CONTRAST, SHARPEN_PCT, SHARPEN_RADIUS = 1.55, 180, 2.0


def disk_bbox(gray, thresh=24):
    """Bounding box of the lit disc (the photo is a full moon on black)."""
    return gray.point(lambda v: 255 if v > thresh else 0).getbbox()


def main():
    img = Image.open(SRC).convert("RGB")
    gray = ImageOps.grayscale(img)
    box = disk_bbox(gray)
    moon = img.crop(box)
    w, h = moon.size
    side = max(w, h)
    sq = Image.new("RGB", (side, side), (0, 0, 0))
    sq.paste(moon, ((side - w) // 2, (side - h) // 2))
    # Crater contrast: stretch the histogram, then local contrast (unsharp mask with a wide radius)
    # and a global contrast push. Keep it a photo: no posterising, no colour.
    sq = ImageOps.grayscale(sq).convert("RGB")   # a grey moon: no colour fringes at 22 px
    sq = ImageOps.autocontrast(sq, cutoff=0.5)
    sq = sq.filter(ImageFilter.UnsharpMask(radius=side / 40, percent=160, threshold=2))
    sq = ImageEnhance.Contrast(sq).enhance(CONTRAST)
    sq = sq.filter(ImageFilter.UnsharpMask(radius=SHARPEN_RADIUS, percent=SHARPEN_PCT, threshold=1))
    created = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    for size in (22, 32, 96):
        # Render at 4x then downsample so the limb is smooth; alpha = soft circle.
        big = size * 4
        small = sq.resize((big, big), Image.LANCZOS)
        mask = Image.new("L", (big, big), 0)
        ImageDraw.Draw(mask).ellipse((1, 1, big - 2, big - 2), fill=255)
        mask = mask.filter(ImageFilter.GaussianBlur(1.2))
        small.putalpha(mask)
        out = small.resize((size, size), Image.LANCZOS)
        if size <= 32:   # tiny sizes lose the craters in the downsample: one more local-contrast pass
            rgb = ImageEnhance.Contrast(out.convert("RGB")).enhance(1.15)
            rgb = rgb.filter(ImageFilter.UnsharpMask(radius=1.0, percent=120, threshold=0))
            a = out.getchannel("A")
            out = rgb.convert("RGBA")
            out.putalpha(a)
        meta = PngInfo()
        meta.add_text("source", f"{SRC_URL} (NASA/JPL PIA00405, public domain; local copy {os.path.relpath(SRC, HERE)})")
        meta.add_text("pipeline", PIPELINE)
        meta.add_text("created", created)
        meta.add_text("params", f"crop={box} autocontrast=1% unsharp=({side/40:.1f},160) contrast={CONTRAST} "
                                f"unsharp=({SHARPEN_RADIUS},{SHARPEN_PCT}) size={size}")
        path = os.path.join(HERE, f"moon-{size}.png")
        out.save(path, pnginfo=meta, optimize=True)
        print(path)


if __name__ == "__main__":
    main()
