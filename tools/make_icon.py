"""Draws the SportTread app icon: a glowing heartbeat line over a forward-leaning treadmill belt.

Usage: python tools/make_icon.py
Writes the 1024x1024 icon into the iPhone and Watch asset catalogs.
"""
import pathlib

from PIL import Image, ImageDraw, ImageFilter, ImageOps

ROOT = pathlib.Path(__file__).resolve().parent.parent
PHONE_ICON = ROOT / "SportTread/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
# watchOS crops icons to a circle, so the watch version is shrunk to keep everything inside it
WATCH_ICON = ROOT / "SportTreadWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
WATCH_SCALE = 0.84

S = 2048  # drawn at 2x, then downscaled for smooth edges
BG_DARK = (9, 11, 14)
BG_LIGHT = (32, 37, 46)
VOLT = (198, 255, 0)
BELT = (226, 232, 242)
SHEAR = 0.24  # forward lean of the belt


def u(v: float) -> int:
    """Design units are 0..1024."""
    return round(v * S / 1024)


def background() -> Image.Image:
    # Diagonal graphite gradient, lighter top-left
    grad = Image.linear_gradient("L").resize((S * 2, S * 2)).rotate(45, resample=Image.BICUBIC)
    grad = grad.crop((S // 2, S // 2, S // 2 + S, S // 2 + S))
    return ImageOps.colorize(ImageOps.invert(grad), BG_DARK, BG_LIGHT).convert("RGBA")


def stroke(draw: ImageDraw.ImageDraw, points, width, fill):
    pts = [(u(x), u(y)) for x, y in points]
    draw.line(pts, fill=fill, width=u(width), joint="curve")
    r = u(width) / 2
    for x, y in (pts[0], pts[-1]):
        draw.ellipse([x - r, y - r, x + r, y + r], fill=fill)


def belt_layer() -> Image.Image:
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle([u(196), u(700), u(828), u(822)], radius=u(61), outline=BELT + (255,), width=u(26))
    for cx in (258, 766):  # rollers
        d.ellipse([u(cx - 19), u(742), u(cx + 19), u(780)], fill=BELT + (255,))
    for x in (372, 452, 532, 612):  # tread marks, fading toward the back
        alpha = 90 + (x - 372) // 2
        d.rounded_rectangle([u(x), u(753), u(x + 44), u(769)], radius=u(8), fill=BELT + (alpha,))
    # Lean forward: shift the top of the belt right, pivoting on the belt's centre line
    k, cy = SHEAR, u(761)
    return layer.transform((S, S), Image.AFFINE, (1, k, -k * cy, 0, 1, 0), resample=Image.BICUBIC)


def pulse_layer() -> Image.Image:
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    points = [(150, 432), (380, 432), (418, 486), (478, 214), (552, 640), (606, 432), (842, 432)]
    stroke(d, points, 46, VOLT + (255,))
    d.ellipse([u(842 - 34), u(432 - 34), u(842 + 34), u(432 + 34)], fill=VOLT + (255,))  # live dot
    return layer


pulse = pulse_layer()
art = Image.new("RGBA", (S, S), (0, 0, 0, 0))
# Glow under the pulse line: a wide soft halo plus a tighter bright one
for radius in (60, 22):
    art = Image.alpha_composite(art, pulse.filter(ImageFilter.GaussianBlur(u(radius))))
art = Image.alpha_composite(art, belt_layer())
art = Image.alpha_composite(art, pulse)

bg = background()
icon = Image.alpha_composite(bg, art).convert("RGB").resize((1024, 1024), Image.LANCZOS)

side = round(S * WATCH_SCALE)
small = Image.new("RGBA", (S, S), (0, 0, 0, 0))
small.paste(art.resize((side, side), Image.LANCZOS), ((S - side) // 2, (S - side) // 2))
watch = Image.alpha_composite(bg, small).convert("RGB").resize((1024, 1024), Image.LANCZOS)

for path, image in ((PHONE_ICON, icon), (WATCH_ICON, watch)):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, "PNG")
    print("wrote", path.relative_to(ROOT))
