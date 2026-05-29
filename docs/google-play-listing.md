# Google Play store listing (draft)

> **Draft for review.** This is a draft of the Google Play store listing copy
> for Linthra's **closed testing / alpha**. It deliberately separates what works
> today from what is planned, and makes **no** claim that Linthra is on Google
> Play or F-Droid (it is not, and no submission has been made). Review and trim
> to Play's limits before pasting into the Play Console. See
> [docs/play-store-readiness.md](./play-store-readiness.md).

The repo already carries reusable listing text under
`fastlane/metadata/android/en-US/` (`short_description.txt`,
`full_description.txt`). This document is the Play-Console-oriented version and
should stay consistent with those files.

## 1. Short description

Play limit: **80 characters.** Suggested:

```
Open-source, local-first music player for music you own. No forced sync.
```

(72 characters — matches `fastlane/.../short_description.txt`.)

## 2. Full description

Play limit: **4000 characters.** Suggested draft (keep the "works today" vs
"planned" split honest):

```
Linthra is an open-source, local-first music player for people who own their
music. Your library lives on your device, and you stay in control of it.

Linthra is early-stage alpha software. This listing separates what works today
from what is planned, so nothing here overpromises.

WHAT LINTHRA IS ABOUT
• Local-first — your music files stay on your device; the app reads from a
  local catalog rather than depending on a remote service.
• Music you own — Linthra plays files you already have. No store, no account,
  no requirement to use anyone's cloud.
• Privacy-focused — no ads, no telemetry, no forced sync. The app does not
  phone home or upload your library, and offline downloads only happen when you
  ask for them.
• Open source — released under the Mozilla Public License 2.0; anyone can read,
  audit, build, and contribute.

WORKS TODAY
• Pick a folder of music with the Android folder picker, scan it, and browse
  your tracks. Your folder and scanned library survive a restart.
• Play your local tracks with an up-next queue, plus shuffle and repeat.
• Background playback with a media notification and lock-screen, Bluetooth, and
  wired-headset controls.
• Android Auto: browse your Library and Queue from the car screen.
• Connect to your own Jellyfin server, sign in, sync your library, and stream.
  The session token is stored encrypted and your password is never saved.
• Explicit, user-initiated offline downloads with a smart cache and a size
  limit you set — Wi-Fi only by default, with an optional "Allow mobile data"
  toggle. Never automatic.
• Cast to Chromecast-compatible devices on your local network.

PLANNED (NOT FINISHED YET)
• Tag/metadata parsing and album artwork (tracks currently show file names).
• Browsing by artist and album, plus search.
• Playlist creation and editing, and queue reorder.
• Album- and playlist-level "download all" and a background download manager.
• Additional sources such as WebDAV and NAS, behind the same interface.

SELF-HOSTED FRIENDLY
Linthra works great with a self-hosted Jellyfin server you run yourself — on a
home server or NAS. The server is entirely optional and entirely yours; Linthra
bundles no server and runs no cloud service of its own.

NO SURPRISES
No ads. No account. No forced sync. No surprise downloads — Linthra never
downloads your library in the background; downloads happen only when you ask,
and they use Wi-Fi only by default unless you allow mobile data.

Linthra is alpha software with honest, documented limitations. Expect rough
edges, and please share feedback.
```

If this exceeds 4000 characters after edits, trim the "Planned" section first.

## 3. Feature list (for the listing / promo copy)

- Local-first library: scan a folder, browse, and play music you own.
- Background playback with media notification and lock-screen / Bluetooth /
  headset controls.
- Up-next queue, shuffle, and repeat.
- Android Auto browsing (Library and Queue).
- Optional Jellyfin connection: sign in, sync, and stream from **your** server.
- Explicit offline downloads with a smart, size-limited cache and a "Wi-Fi
  only" option.
- Casting to Chromecast-compatible devices on the local network.
- Open source (MPL-2.0), no ads, no telemetry, no forced sync.

## 4. What works today

Use this as the truthful baseline; do not list planned items as if shipped.

- Folder selection (Android folder picker), scanning, and a persisted track
  list.
- Local playback with an up-next queue, shuffle, and repeat.
- Background playback + media session (notification, lock screen, Bluetooth,
  wired headset).
