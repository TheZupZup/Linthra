#!/usr/bin/env python3
"""Generate Linthra's launcher icons and store graphics from one source design.

Linthra's mark is a small equalizer — four rounded white bars on the brand
violet gradient — echoing a now-playing visualizer. This script is the single
source of truth for that mark: it renders every raster asset the app and the
F-Droid/Fastlane listing need, so the icon never drifts between sizes and can be
regenerated deterministically.

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
and is not generated here. Run from the repo root:  python3 tool/branding/generate_icons.py
"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

# Brand palette (kept in step with lib/app/colors.dart's accent family).
GRADIENT_TOP = (0x9C, 0x8D, 0xF8)
GRADIENT_BOTTOM = (0x67, 0x50, 0xC8)
BAR_COLOR = (0xFF, 0xFF, 0xFF)

# The equalizer bars, as fractions of the region they're drawn in. Heights are
# bottom-aligned to a shared baseline, giving the "levels" look.
BAR_HEIGHTS = (0.46, 0.70, 0.56, 0.34)
BAR_WIDTH_FRACTION = 0.13
BAR_GAP_FRACTION = 0.10
BASELINE_FRACTION = 0.80

REPO_ROOT = Path(__file__).resolve().parents[2]
RES_DIR = REPO_ROOT / "android/app/src/main/res"
FASTLANE_IMAGES = (
    REPO_ROOT / "fastlane/metadata/android/en-US/images"
)

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


def _gradient_row(y: float, height: int) -> tuple[int, int, int]:
    t = y / max(height - 1, 1)
    return (
        _lerp(GRADIENT_TOP[0], GRADIENT_BOTTOM[0], t),
        _lerp(GRADIENT_TOP[1], GRADIENT_BOTTOM[1], t),
        _lerp(GRADIENT_TOP[2], GRADIENT_BOTTOM[2], t),
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


def _in_capsule(
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


def _bars(region_left: float, region_top: float, region_size: float):
    """Returns the (cx, half_width, top, bottom) of each equalizer bar."""
    bar_width = region_size * BAR_WIDTH_FRACTION
    gap = region_size * BAR_GAP_FRACTION
    count = len(BAR_HEIGHTS)
    group_width = count * bar_width + (count - 1) * gap
    start_x = region_left + (region_size - group_width) / 2
    baseline = region_top + region_size * BASELINE_FRACTION
    bars = []
    for i, height_fraction in enumerate(BAR_HEIGHTS):
        left = start_x + i * (bar_width + gap)
        cx = left + bar_width / 2
        top = baseline - region_size * height_fraction
        bars.append((cx, bar_width / 2, top, baseline))
    return bars


def _render(width: int, height: int, ss: int, *, mode: str) -> bytearray:
    """Renders the mark at width x height, supersampled by ss for anti-aliasing.

    [mode] selects the composition:
      - "tile":       brand gradient in a rounded square, transparent corners
                      (the legacy launcher icon and the F-Droid icon);
      - "foreground": transparent background, bars only in the safe zone (the
                      adaptive icon foreground, masked by the launcher);
      - "banner":     full-bleed gradient with centred bars (the feature
                      graphic).
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
        bars = _bars(tile_left, tile_top, tile_right - tile_left)
    elif mode == "foreground":
        safe = region * 0.62
        bars = _bars((sw - safe) / 2, (sh - safe) / 2, safe)
    else:  # "banner"
        bar_region = region * 0.66
        bars = _bars((sw - bar_region) / 2, (sh - bar_region) / 2, bar_region)

    # Hard inside/outside tests at the supersampled resolution; the box
    # downsample below turns the jagged edges into smooth anti-aliased ones.
    hi = bytearray(sw * sh * 4)
    for sy in range(sh):
        grad = _gradient_row(sy, sh)
        row = sy * sw * 4
        for sx in range(sw):
            r = g = b = a = 0
            if mode == "banner":
                r, g, b, a = grad[0], grad[1], grad[2], 255
            elif mode == "tile" and _in_rounded_rect(
                sx, sy, tile_left, tile_top, tile_right, tile_bottom, corner
            ):
                r, g, b, a = grad[0], grad[1], grad[2], 255
            for (cx, hw, top, bottom) in bars:
                if _in_capsule(sx, sy, cx, hw, top, bottom):
                    r, g, b, a = BAR_COLOR[0], BAR_COLOR[1], BAR_COLOR[2], 255
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
