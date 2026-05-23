# Store listing assets (F-Droid / GitHub)

This document describes the **image assets** a Linthra store/repository listing
needs (app icon, feature graphic, screenshots), the exact paths and sizes they
go in, and how to capture them from a real build.

> **Status:** the real Linthra **app icon and feature graphic now exist**, and
> the Android launcher icons under `android/app/src/main/res/mipmap-*` are the
> real Linthra mark (adaptive + legacy), no longer the default Flutter icon. All
> of these are generated deterministically from one source design by
> [`tool/branding/generate_icons.py`](../tool/branding/generate_icons.py)
> (vector source: `tool/branding/linthra_icon.svg`). **Screenshots are the only
> remaining listing asset** and must be captured from a real build — never
> mocked. See also [docs/fdroid-readiness.md](./fdroid-readiness.md).

## 1. Where assets live

F-Droid reads images from the Fastlane Supply layout already used by this repo:

```
fastlane/metadata/android/en-US/
├── title.txt                     (present)
├── short_description.txt         (present)
├── full_description.txt          (present)
├── changelogs/1.txt              (present)
└── images/
    ├── icon.png                  (present, 512×512)
    ├── featureGraphic.png        (present, 1024×500)
    ├── phoneScreenshots/         (MISSING — capture from a real build)
    │   ├── 1.png
    │   ├── 2.png
    │   └── …
    ├── sevenInchScreenshots/     (optional, MISSING)
    │   └── 1.png …
    └── tenInchScreenshots/       (optional, MISSING)
        └── 1.png …
```

The same `images/` files double as the source for a GitHub listing (README
embeds, Releases page), so they only need to be produced once.

## 2. Asset checklist

| Asset            | Path                                                   | Required | Status  |
| ---------------- | ------------------------------------------------------ | -------- | ------- |
| App icon         | `images/icon.png`                                      | Yes      | Present |
| Feature graphic  | `images/featureGraphic.png`                            | Yes      | Present |
| Phone screenshots| `images/phoneScreenshots/1.png` … (2–8)                | Yes      | Missing |
| 7-inch tablet    | `images/sevenInchScreenshots/1.png` …                  | Optional | Missing |
| 10-inch tablet   | `images/tenInchScreenshots/1.png` …                    | Optional | Missing |

All paths are relative to `fastlane/metadata/android/en-US/`.

## 3. Exact sizes and formats

| Asset            | Format    | Size / constraints                                              |
| ---------------- | --------- | --------------------------------------------------------------- |
| App icon         | PNG       | 512×512, square. Real Linthra icon, not the default Flutter logo. |
| Feature graphic  | PNG/JPG   | 1024×500 exactly. No essential text near edges (gets cropped).  |
| Screenshots      | PNG/JPG   | Each side 320–3840 px; aspect ratio between 1:2 and 2:1; portrait phone capture is fine as-is. |

Screenshot notes:

- Use **real** captures from a running build — never mockups, stock UI, or
  upscaled placeholders.
- 2–8 phone screenshots is the practical range; show the flows that actually
  work today (folder selection, scan, the persisted track list).
- F-Droid rejects screenshots whose aspect ratio is outside 1:2–2:1, so a raw
  capture from an unusually tall/narrow device may need cropping (not stretching).
- Keep filenames numeric and sequential (`1.png`, `2.png`, …); ordering on the
  listing follows the filename **string** sort order, so `10.png` sorts before
  `2.png`. Stay under 10 screenshots, or zero-pad (`01.png`, `02.png`, …) to keep
  the intended order.
- Tablet screenshots are optional. Only add them if the layout is genuinely
  worth showing on a larger screen — otherwise omit those folders entirely
  rather than padding them with stretched phone captures.

See F-Droid's
[descriptions, graphics & screenshots guide](https://f-droid.org/docs/All_About_Descriptions_Graphics_and_Screenshots/)
for the authoritative rules.

## 4. How to capture screenshots

Linthra is a Flutter Android app. Capture from a device or emulator running a
debug or release build.

1. **Run the app** on a connected device/emulator:

   ```sh
   flutter run
   ```

   (See the README "Getting started" / "Building a debug APK" sections.)

2. **Navigate** to a screen worth showing (e.g. the track list after a scan).

3. **Capture** the current screen with `adb`:

   ```sh
   # Save directly to the Fastlane phone-screenshots folder
   adb exec-out screencap -p \
     > fastlane/metadata/android/en-US/images/phoneScreenshots/1.png
   ```

   Repeat for each screen, incrementing the filename (`2.png`, `3.png`, …).

   Alternatively, take a screenshot on the device (power + volume-down) and pull
   it:

   ```sh
   adb pull /sdcard/Pictures/Screenshots/<file>.png \
     fastlane/metadata/android/en-US/images/phoneScreenshots/1.png
   ```

4. **Verify dimensions** before committing (each side must be 320–3840 px):

   ```sh
   file fastlane/metadata/android/en-US/images/phoneScreenshots/*.png
   ```

For an emulator, the same `adb exec-out screencap` command works while the
emulator is running.

## 5. How the icon and feature graphic are produced

Both are generated from one source design, so they never drift:

- **Source:** `tool/branding/linthra_icon.svg` is the canonical vector mark
  (four rounded white equalizer bars on the brand violet gradient).
- **Generator:** [`tool/branding/generate_icons.py`](../tool/branding/generate_icons.py)
  rasterises it (standard library only, no Pillow) into:
  - the legacy launcher icons (`mipmap-*/ic_launcher.png`) and the adaptive
    foreground (`mipmap-*/ic_launcher_foreground.png`);
  - `images/icon.png` (512×512) and `images/featureGraphic.png` (1024×500).
  The adaptive background is the vector gradient
  `android/app/src/main/res/drawable/ic_launcher_background.xml`.
- **Regenerate** after editing the design: `python3 tool/branding/generate_icons.py`
  (run from the repo root). Edit the SVG and the generator's constants together.

To evolve the brand, change the palette/bar constants in the generator (and the
matching values in `lib/app/colors.dart` / the gradient drawable) and re-run.

## 6. Remaining: screenshots

The icon and feature graphic are committed. The only missing listing assets are
**screenshots**, which must be captured from a real build (§4) — they are
intentionally left out rather than faked. Once real screenshots are committed:

1. Update `images/NEEDED-ASSETS.txt` (or delete it once screenshots also land).
2. Tick the screenshot row in
   [docs/fdroid-readiness.md](./fdroid-readiness.md) §7 (metadata checklist) and
   clear the remaining image blocker in §8.
3. Update the README "F-Droid metadata" section accordingly.

## 7. Related docs

- [docs/fdroid-readiness.md](./fdroid-readiness.md) — full F-Droid submission
  checklist (identity, build, dependencies, anti-features, signing, tagging).
- [README.md](../README.md) — project overview and the "F-Droid metadata
  (work in progress)" section.
- `fastlane/metadata/android/en-US/images/NEEDED-ASSETS.txt` — short in-place
  reminder pointing back to this guide.
