# Linthra

[![License: MPL-2.0](https://img.shields.io/badge/License-MPL--2.0-brightgreen.svg)](./LICENSE)
[![Platform: Android](https://img.shields.io/badge/platform-Android-3ddc84.svg)](#-try-it)
[![Built with Flutter](https://img.shields.io/badge/built%20with-Flutter-02569B.svg)](https://flutter.dev)
[![Status: alpha](https://img.shields.io/badge/status-alpha-orange.svg)](#-status)
[![Releases](https://img.shields.io/badge/download-releases-blue.svg)](https://github.com/thezupzup/linthra/releases)

![Linthra](fastlane/metadata/android/en-US/images/featureGraphic.png)

### Your music. Your server. Your rules.

**Linthra is an open-source Android music player for people who own their
music** — with Jellyfin/Navidrome streaming, a smart offline cache, Cast,
Android Auto, and **no surprise downloads**.

---

## 🎧 Why Linthra?

You ripped the CDs. You pay for the server. You shouldn't have to rent your own
music back from someone else's app.

Most "music apps" are storefronts that happen to play audio — they nudge you
toward a catalog, sync things you didn't ask for, and treat your library as a
guest. Linthra flips that around:

Point it at your Jellyfin / Navidrome / Subsonic server, or a folder of
local files.

Streaming is the default. Nothing downloads unless you tap download.

Your whole library is browsable instantly because the app reads from a local
catalog, not the network.

No telemetry, no ads, no account, no phoning home.


If you self-host your music and want a clean Android player that respects that,
Linthra is for you.

## Status

**Linthra is early alpha — but already usable for testing today.** You can
connect a real server, sync your library, stream, cache, cast, and drive it from
Android Auto on a real phone. It's not production-stable, it's **not on Google
Play or F-Droid**, and it has honest, documented rough edges (see
[Roadmap](#-roadmap) and the per-feature docs). That's exactly why it's a great
time to jump in — small contributions land fast and shape where it goes.

> **F-Droid readiness is in progress** (not yet submitted, not yet on F-Droid) —
> see [docs/fdroid-readiness.md](./docs/fdroid-readiness.md).

## 📸 Screenshots

Linthra ships with real branding — an equalizer mark carrying a violet→orange
gradient, generated from one source design (not mockups).

| App icon | Feature graphic |
| --- | --- |
| ![Linthra icon](fastlane/metadata/android/en-US/images/icon.png) | ![Linthra feature graphic](fastlane/metadata/android/en-US/images/featureGraphic.png) |

> **In-app screenshots aren't committed yet.** Rather than ship mock images, no
> screenshots from a running build are included until real ones are captured —
> [a great first contribution](#-ways-to-help)! The capture checklist and sizes
> are in [docs/listing-assets.md](./docs/listing-assets.md).

## What works today

- **Local library** — pick a folder (Storage Access Framework), scan it, browse
  **Songs / Albums / Artists** with search. No broad storage permission.
- **Self-hosted streaming** — connect your own **Jellyfin** or
  **Navidrome / Subsonic** server: test, sign in, sync, and stream. Works over
  HTTPS / Cloudflare-proxied domains.
- **Smart offline cache** — tap to download the tracks you want offline; Wi-Fi
  only by default, with a size limit and "Keep offline" pinning.
- **Cast / Chromecast** — hand a stream off to a speaker or TV, with device
  volume control and track metadata (title/artist/album/artwork) on the receiver.
  Pure-Dart Cast, no Google Play Services. (App-name/logo branding on the receiver
  needs a custom receiver app — see [docs/cast.md](./docs/cast.md).)
- **Android Auto** — browse your Library, Queue, Playlists, and Favorites from
  the car screen and tap to play.
- **Queue / Up Next** — play next, add to queue, reorder, remove, and save the
  queue as a playlist — without building a playlist first ([docs](./docs/queue.md)).
- **Playlists & favourites** — create/edit/reorder/delete playlists; favourite
  tracks. Both sync with Jellyfin where supported.
- **Smart mixes** — automatic, Made-by-Linthra collections (Recently added /
  played, Most played, Favorites, Downloaded, Random, Never played) built from
  on-device signals that stay on the device ([docs](./docs/smart-mixes.md)).
- **Background playback** — media notification with lock-screen, Bluetooth, and
  wired-headset controls, plus shuffle / repeat and synced lyrics.

Each feature has a deep-dive in [the docs](#-documentation).

## Try it

> Linthra is **not on Google Play or F-Droid**. It's distributed as a
> sideloadable APK from **[GitHub Releases](https://github.com/thezupzup/linthra/releases)**.
> Alpha releases are GitHub **pre-releases**.

**Obtainium (recommended)** — [Obtainium](https://github.com/ImranR98/Obtainium)
installs straight from GitHub Releases and keeps you updated. Add app, paste
`https://github.com/thezupzup/linthra`, enable **"Include prereleases"**, install.

**Manual APK** — download the `.apk` from the
[latest release](https://github.com/thezupzup/linthra/releases), open it on your
phone, and allow "install from unknown sources" if prompted.

**Build it yourself** — `flutter pub get && flutter build apk --debug`. Full
setup, CI builds, and release details are in
[docs/development.md](./docs/development.md). In most environments, run
`./scripts/setup_flutter.sh` then `./scripts/verify_android.sh` to get the
pinned Flutter toolchain and run the same checks as CI.

> **Using Android Auto?** Sideloaded media apps only appear after you enable
> Android Auto's developer **"Unknown sources"** toggle — a one-time step,
> detailed in [docs/android-auto.md](./docs/android-auto.md).
>
> **Heads up:** until release signing is provisioned, some alpha APKs may be
> **debug-signed**; if a signature changes, you may need to reinstall.

## Ways to help

Linthra is small and friendly — good first contributions are very welcome, and
many don't need a single line of code:

- **Test with your server** — does it work with your **Jellyfin**? Your
  **Navidrome / Subsonic**? Tell us what broke.
- **Try Cast** — connect a Chromecast / speaker / TV and report device
  compatibility.
- **Test Android Auto** — on a head unit or the Desktop Head Unit.
- **Capture screenshots** for the README and store listing.
- **Improve docs** — fix a confusing step, add a setup gotcha.
- **Report bugs in one tap** — **Settings → Report a bug** builds a
  **secret-free** report on your device (no tokens, no passwords); review it,
  then copy it or open a prefilled GitHub issue.
  ([how it works](./docs/reporting-bugs.md))
- **Improve accessibility** — better screen-reader labels and TalkBack support.
- **Polish UI/UX** — small refinements add up.
- **Help future providers** — WebDAV / NAS support behind the same interface.

New here? [CONTRIBUTING.md](./CONTRIBUTING.md) walks through setup in two
commands, and the [contributor roadmap](./docs/contributor-roadmap.md) shows
where help is most useful right now. The
[issue tracker](https://github.com/thezupzup/linthra/issues) has tasks tagged
`good first issue` and `help wanted`.

Found Linthra useful? A **GitHub star** helps others discover it.

## Self-hosted sources

Sources sit behind one interface, so the app treats them uniformly:

| Source | Status |
| --- | --- |
| **Local files** | ✅ Scan a folder, play directly (SAF, no broad permission) |
| **Jellyfin** | ✅ Stream, cache, cast, playlists & favourites — [docs](./docs/jellyfin.md) |
| **Navidrome / Subsonic** | ✅ Stream, cache, cast (favourites & lyrics are follow-ups) — [docs](./docs/providers.md) |
| **WebDAV / NAS** | 🔜 Planned — same `MusicSource` seam |

## Privacy

Linthra is built to respect the people who use it:

- **No telemetry, no analytics, no phoning home** — nothing leaves your device
  unless **you** choose to. Bug reports are built locally and never auto-sent;
  "Open GitHub issue" only opens your browser to a prefilled, unsubmitted issue.
- **No surprise downloads** — streaming is the default; downloads are always
  user-initiated, Wi-Fi only unless you opt in to mobile data.
- **Minimal permissions** — foreground-service + notification (playback) and
  internet (your server). **No broad storage permission.**
- **Your secrets stay safe** — the server password is used once to get a token,
  then discarded; the token is encrypted at rest, never logged, and stream URLs
  are minted only on demand. Token-handling details are in each provider's doc.

## Roadmap

**Next up:** local tag/metadata parsing + album artwork · Subsonic favourites,
lyrics & cover art · full playlist sync · album/playlist "download all" +
background download manager · real connectivity detection for the Wi-Fi gate ·
WebDAV / NAS sources.

**Later:** local-file lyrics (`.lrc`/tags), ReplayGain, MPRIS, Linux desktop,
richer Android Auto and Cast.

Honest gaps (no local tag parsing yet, single Jellyfin server, direct-play only,
partial playlist sync, optimistic connectivity) are documented per feature.

## Documentation

| Topic | Doc |
| --- | --- |
| Contributing & setup | [CONTRIBUTING.md](./CONTRIBUTING.md) |
| Where to help (contributor roadmap) | [docs/contributor-roadmap.md](./docs/contributor-roadmap.md) |
| Architecture & extension points | [docs/architecture.md](./docs/architecture.md) |
| Development, build & CI | [docs/development.md](./docs/development.md) |
| Library browsing & search | [docs/library.md](./docs/library.md) |
| Music providers (overview) | [docs/providers.md](./docs/providers.md) |
| Jellyfin setup | [docs/jellyfin.md](./docs/jellyfin.md) · [compatibility](./docs/jellyfin-compatibility.md) · [sync](./docs/jellyfin-sync.md) |
| Streaming, buffering & recovery | [docs/streaming.md](./docs/streaming.md) |
| Queue / Up Next | [docs/queue.md](./docs/queue.md) |
| Offline cache & downloads | [docs/offline-cache.md](./docs/offline-cache.md) |
| Cast / Chromecast | [docs/cast.md](./docs/cast.md) |
| Android Auto | [docs/android-auto.md](./docs/android-auto.md) |
| Reporting a bug | [docs/reporting-bugs.md](./docs/reporting-bugs.md) |
| Playlists & safe removal | [docs/playlists-and-delete.md](./docs/playlists-and-delete.md) |
| Smart mixes (automatic playlists) | [docs/smart-mixes.md](./docs/smart-mixes.md) |
| Manual QA checklist | [docs/manual-test-checklist.md](./docs/manual-test-checklist.md) |
| Release process & signing | [docs/release-process.md](./docs/release-process.md) · [signing](./docs/release-signing.md) |
| F-Droid readiness | [docs/fdroid-readiness.md](./docs/fdroid-readiness.md) |
| Google Play readiness | [docs/play-store-readiness.md](./docs/play-store-readiness.md) |

## License

[MPL-2.0](./LICENSE)
