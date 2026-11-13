#!/usr/bin/env python3
"""Render Sinhron app icon (SinhronMark on accent gradient) at all iOS sizes.

Design:
  - 1024×1024 master, rendered at 2x supersampling for crisp downsampling.
  - Background: vertical gradient #4889FF → #1C5BE0 (accent ±).
  - Glyph: SinhronMark (56-viewBox), scaled to 70% of icon.
      • Left ring: 3.5-stroke white, no fill, center (22,28) r=14
      • Right disk: white fill, center (34,28) r=14
      • Sync arc: 3.5-stroke accent #2D6FF7, half-circle (22,14)→(22,42) curving right
  - No transparency, no baked-in rounded corners (iOS adds them).
"""
from pathlib import Path

from PIL import Image, ImageDraw

ACCENT_TOP = (72, 137, 255)   # #4889FF
ACCENT_BOT = (28, 91, 224)    # #1C5BE0
ACCENT_MID = (45, 111, 247)   # #2D6FF7 — sync arc stroke
WHITE = (255, 255, 255)

SUPER = 2048                  # supersampled master (final = 1024)
PAD_FRACTION = 0.06           # 6 % padding — mark fills the tile prominently
VIEW_BOX = 56                 # SinhronMark coordinate space
# Mark visual bbox inside 56 viewBox is x:8..48 (w=40), y:14..42 (h=28). We
# rescale by the wider axis so the mark fills the icon edge-to-edge horizontally
# with a small breathing margin set by PAD_FRACTION.
MARK_BBOX_W = 40
STROKE_VB = 4.0               # thicker stroke than glyph (3.0) for icon legibility


def render_master(super_size: int) -> Image.Image:
    """Render the icon at super-sampled resolution."""
    img = Image.new("RGB", (super_size, super_size), ACCENT_TOP)
    draw = ImageDraw.Draw(img)

    # Vertical gradient background
    for y in range(super_size):
        t = y / (super_size - 1)
        rgb = (
            int(ACCENT_TOP[0] * (1 - t) + ACCENT_BOT[0] * t),
            int(ACCENT_TOP[1] * (1 - t) + ACCENT_BOT[1] * t),
            int(ACCENT_TOP[2] * (1 - t) + ACCENT_BOT[2] * t),
        )
        draw.line([(0, y), (super_size, y)], fill=rgb)

    # Mark geometry — scale so the 40-unit-wide visual bbox occupies
    # (1 - 2*PAD_FRACTION) of the icon edge. Center on the icon.
    available = super_size * (1 - 2 * PAD_FRACTION)
    scale = available / MARK_BBOX_W
    # Centroid of the mark visual bbox in viewBox coords: (28, 28).
    cx_vb, cy_vb = 28, 28
    offset_x = super_size / 2 - cx_vb * scale
    offset_y = super_size / 2 - cy_vb * scale
    stroke = STROKE_VB * scale

    def pt(x_vb: float, y_vb: float) -> tuple[float, float]:
        return (offset_x + x_vb * scale, offset_y + y_vb * scale)

    def circle_bbox(cx_vb: float, cy_vb: float, r_vb: float):
        cx, cy = pt(cx_vb, cy_vb)
        r = r_vb * scale
        return (cx - r, cy - r, cx + r, cy + r)

    # Left ring (stroke = white, no fill)
    draw.ellipse(circle_bbox(22, 28, 14), outline=WHITE, width=round(stroke))
    # Right disk (white fill)
    draw.ellipse(circle_bbox(34, 28, 14), fill=WHITE)
    # Sync arc — accent stroke cutting through right disk.
    # Half-circle (22,14) → (22,42), curving right through (36,28).
    # Full-circle bbox in viewBox: (8,14)-(36,42).
    arc_bbox = (*pt(8, 14), *pt(36, 42))
    draw.arc(arc_bbox, start=-90, end=90, fill=ACCENT_MID, width=round(stroke))

    return img


# Required iOS sizes: (pt_size, scale, filename)
SIZES = [
    (20, 1, "Icon-App-20x20@1x.png"),
    (20, 2, "Icon-App-20x20@2x.png"),
    (20, 3, "Icon-App-20x20@3x.png"),
    (29, 1, "Icon-App-29x29@1x.png"),
    (29, 2, "Icon-App-29x29@2x.png"),
    (29, 3, "Icon-App-29x29@3x.png"),
    (40, 1, "Icon-App-40x40@1x.png"),
    (40, 2, "Icon-App-40x40@2x.png"),
    (40, 3, "Icon-App-40x40@3x.png"),
    (60, 2, "Icon-App-60x60@2x.png"),
    (60, 3, "Icon-App-60x60@3x.png"),
    (76, 1, "Icon-App-76x76@1x.png"),
    (76, 2, "Icon-App-76x76@2x.png"),
    (83.5, 2, "Icon-App-83.5x83.5@2x.png"),
    (1024, 1, "Icon-App-1024x1024@1x.png"),
]


def main() -> None:
    out_dir = Path(__file__).resolve().parents[1] / (
        "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    )
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Rendering master at {SUPER}×{SUPER}…")
    master = render_master(SUPER)

    for pt_size, scale, name in SIZES:
        px = round(pt_size * scale)
        img = master.resize((px, px), Image.LANCZOS)
        # Marketing icon must be fully opaque RGB (no alpha) per App Store rules.
        img.save(out_dir / name, "PNG", optimize=True)
        print(f"  {name:36s} {px:4d}×{px}")

    print(f"\nWrote {len(SIZES)} icons → {out_dir}")


if __name__ == "__main__":
    main()
