# Store listing assets (F-Droid / GitHub)

This document describes the **image assets** a Linthra store/repository listing
needs (app icon, feature graphic, screenshots), the exact paths and sizes they
go in, and how to capture them from a real build.

> **Status:** all three listing-asset types now exist. The real Linthra **app
> icon and feature graphic** are generated deterministically from one source
> design by [`tool/branding/generate_icons.py`](../tool/branding/generate_icons.py)
> (vector source: `tool/branding/linthra_icon.svg`) — the same mark the Android
> launcher icons under `android/app/src/main/res/mipmap-*` use (adaptive +
> legacy, no longer the default Flutter icon). A set of **eight real phone
> screenshots**, captured from a running build rather than mocked, now lives
> under `images/phoneScreenshots/` — described in full in §6. See also
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
    ├── icon.png                  (present, 512×512)
    ├── featureGraphic.png        (present, 1024×500)
    ├── phoneScreenshots/         (present — 8 real captures, see §6)
    │   ├── 01-now-playing-carefree.png
    │   ├── 02-library-albums.png
    │   └── …                     (through 08-favorites.png)
    ├── sevenInchScreenshots/     (optional, not committed)
    │   └── 1.png …
    └── tenInchScreenshots/       (optional, not committed)
        └── 1.png …
```

The same `images/` files double as the source for a GitHub listing (README
embeds, Releases page), so they only need to be produced once.

## 2. Asset checklist

| Asset            | Path                                                   | Required | Status  |
| ---------------- | ------------------------------------------------------ | -------- | ------- |
| App icon         | `images/icon.png`                                      | Yes      | Present |
| Feature graphic  | `images/featureGraphic.png`                            | Yes      | Present |
| Phone screenshots| `images/phoneScreenshots/01-…png` … (8 committed)      | Yes      | Present |
| 7-inch tablet    | `images/sevenInchScreenshots/1.png` …                  | Optional | Not committed |
| 10-inch tablet   | `images/tenInchScreenshots/1.png` …                    | Optional | Not committed |

All paths are relative to `fastlane/metadata/android/en-US/`.

### The committed shot list

The eight shots under `images/phoneScreenshots/` are described in full in §6.
Between them they cover Now Playing, the Library (Albums and Artists), Smart
mixes, both provider setup screens, the diagnostics / bug-report screen, a
library-syncing state, and Favorites — all captured from a running build, not
mocked.

A few things that were kept in mind while capturing, worth repeating for any
re-captures or extra shots:

- No personal server URL, username, password, or token on screen — the provider
  screen is shown with empty fields, and the diagnostics screen shows only the
  buttons and the app version, never the report contents.
- No private account data you wouldn't want public. (Library / Favorites show
  ordinary album, artist, and track names, which is the point of a music-player
  shot.)
- Real captures only, no mockups. If a mockup is ever used somewhere else, label
  it clearly and keep it out of the F-Droid `phoneScreenshots/` folder.

## 3. Exact sizes and formats

| Asset            | Format    | Size / constraints                                              |
| ---------------- | --------- | --------------------------------------------------------------- |
| App icon         | PNG       | 512×512, square. Real Linthra icon, not the default Flutter logo. |
| Feature graphic  | PNG/JPG   | 1024×500 exactly. No essential text near edges (gets cropped).  |
| Screenshots      | PNG/JPG   | F-Droid sets **no** strict size or aspect-ratio limit — PNG or JPG at a sensible phone resolution. A full-height portrait capture is fine as-is. (Google Play is stricter; see the note below.) |

Screenshot notes:

- Use **real** captures from a running build — never mockups, stock UI, or
  upscaled placeholders.
- 2–8 phone screenshots is the practical range; the committed set is eight (§6).
- **Aspect ratio:** F-Droid itself imposes no aspect-ratio limit — a full-height
  portrait phone capture is accepted as-is. The committed shots are 1008×2244
  (≈9:20), which is fine for F-Droid and for GitHub embeds. **Google Play** is
  stricter (the longer side may be at most twice the shorter), so these
  full-height captures would need cropping before they could be reused for a Play
  listing — see [docs/play-store-readiness.md](./play-store-readiness.md).
- Filenames: F-Droid accepts any `.png` / `.jpg` / `.jpeg` name and orders the
  listing by the filename **string** sort. The committed shots use descriptive,
  zero-padded names (`01-now-playing-carefree.png` … `08-favorites.png`) so they
  stay in the intended order — zero-padding matters because `10.png` would
  otherwise sort before `2.png`.
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
  - `images/icon.png` (512×512) and `images/featureGraphic.png` (1024×500);
  - the full-bleed Google Play app icon
    `assets/brand/linthra-play-store-icon-512.png` (512×512) — Play masks its
    own corners, so this one drops the squircle; see
    [docs/play-store-readiness.md §6](./play-store-readiness.md#6-required-assets).
  The adaptive background is the vector gradient
  `android/app/src/main/res/drawable/ic_launcher_background.xml`.
- **Regenerate** after editing the design: `python3 tool/branding/generate_icons.py`
  (run from the repo root). Edit the SVG and the generator's constants together.

To evolve the brand, change the palette/bar constants in the generator (and the
matching values in `lib/app/colors.dart` / the gradient drawable) and re-run.

## 6. Committed screenshots

Eight real phone screenshots are committed under
`fastlane/metadata/android/en-US/images/phoneScreenshots/`, captured from a
running build (not mocked). F-Droid orders the listing by filename, so the
zero-padded prefixes set the order shown below.

### Main F-Droid screenshots

These six lead the listing — the core of day-to-day use:

| File | Shows |
| ---- | ----- |
| `01-now-playing-carefree.png` | Now Playing — artwork, transport controls, queue actions, and the "Streaming direct" badge. The track is Kevin MacLeod's *Carefree* (Creative Commons), so no private library content is on screen. |
| `02-library-albums.png`       | Library → **Albums**, with the search field. |
| `03-library-artists.png`      | Library → **Artists**, with the search field. |
| `04-smart-mixes.png`          | Smart mixes (Recently added / played, Most played, Favorites, Downloaded, Random, Never played) — counts only. |
| `05-settings-providers.png`   | Settings → providers: the Jellyfin and Navidrome / Subsonic setup cards, shown with **empty** Server URL / Username / Password fields. |
| `06-settings-diagnostics.png` | Settings → diagnostics & bug report: the buttons and the app version, with the on-screen note that diagnostics never include passwords, tokens, or full server URLs. |

### Optional docs / GitHub screenshots

More supplementary, and they trail the listing:

| File | Shows |
| ---- | ----- |
| `07-jellyfin-syncing.png` | The Library "Your Jellyfin library is syncing" state — just the spinner and copy. |
| `08-favorites.png`        | The Favorites list (ordinary track / artist names). |

### Privacy / redaction notes

Every committed shot was reviewed to confirm it does **not** expose:

- private server URLs, usernames, passwords, tokens, or authenticated links —
  the provider screen is shown with empty fields, and the diagnostics screen
  shows only buttons and the version;
- local file paths or raw provider IDs (e.g. `jellyfin:…`);
- any viewer / gallery / browser chrome around the app — all eight are clean,
  cropped, full-screen captures.

Library and Favorites do show ordinary album, artist, and track names — that is
the normal content of a music-player screenshot, not private account data. The
Now Playing shot deliberately uses a Creative Commons track (Kevin MacLeod —
*Carefree*) rather than anything from a personal library.

### Still optional, if anyone wants to add them

Nice-to-have, not required:

- Downloads / offline cache **with tracks actually downloaded** — the current
  "Downloaded" count is 0, so a populated Downloads screen would show the
  feature off better.
- Android Auto, captured on a head unit or the Desktop Head Unit.
- The Cast device picker, if you have a Cast device.
- 7-inch / 10-inch tablet screenshots, only if the larger layout is worth
  showing (otherwise leave those folders out rather than padding them).

When new shots land, keep the zero-padded naming so the order stays predictable,
and re-run the privacy check above.

## 7. Related docs

- [docs/fdroid-readiness.md](./fdroid-readiness.md) — full F-Droid submission
  checklist (identity, build, dependencies, anti-features, signing, tagging).
- [docs/fdroid-submission.md](./fdroid-submission.md) — the submission package
  and listing-asset status.
- [README.md](../README.md) — project overview and the Screenshots section.
