# Linthra

[![License: MPL-2.0](https://img.shields.io/badge/License-MPL--2.0-brightgreen.svg)](./LICENSE)
[![Platform: Android](https://img.shields.io/badge/platform-Android-3ddc84.svg)](#install)
[![Built with Flutter](https://img.shields.io/badge/built%20with-Flutter-02569B.svg)](https://flutter.dev)
[![Latest release: v0.1.8](https://img.shields.io/badge/release-v0.1.8-7C5CFF.svg)](https://github.com/thezupzup/linthra/releases/latest)
[![Releases](https://img.shields.io/badge/download-releases-blue.svg)](https://github.com/thezupzup/linthra/releases)
[![Community: r/Linthra](https://img.shields.io/badge/community-r%2FLinthra-FF9F43.svg)](https://reddit.com/r/Linthra)

[<img src="https://fdroid.gitlab.io/artwork/badge/get-it-on.png" alt="Get it on F-Droid" height="75">](https://f-droid.org/packages/io.github.thezupzup.linthra/)

![Linthra](fastlane/metadata/android/en-US/images/featureGraphic.png)

### Your music, your server.

**Linthra is an open-source Android music player for people who keep their music
on their own devices or self-hosted servers.** It plays local files and streams
from your own Jellyfin, Navidrome / Subsonic, or Plex server. No ads, no
tracking, no account.

## Features

- **Local library** — pick a folder, scan it, browse Songs / Albums / Artists
  with search. No broad storage permission.
- **Self-hosted streaming** — connect your own Jellyfin, Navidrome / Subsonic,
  or Plex server. Streaming is the default; nothing downloads unless you ask.
- **Smart offline cache** — download the tracks you want offline; Wi-Fi only by
  default, with a size limit and "Keep offline" pinning.
- **Cast / Chromecast** — pure-Dart Cast, no Google Play Services.
- **Android Auto** — browse your library and play from the car screen.
- **Queue, playlists & favourites** — full queue control, and playlists /
  favourites sync two-way with Jellyfin and Navidrome / Subsonic.
- **Smart mixes** — automatic collections (Recently played, Most played,
  Favorites, …) built from on-device signals that stay on the device.
- **Background playback** — lock-screen, Bluetooth, and headset controls, plus
  shuffle / repeat and synced lyrics.
- **Themes & icons** — retint the app and switch the real launcher icon.

Every feature has a deep-dive in [the docs](./docs/README.md).

## Screenshots

| Now Playing | Library | Smart mixes |
| --- | --- | --- |
| ![Now Playing](fastlane/metadata/android/en-US/images/phoneScreenshots/01-now-playing-carefree.png) | ![Library — Albums](fastlane/metadata/android/en-US/images/phoneScreenshots/02-library-albums.png) | ![Smart mixes](fastlane/metadata/android/en-US/images/phoneScreenshots/04-smart-mixes.png) |

More in [`phoneScreenshots/`](fastlane/metadata/android/en-US/images/phoneScreenshots/).

## Install

**[GitHub Releases](https://github.com/thezupzup/linthra/releases)** is the
source of truth for the latest builds — each release ships signed APKs, and the
current stable is **v0.1.8**. Linthra is also on
**[F-Droid](https://f-droid.org/packages/io.github.thezupzup.linthra/)**, though
F-Droid updates may arrive later while their build/review runs. Not on Google
Play yet.

> **Don't mix install sources:** GitHub APKs and F-Droid builds are signed with
> different keys and can't update each other — pick one and stick with it.

- **Obtainium** — [Obtainium](https://github.com/ImranR98/Obtainium) installs
  straight from GitHub Releases and keeps Linthra updated: add
  `https://github.com/thezupzup/linthra` as the source URL.
- **Manual APK** — download the signed `.apk` from the
  [latest release](https://github.com/thezupzup/linthra/releases/latest) and
  open it on your phone.
- **Android Auto?** Sideloaded media apps only appear after a one-time
  "Unknown sources" toggle — see [docs/android-auto.md](./docs/android-auto.md).
- **Build it yourself** — setup, build, and CI details are in
  [docs/development.md](./docs/development.md).

## Supported sources

| Source | Status |
| --- | --- |
| **Local files** | ✅ Scan a folder, play directly (SAF, no broad permission) — [docs](./docs/local-music.md) |
| **Jellyfin** | ✅ Stream, cache, cast, playlists & favourites — [docs](./docs/jellyfin.md) |
| **Navidrome / Subsonic** | ✅ Stream, cache, cast, lyrics, playlists & favourites (two-way sync) — [docs](./docs/providers.md) |
| **Plex** | ✅ Browse, stream & cache from your own Plex Media Server — [docs](./docs/plex.md) |
| **WebDAV / NAS** | 🔜 Planned — same `MusicSource` seam |

## Privacy

- **No telemetry, no analytics, no phoning home** — nothing leaves your device
  unless **you** choose to.
- **No surprise downloads** — streaming is the default; downloads are always
  user-initiated.
- **Minimal permissions** — playback and internet; no broad storage permission.
- **Your secrets stay safe** — the server password is used once to get a token,
  then discarded; the token is encrypted at rest and never logged.

Details in [PRIVACY.md](./PRIVACY.md) and each provider's doc.

## Contributing

Linthra is small and friendly — testing against your own server, capturing
screenshots, and fixing docs are all real contributions, no Flutter expertise
required. Start with [CONTRIBUTING.md](./CONTRIBUTING.md); the
[contributor roadmap](./docs/contributor-roadmap.md) shows where help matters
most right now, and optional ways to support development are in
[docs/SUPPORT.md](./docs/SUPPORT.md).

## Roadmap

The phased product direction — and its one guiding rule, **Linthra works on its
own; Linthra Connect is optional** — lives in
[docs/roadmap.md](./docs/roadmap.md), along with the honest gaps.

## Documentation

The full index — setup, architecture, and a deep-dive per feature — is in
[docs/README.md](./docs/README.md).

## License

[MPL-2.0](./LICENSE)
