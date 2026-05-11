#!/usr/bin/env python3
"""
Build packaging/AppIcon-1024.png from a source brand-mark PNG.

The source is a square PNG (any size) of the Orgo brand mark — solid orange
background with the white ring centered. This script:

  1. Resizes the source down to the macOS Big Sur+ inner-icon bounds (824x824
     centered inside a 1024x1024 transparent canvas, ~100 px margin on each
     side — Apple's spec).
  2. Applies a continuous-curvature squircle mask (185 px corner radius on
     824 = ~22.5 %, supersampled 4x for clean anti-aliased edges).
  3. Lays in three subtle polish layers used by Apple's modern macOS icons:
       - vertical multiply gradient (~6 % lighter at top, ~6 % darker at
         bottom) — gives the icon "weight" without reading as a gradient
       - thin top specular highlight — suggests a top-down light source on a
         slightly glossy surface
       - thin bottom inset shadow — anchors the icon, makes the squircle
         feel solid rather than flat

After this script writes AppIcon-1024.png, scripts/build-macos-app.sh
regenerates the iconset variants and the .icns automatically.

Usage:
    python3 scripts/build-app-icon.py /path/to/source-brand.png

Defaults to the canonical Orgo source if no path is given.
"""

from __future__ import annotations

import pathlib
import sys

from PIL import Image, ImageChops, ImageDraw

# Apple's macOS Big Sur+ icon spec
CANVAS = 1024
INNER = 824
OFFSET = (CANVAS - INNER) // 2
RADIUS = 185
SUPERSAMPLE = 4

# Polish dials — small numbers on purpose; "luxury" reads as restraint.
GRADIENT_TOP_LIFT = 0.06
GRADIENT_BOTTOM_DARKEN = 0.06
HIGHLIGHT_HEIGHT_FRAC = 0.20
HIGHLIGHT_PEAK_ALPHA = 38
SHADOW_HEIGHT_FRAC = 0.10
SHADOW_PEAK_ALPHA = 28


def make_squircle_mask(size: int) -> Image.Image:
    big = size * SUPERSAMPLE
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, big - 1, big - 1),
        radius=RADIUS * SUPERSAMPLE,
        fill=255,
    )
    return mask.resize((size, size), Image.LANCZOS)


def vertical_l_column(height: int, alpha_at_y) -> Image.Image:
    col = Image.new("L", (1, height))
    px = col.load()
    for y in range(height):
        t = y / (height - 1) if height > 1 else 0.0
        px[0, y] = max(0, min(255, round(alpha_at_y(t))))
    return col


def main(src_path: pathlib.Path, out_path: pathlib.Path) -> None:
    if not src_path.exists():
        print(f"Source not found: {src_path}", file=sys.stderr)
        sys.exit(1)

    brand = Image.open(src_path).convert("RGBA").resize((INNER, INNER), Image.LANCZOS)
    squircle_mask = make_squircle_mask(INNER)

    # Vertical bg gradient via multiply blend
    def gradient_value(t: float) -> float:
        delta = GRADIENT_TOP_LIFT - (GRADIENT_TOP_LIFT + GRADIENT_BOTTOM_DARKEN) * t
        return 255 * (1.0 + delta)

    grad_l = vertical_l_column(INNER, gradient_value).resize((INNER, INNER))
    grad_rgb = Image.merge("RGB", (grad_l, grad_l, grad_l))
    brand_rgb = brand.convert("RGB")
    brand_lit = ImageChops.multiply(brand_rgb, grad_rgb).convert("RGBA")
    brand_lit.putalpha(brand.getchannel("A"))

    # Top specular highlight
    hh = int(INNER * HIGHLIGHT_HEIGHT_FRAC)

    def highlight_alpha_at(t: float) -> float:
        y_pix = t * (INNER - 1)
        if y_pix >= hh:
            return 0.0
        local_t = y_pix / (hh - 1) if hh > 1 else 0.0
        return HIGHLIGHT_PEAK_ALPHA * (1 - local_t) ** 1.5

    highlight_alpha = vertical_l_column(INNER, highlight_alpha_at).resize((INNER, INNER))
    highlight = Image.new("RGBA", (INNER, INNER), (255, 255, 255, 0))
    highlight.putalpha(highlight_alpha)

    # Bottom inset shadow
    sh = int(INNER * SHADOW_HEIGHT_FRAC)
    shadow_start = INNER - sh

    def shadow_alpha_at(t: float) -> float:
        y_pix = t * (INNER - 1)
        if y_pix < shadow_start:
            return 0.0
        local_t = (y_pix - shadow_start) / (sh - 1) if sh > 1 else 0.0
        return SHADOW_PEAK_ALPHA * (local_t**1.2)

    shadow_alpha = vertical_l_column(INNER, shadow_alpha_at).resize((INNER, INNER))
    shadow = Image.new("RGBA", (INNER, INNER), (0, 0, 0, 0))
    shadow.putalpha(shadow_alpha)

    # Composite, clip with squircle, place in 1024 canvas
    stack = Image.new("RGBA", (INNER, INNER), (0, 0, 0, 0))
    stack.alpha_composite(brand_lit)
    stack.alpha_composite(highlight)
    stack.alpha_composite(shadow)

    clipped = Image.new("RGBA", (INNER, INNER), (0, 0, 0, 0))
    clipped.paste(stack, (0, 0), squircle_mask)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(clipped, (OFFSET, OFFSET), clipped)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(out_path, format="PNG", optimize=True)
    print(f"Wrote {out_path} ({out_path.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    default_src = (
        pathlib.Path.home()
        / "Downloads"
        / ("ig_0c92a172ea0e2f1f0169f80d7e290c8196bd19f46153a16b82.png")
    )
    src = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else default_src
    out = repo_root / "packaging" / "AppIcon-1024.png"
    main(src, out)
