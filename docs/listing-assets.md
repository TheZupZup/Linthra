# Store listing assets (F-Droid / GitHub)

This document describes the **image assets** a Linthra store/repository listing
needs (app icon, feature graphic, screenshots), the exact paths and sizes they
go in, and how to capture them from a real build.

> **No real listing assets exist yet.** Nothing in this document claims an asset
> is present. The Android launcher icons under `android/app/src/main/res/mipmap-*`
> are still the **default Flutter placeholder icon**, not Linthra branding, so
> they must **not** be reused as the store icon. Capture/produce real assets
> before a listing or F-Droid submission. See also
> [docs/fdroid-readiness.md](./fdroid-readiness.md).

## 1. Where assets live

F-Droid reads images from the Fastlane Supply layout already used by this repo:

```
fastlane/metadata/android/en-US/
├── title.txt                     (present)
├── short_description.txt         (present)
├── full_description.txt          (present)
├── changelogs/1.txt              (present)
└── images/
    ├── icon.png                  (MISSING)
    ├── featureGraphic.png        (MISSING)
    ├── phoneScreenshots/         (MISSING)
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
| App icon         | `images/icon.png`                                      | Yes      | Missing |
| Feature graphic  | `images/featureGraphic.png`                            | Yes      | Missing |
| Phone screenshots| `images/phoneScreenshots/1.png` … (2–8)                | Yes      | Missing |
| 7-inch tablet    | `images/sevenInchScreenshots/1.png` …                  | Optional | Missing |
| 10-inch tablet   | `images/tenInchScreenshots/1.png` …                    | Optional | Missing |

All paths are relative to `fastlane/metadata/android/en-US/`.

## 3. Exact sizes and formats

| Asset            | Format    | Size / constraints                                              |
| ---------------- | --------- | --------------------------------------------------------------- |
| App icon         | PNG       | 512×512, square. Real Linthra icon, not the default Flutter logo. |
| Feature graphic  | PNG/JPG   | 1024×500 exactly. No essential text near edges (gets cropped).  |
| Screenshots      | PNG/JPG   | Each side 320–3840 px; portrait phone capture is fine as-is.    |

Screenshot notes:

- Use **real** captures from a running build — never mockups, stock UI, or
  upscaled placeholders.
- 2–8 phone screenshots is the practical range; show the flows that actually
  work today (folder selection, scan, the persisted track list).
- Keep filenames numeric and sequential (`1.png`, `2.png`, …); ordering on the
  listing follows the filename sort order.
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

## 5. How to produce the icon and feature graphic

- **App icon (`icon.png`, 512×512):** design a real Linthra icon. Once it
  exists, it should also replace the default Flutter launcher icons under
  `android/app/src/main/res/mipmap-*` (e.g. via `flutter_launcher_icons`) so the
  installed app and the store listing match. That launcher-icon change is a
  separate app/branding PR, not part of this listing-readiness step.
- **Feature graphic (`featureGraphic.png`, 1024×500):** a simple branded banner
  (logo + name on a solid/gradient background) is enough. Keep important content
  away from the edges.

## 6. Once assets exist

When real assets are committed under `images/`:

1. Delete `images/NEEDED-ASSETS.txt` (its only purpose is to document the gap).
2. Tick the image rows in
   [docs/fdroid-readiness.md](./fdroid-readiness.md) §7 (metadata checklist) and
   clear the "No image assets" blocker in §8.
3. Update the README "F-Droid metadata" section so it no longer lists the assets
   as missing.

## 7. Related docs

- [docs/fdroid-readiness.md](./fdroid-readiness.md) — full F-Droid submission
  checklist (identity, build, dependencies, anti-features, signing, tagging).
- [README.md](../README.md) — project overview and the "F-Droid metadata
  (work in progress)" section.
- `fastlane/metadata/android/en-US/images/NEEDED-ASSETS.txt` — short in-place
  reminder pointing back to this guide.