- Android Auto: browse Library and Queue.
- Jellyfin: connect, sign in (token stored encrypted; password never saved),
  sync, stream, and synced favorites/lyrics.
- Explicit offline downloads with a smart cache and a configurable size limit.
- Chromecast/Cast foundation to local-network devices.

## 5. Known alpha limitations

Be upfront in the listing and/or release notes:

- Tracks currently show **file names**; tag/metadata parsing and **album
  artwork** are not implemented yet.
- No browse-by-artist/album and **no search** yet.
- **No playlist** creation/editing yet; queue reordering is limited.
- No album/playlist "download all" or background download manager yet.
- The Wi-Fi / mobile-data gate relies on basic connectivity handling; robust
  connectivity detection is still planned.
- Some Android 11+ scoped-storage folders may be unreadable; the app surfaces a
  clear error rather than a silent empty library.
- Alpha overall — expect rough edges and changing behavior between versions.

## 6. Suggested keywords

For the title/short description and ASO thinking (Play has no separate keyword
field — weave naturally, do not keyword-stuff):

`music player`, `local music`, `offline music`, `Jellyfin`, `self-hosted`,
`open source`, `privacy`, `no ads`, `Chromecast`, `Android Auto`, `NAS`,
`media player`, `audio player`.

> Use third-party names like **Jellyfin**, **Chromecast**, **Android Auto**, and
> **NAS** only to describe genuine compatibility — never in a way that implies
> endorsement or affiliation. Do **not** describe Linthra as a clone of, or
> drop-in replacement for, any specific commercial app.

## 7. Screenshot checklist

Play requires **2–8 phone screenshots**; they must be **real** captures from a
running build (see [docs/listing-assets.md](./listing-assets.md) for sizes and
`adb` capture steps). Eight real captures already exist for F-Droid under
`images/phoneScreenshots/` and can be reused here once **cropped** to Play's
≤ 2:1 ratio (the F-Droid originals are full-height ≈9:20). Suggested set, showing
only what works today:

- [ ] Library / track list after a scan.
- [ ] Now Playing screen (with shuffle/repeat/favorite controls).
- [ ] Background-playback media notification or lock-screen controls.
- [ ] Jellyfin connect / signed-in Settings screen (no secrets visible).
- [ ] Offline cache / downloads settings (size limit, clear cache).
- [ ] (Optional) Cast device picker.
- [ ] (Optional) Android Auto browse, if cleanly capturable.

Do **not** ship mock or upscaled screenshots. Capture from a real device or
emulator.

## 8. "No surprise downloads" messaging

A core promise worth stating plainly in the listing and release notes:

> Linthra never downloads your library in the background. Offline downloads are
> always something **you** start, with a size limit you set and Wi-Fi-only by
> default (mobile data is opt-in). There is no forced full-library sync.

## 9. Jellyfin / NAS / self-hosted positioning

- Position Linthra as a **player for music you own**, that **optionally** works
  with a **self-hosted Jellyfin server** (e.g. on a home server or NAS).
- The Jellyfin connection is **optional and user-configured**: Linthra bundles
  no server, promotes no hosted service, and runs **no cloud service of its
  own**.
- Frame self-hosting as a benefit for people who want their library on their own
  hardware — not as a requirement. The local-first core works without any
  server.

## 10. Things to avoid in the listing

- **Do not** call Linthra a "Plexamp clone" (or a clone/replacement of any
  specific commercial product).
- **Do not** overclaim production stability — it is alpha; say so.
- **Do not** claim availability on F-Droid or Google Play before it is actually
  published there.
- **Do not** use third-party trademark names (Jellyfin, Chromecast, Android
  Auto, NAS vendors) in a confusing way that implies affiliation or endorsement.

## 11. Related docs

- [docs/play-store-readiness.md](./play-store-readiness.md) — overall Play
  readiness and submission path.
- [docs/google-play-data-safety.md](./google-play-data-safety.md) — Data Safety
  form prep.
- [docs/privacy-policy.md](./privacy-policy.md) — privacy policy draft.
- [docs/listing-assets.md](./listing-assets.md) — image asset sizes and capture.
- `fastlane/metadata/android/en-US/` — the canonical short/full description and
  changelog text.
</content>
