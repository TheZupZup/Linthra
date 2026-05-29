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

Play limit: **4000 characters.**

The **canonical full description is
[`fastlane/metadata/android/en-US/full_description.txt`](../fastlane/metadata/android/en-US/full_description.txt)**
— it is kept current with the shipped build, separates "works today" from
"planned," states the privacy posture (no ads, no tracking, no analytics, no
crash-reporting / telemetry SDK, no Google Play Services), and makes clear that
Linthra is an **unofficial community client, not affiliated with Jellyfin,
Navidrome, or Subsonic**. It is comfortably under 4000 characters.

**Paste that file's contents into the Play Console.** Do **not** keep a second
full-description copy in this doc — a duplicate drifts from the shipped app (as
it did before). The sections below are Play-Console guidance only (limits,
keywords, screenshots, do's and don'ts) and defer to that file for the actual
copy.

## 3. Feature list (for the listing / promo copy)

- Local-first library: scan a folder (Storage Access Framework — no broad
  storage permission), then browse Songs, Albums, and Artists with search.
- Background playback with media notification and lock-screen / Bluetooth /
  headset controls, plus shuffle, repeat, and synced lyrics.
- Up-next queue, playlists, favourites, and automatic "smart mixes."
- Android Auto browsing.
- Optional self-hosted connection: sign in, sync, and stream from **your own**
  Jellyfin or Navidrome / Subsonic server (including over HTTPS).
- Explicit offline downloads with a smart, size-limited cache and a "Wi-Fi
  only" default.
- Casting to Chromecast-compatible devices on the local network (pure-Dart, no
  Google Play Services).
- Open source (MPL-2.0), no ads, no telemetry, no forced sync.

## 4. What works today

Use this as the truthful baseline; keep it consistent with the canonical
description (§2). The shipped feature set:

- Folder selection (Storage Access Framework), scanning, and browsing Songs,
  Albums, and Artists **with search**; the library persists across restarts.
- Local playback with an up-next queue, shuffle, repeat, and synced lyrics.
- Playlists, favourites, and automatic "smart mixes."
- Background playback + media session (notification, lock screen, Bluetooth,
  wired headset).
- Android Auto browsing.
- Jellyfin **and** Navidrome / Subsonic: connect, sign in (the session
  credential is stored encrypted; the password is never saved), sync, and stream
  — including over HTTPS.
- Explicit, user-initiated offline downloads with a smart cache and a
  configurable size limit (Wi-Fi only by default).
- Casting to Chromecast-compatible local-network devices (pure-Dart, no Google
  Play Services).

## 5. Known alpha limitations

Be upfront in the listing and/or release notes (keep consistent with the
"planned" section of the canonical description in §2):

- Local files currently show **file names**; reading **tags and album art** from
  local files is not implemented yet.
- For **Subsonic/Navidrome**, favourites, lyrics, cover art, and fuller playlist
  sync are still in progress.
- No album/playlist **"download all"** yet.
- Additional sources (WebDAV / NAS) are planned, behind the same interface.
- Alpha overall — expect rough edges and changing behavior between versions.

## 6. Suggested keywords

For the title/short description and ASO thinking (Play has no separate keyword
field — weave naturally, do not keyword-stuff):

`music player`, `local music`, `offline music`, `Jellyfin`, `Navidrome`,
`Subsonic`, `self-hosted`, `open source`, `privacy`, `no ads`, `Chromecast`,
`Android Auto`, `NAS`, `media player`, `audio player`.

> Use third-party names like **Jellyfin**, **Navidrome**, **Subsonic**,
> **Chromecast**, **Android Auto**, and **NAS** only to describe genuine
> compatibility — never in a way that implies endorsement or affiliation.
> Linthra is an **unofficial community client and is not affiliated with
> Jellyfin, Navidrome, or Subsonic.** Do **not** describe Linthra as a clone of,
> or drop-in replacement for, any specific commercial app.

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
  with a **self-hosted Jellyfin or Navidrome / Subsonic server** (e.g. on a home
  server or NAS).
- The server connection is **optional and user-configured**: Linthra bundles
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
- **Do not** use third-party trademark names (Jellyfin, Navidrome, Subsonic,
  Chromecast, Android Auto, NAS vendors) in a confusing way that implies
  affiliation or endorsement. Linthra is an unofficial community client.

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
