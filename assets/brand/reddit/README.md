# Linthra — Reddit community assets

Branded artwork for the **r/Linthra** subreddit: a community icon (avatar) and a
wide banner, each in three on-brand "skins". Everything is built from Linthra's
single source of truth — the violet→orange four-bar equalizer mark
(`tool/branding/linthra_icon.svg`) and the app palette (`lib/app/colors.dart`) —
so the community art reads as the same product as the app and the F-Droid
listing.

## Files

| Asset | Size | Files |
| --- | --- | --- |
| Community icon — Classic | 512×512 | `linthra-reddit-icon-classic.{png,svg}` |
| Community icon — Monochrome | 512×512 | `linthra-reddit-icon-mono.{png,svg}` |
| Community icon — Community | 512×512 | `linthra-reddit-icon-community.{png,svg}` |
| Banner — Classic | 1920×384 | `linthra-reddit-banner-classic.{png,svg}` |
| Banner — Monochrome | 1920×384 | `linthra-reddit-banner-mono.{png,svg}` |
| Banner — Community | 1920×384 | `linthra-reddit-banner-community.{png,svg}` |

PNGs are ready to upload as-is. SVGs are the editable, resolution-independent
sources (fonts are embedded, so they render identically anywhere — no network
or installed fonts required).

## The three skins

- **Classic** — Linthra's signature look: the violet→orange mark on a deep
  violet-black backdrop. The default, premium and restrained.
- **Monochrome** — strictly black & white. A pure-white mark on near-black, for
  a stark, high-contrast minimal feel.
- **Community** — pushes the orange + purple accents harder: dual violet/orange
  glows, a warm accent ring on the icon, and an orange→violet underline on the
  banner. Energetic and welcoming.

All three share the **same equalizer mark, the same lockup, and the same
typography** — only the colour/glow treatment changes — so the set stays
recognisably Linthra.

## Using them on Reddit

- **Community icon** — upload under *Mod Tools → Community Appearance → Avatar*.
  Reddit displays it as a **circle** and down to ~32–40 px, so the design is
  full-bleed with the mark centred inside the circular safe area and no text.
- **Banner** — upload under *Mod Tools → Community Appearance → Banner*. The
  important content (mark, **Linthra** wordmark, and the tagline) is centred so
  it survives Reddit's mobile crop; the waveform and the faint server-rack
  motifs at the edges are decoration that may be cropped.

## Brand reference

| Role | Hex |
| --- | --- |
| Brand violet (mark top) | `#9C84FF` (`brandBright`) |
| Warm orange (mark bottom) | `#FF9F43` (`accent`) |
| Backdrop top → bottom | `#1C1730` → `#100E18` |
| Ink / muted ink | `#F6F7FB` / `#9E9CB0` |

Typography: **Space Grotesk** (the *Linthra* wordmark) and **Inter** (taglines),
both SIL Open Font License — see `tool/branding/reddit/fonts/`.

## Regenerating

These assets are generated deterministically from one script, exactly like the
app icons (`tool/branding/generate_icons.py`):

```bash
node tool/branding/reddit/generate_reddit_assets.mjs \
  assets/brand/reddit \
  tool/branding/reddit/fonts
```

It needs Node and Playwright's Chromium (used purely to rasterise the SVGs to
PNG). Edit the palette, mark, or layout in the script and re-run to refresh
every PNG and SVG together so the set never drifts.
