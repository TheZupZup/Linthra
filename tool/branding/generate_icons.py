#!/usr/bin/env python3
"""Generate Linthra's launcher icons and store graphics from one source design.

Linthra's mark is an abstract "L" monogram made of audio: a bold vertical spine
and a horizontal foot form the letter, while a short equalizer crescendo rises
from the foot so the "L" still reads as sound. It carries the brand's two
colours as a single violet→orange gradient on a dark, premium squircle.

This script is the single source of truth for that mark: it renders every raster
asset the app and the F-Droid/Fastlane listing need, so the icon never drifts
between sizes and can be regenerated deterministically.

It is a *developer tool*, not part of the app build, and depends only on the
Python standard library (no Pillow / native image tools required): it rasterises
with supersampling and writes PNGs directly via zlib. The canonical vector
source lives next to it in linthra_icon.svg.

Outputs (paths relative to the repo root):
  - android/app/src/main/res/mipmap-*/ic_launcher.png        (legacy launcher)
  - android/app/src/main/res/mipmap-*/ic_launcher_foreground.png (adaptive fg)
  - fastlane/metadata/android/en-US/images/icon.png          (512x512)
  - fastlane/metadata/android/en-US/images/featureGraphic.png (1024x500)

The adaptive background is a vector gradient drawable (ic_launcher_background.xml)
and is not generated here. Run from the repo root:
  python3 tool/branding/generate_icons.py
"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

# Brand palette (kept in step with lib/app/colors.dart).
# Squircle / banner background: a dark, premium violet-black.
BG_TOP = (0x1C, 0x17, 0x30)
BG_BOTTOM = (0x10, 0x0E, 0x18)
# The mark: a single violet→orange gradient (brandBright → accent), mapped
# across the mark's shared vertical span so it reads as one sweep of motion.
MARK_TOP = (0x9C, 0x84, 0xFF)
MARK_BOTTOM = (0xFF, 0x9F, 0x43)

# The mark, in fractional [0, 1] coordinates of its square region. An abstract
# "L" — a vertical spine plus a horizontal foot — with a three-step equalizer
# crescendo rising from the foot. Shape tuples:
#   ("v", cx, half_width, top, bottom)   vertical capsule (rounded bar)
#   ("h", cy, half_height, left, right)  horizontal capsule (rounded bar)
MARK = (
    ("v", 0.17, 0.095, 0.07, 0.92),   # spine — the stem of the "L"
    ("h", 0.85, 0.060, 0.17, 0.93),   # foot — the base of the "L"
    ("v", 0.46, 0.055, 0.50, 0.79),   # equalizer tick — short
    ("v", 0.64, 0.055, 0.33, 0.79),   # equalizer tick — tall (the beat)
    ("v", 0.82, 0.055, 0.47, 0.79),   # equalizer tick — mid
)

REPO_ROOT = Path(__file__).resolve().parents[2]
RES_DIR = REPO_ROOT / "android/app/src/main/res"
FASTLANE_IMAGES = REPO_ROOT / "fastlane/metadata/android/en-US/images"

# Legacy square launcher icon, per density (dp size 48 * density).
LEGACY_SIZES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}
# Adaptive foreground, per density (dp size 108 * density).
FOREGROUND_SIZES = {
    "mdpi": 108,
    "hdpi": 162,
    "xhdpi": 216,
    "xxhdpi": 324,
    "xxxhdpi": 432,
}


def _lerp(a: int, b: int, t: float) -> int:
    return round(a + (b - a) * t)


def _bg_row(y: float, height: int) -> tuple[int, int, int]:
    t = y / max(height - 1, 1)
    return (
        _lerp(BG_TOP[0], BG_BOTTOM[0], t),
        _lerp(BG_TOP[1], BG_BOTTOM[1], t),
        _lerp(BG_TOP[2], BG_BOTTOM[2], t),
    )


def _mark_row(y: float, top: float, bottom: float) -> tuple[int, int, int]:
    span = max(bottom - top, 1.0)
    t = (y - top) / span
    t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
    return (
        _lerp(MARK_TOP[0], MARK_BOTTOM[0], t),
        _lerp(MARK_TOP[1], MARK_BOTTOM[1], t),
        _lerp(MARK_TOP[2], MARK_BOTTOM[2], t),
    )


def _in_rounded_rect(
    x: float, y: float, left: float, top: float, right: float,
    bottom: float, radius: float,
) -> bool:
    if x < left or x > right or y < top or y > bottom:
        return False
    cx = min(max(x, left + radius), right - radius)
    cy = min(max(y, top + radius), bottom - radius)
    dx = x - cx
    dy = y - cy
    return dx * dx + dy * dy <= radius * radius


def _in_vcapsule(
    x: float, y: float, cx: float, half_width: float, top: float,
    bottom: float,
) -> bool:
    if abs(x - cx) > half_width:
        return False
    inner_top = top + half_width
    inner_bottom = bottom - half_width
    if inner_top <= y <= inner_bottom:
        return True
    anchor_y = inner_top if y < inner_top else inner_bottom
    dx = x - cx
    dy = y - anchor_y
    return dx * dx + dy * dy <= half_width * half_width


def _in_hcapsule(
    x: float, y: float, cy: float, half_height: float, left: float,
    right: float,
) -> bool:
    if abs(y - cy) > half_height:
        return False
    inner_left = left + half_height
    inner_right = right - half_height
    if inner_left <= x <= inner_right:
        return True
    anchor_x = inner_left if x < inner_left else inner_right
    dx = x - anchor_x
    dy = y - cy
    return dx * dx + dy * dy <= half_height * half_height


def _mark_shapes(left: float, top: float, size: float):
    """Maps the fractional MARK into a square region at (left, top, size)."""
    shapes = []
    for s in MARK:
        if s[0] == "v":
            _, cx, hw, t, b = s
            shapes.append((
                "v", left + cx * size, hw * size,
                top + t * size, top + b * size,
            ))
        else:
            _, cy, hh, l, r = s
            shapes.append((
                "h", top + cy * size, hh * size,
                left + l * size, left + r * size,
            ))
    return shapes


def _mark_span(shapes) -> tuple[float, float]:
    tops, bottoms = [], []
    for s in shapes:
        if s[0] == "v":
            tops.append(s[3])
            bottoms.append(s[4])
        else:
            tops.append(s[1] - s[2])
            bottoms.append(s[1] + s[2])
    return min(tops), max(bottoms)


def _hit(s, x: float, y: float) -> bool:
    if s[0] == "v":
        return _in_vcapsule(x, y, s[1], s[2], s[3], s[4])
    return _in_hcapsule(x, y, s[1], s[2], s[3], s[4])


def _render(width: int, height: int, ss: int, *, mode: str) -> bytearray:
    """Renders the mark at width x height, supersampled by ss for anti-aliasing.

    [mode] selects the composition:
      - "tile":       brand squircle (dark gradient), transparent corners
                      (the legacy launcher icon and the F-Droid icon);
      - "foreground": transparent background, mark in the adaptive safe zone
                      (the adaptive icon foreground, masked by the launcher);
      - "banner":     full-bleed dark background with the centred mark (the
                      feature graphic).
    """
    sw, sh = width * ss, height * ss
    region = min(sw, sh)

    tile_left = tile_top = tile_right = tile_bottom = corner = 0.0
    if mode == "tile":
        margin = region * 0.06
        tile_left = margin
        tile_top = (sh - region) / 2 + margin
        tile_right = sw - margin
        tile_bottom = (sh + region) / 2 - margin
        corner = (tile_right - tile_left) * 0.225
        inset = (tile_right - tile_left) * 0.12
        shapes = _mark_shapes(
            tile_left + inset, tile_top + inset,
            (tile_right - tile_left) - 2 * inset,
        )
    elif mode == "foreground":
        safe = region * 0.62
        shapes = _mark_shapes((sw - safe) / 2, (sh - safe) / 2, safe)
    else:  # "banner"
        mark_region = region * 0.62
        shapes = _mark_shapes(
            (sw - mark_region) / 2, (sh - mark_region) / 2, mark_region,
        )

    mark_top, mark_bottom = _mark_span(shapes)

    # Hard inside/outside tests at the supersampled resolution; the box
    # downsample below turns the jagged edges into smooth anti-aliased ones.
    hi = bytearray(sw * sh * 4)
    for sy in range(sh):
        bg = _bg_row(sy, sh)
        mk = _mark_row(sy, mark_top, mark_bottom)
        row = sy * sw * 4
        for sx in range(sw):
            r = g = b = a = 0
            if mode == "banner":
                r, g, b, a = bg[0], bg[1], bg[2], 255
            elif mode == "tile" and _in_rounded_rect(
                sx, sy, tile_left, tile_top, tile_right, tile_bottom, corner
            ):
                r, g, b, a = bg[0], bg[1], bg[2], 255
            for s in shapes:
                if _hit(s, sx, sy):
                    r, g, b, a = mk[0], mk[1], mk[2], 255
                    break
            o = row + sx * 4
            hi[o] = r
            hi[o + 1] = g
            hi[o + 2] = b
            hi[o + 3] = a

    return _box_downsample(hi, sw, sh, ss)


def _box_downsample(hi: bytearray, sw: int, sh: int, ss: int) -> bytearray:
    w, h = sw // ss, sh // ss
    out = bytearray(w * h * 4)
    samples = ss * ss
    for y in range(h):
        for x in range(w):
            tr = tg = tb = ta = 0
            base_y = y * ss
            base_x = x * ss
            for dy in range(ss):
                row = (base_y + dy) * sw * 4
                for dx in range(ss):
                    o = row + (base_x + dx) * 4
                    a = hi[o + 3]
                    # Weight colour by coverage so transparent samples don't
                    # darken the edge (premultiplied averaging).
                    tr += hi[o] * a
                    tg += hi[o + 1] * a
                    tb += hi[o + 2] * a
                    ta += a
            o = (y * w + x) * 4
            if ta > 0:
                out[o] = round(tr / ta)
                out[o + 1] = round(tg / ta)
                out[o + 2] = round(tb / ta)
            out[o + 3] = round(ta / samples)
    return out


def _write_png(path: Path, width: int, height: int, rgba: bytearray) -> None:
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)  # filter type 0 (None)
        raw.extend(rgba[y * stride:(y + 1) * stride])

    def chunk(tag: bytes, data: bytes) -> bytes:
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(
            ">I", zlib.crc32(body) & 0xFFFFFFFF
        )

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", ihdr)
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)
    print(f"wrote {path.relative_to(REPO_ROOT)} ({width}x{height})")


def main() -> None:
    for density, size in LEGACY_SIZES.items():
        rgba = _render(size, size, ss=3, mode="tile")
        _write_png(RES_DIR / f"mipmap-{density}/ic_launcher.png", size, size, rgba)

    for density, size in FOREGROUND_SIZES.items():
        rgba = _render(size, size, ss=3, mode="foreground")
        _write_png(
            RES_DIR / f"mipmap-{density}/ic_launcher_foreground.png",
            size, size, rgba,
        )

    icon = _render(512, 512, ss=3, mode="tile")
    _write_png(FASTLANE_IMAGES / "icon.png", 512, 512, icon)

    feature = _render(1024, 500, ss=2, mode="banner")
    _write_png(FASTLANE_IMAGES / "featureGraphic.png", 1024, 500, feature)


if __name__ == "__main__":
    main()
