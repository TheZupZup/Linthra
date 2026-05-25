# Linthra

[![License: MPL-2.0](https://img.shields.io/badge/License-MPL--2.0-brightgreen.svg)](./LICENSE)
[![Platform: Android](https://img.shields.io/badge/platform-Android-3ddc84.svg)](#install)
[![Built with Flutter](https://img.shields.io/badge/built%20with-Flutter-02569B.svg)](https://flutter.dev)
[![Status: alpha](https://img.shields.io/badge/status-alpha-orange.svg)](#project-status)
[![Releases](https://img.shields.io/badge/download-releases-blue.svg)](https://github.com/thezupzup/linthra/releases)

![Linthra](fastlane/metadata/android/en-US/images/featureGraphic.png)

**Linthra is an open-source Android music player for people who own their
music** — with Jellyfin streaming, a smart offline cache, Android Auto, a
Chromecast foundation, synced lyrics, and **no surprise downloads**. Your
library lives on your device, the app reads from a local catalog, and anything
that touches the network is something you asked for.

> **Your music, beautifully yours.**

Linthra is **early-stage alpha software**. The sections below honestly separate
what works today from what is still planned — nothing here overpromises, and
Linthra is **not on F-Droid** and **not production-stable** yet.

- [Screenshots](#screenshots)
- [What works today](#what-works-today)
- [Known limitations](#known-limitations)
- [Install](#install)
- [Connect your Jellyfin server](#connect-your-jellyfin-server)
- [Privacy &amp; security](#privacy--security)
- [Roadmap](#roadmap)
- [Project status](#project-status)
- [Contributing &amp; deeper docs](#contributing--deeper-docs)

## Screenshots

Linthra ships with real branding — an equalizer mark carrying the brand's
violet→orange gradient — generated from a single source design (not mockups):

| App icon | Feature graphic |
| --- | --- |
| ![Linthra icon](fastlane/metadata/android/en-US/images/icon.png) | ![Linthra feature graphic](fastlane/metadata/android/en-US/images/featureGraphic.png) |

> **In-app screenshots are not committed yet.** Rather than ship placeholder or
> mock images, no screenshots from a running build are included until real ones
> are captured. The capture checklist and exact sizes live in
> [docs/listing-assets.md](./docs/listing-assets.md).

## What works today

Everything below works end to end on a real Android device in the current alpha
(`0.1.0-alpha.9`):

- **Local library** — pick a folder with the native Android picker (Storage
  Access Framework), scan it, and list your tracks. The chosen folder and the
  scanned catalog survive a restart. No broad storage permission is requested.
- **Playback** — play local tracks with an up-next queue, plus working
  **shuffle** and **repeat** (off / all / one).
- **Background playback** — a media notification with lock-screen, Bluetooth,
  and wired-headset transport controls.
- **Android Auto** — browse your Library and Queue from the car screen and
  tap to play.
- **Jellyfin (self-hosted)** — connect to your own server, test the connection,
  sign in, sync your library, and **stream** tracks. Works with HTTPS /
  Cloudflare-proxied domains.
- **Navidrome / Subsonic (self-hosted)** — connect to your own
  Subsonic-compatible server, test the connection, sign in, **sync** your
  library, and **stream / cache / cast** tracks. Auth uses the Subsonic
  token+salt scheme, so your password is never stored — only a derived token is
  kept (encrypted). Favorites and lyrics are follow-ups; see
  [docs/providers.md](docs/providers.md).
- **Smart offline cache** — mark individual Jellyfin tracks for offline use
  (Plexamp-style explicit downloads), with a **"Wi-Fi only"** option, a
  configurable cache size limit, "Keep offline" pinning, and optional smart
  pre-caching of upcoming tracks. Cached tracks play fully offline.
- **Synced lyrics** — fetch a Jellyfin track's lyrics into a sheet; favorites
  also sync with your Jellyfin server.
- **Chromecast** — discover Cast devices, connect, and hand off the current
  Jellyfin/Subsonic stream to the receiver, using a pure-Dart Cast protocol (no
  Google Play Services). When connected, the Cast sheet shows a **Cast volume**
  control (slider + mute) that drives the *device's* volume.

## Known limitations

This is an alpha — expect rough edges. The honest gaps today:

- **No tag/metadata parsing yet** — tracks show their file name, and there is
  no album artwork.
- **No browse-by-artist/album and no search** in the in-app library yet.
- **No saved playlists** — there is an up-next queue, but no playlist creation,
  editing, or reordering.
- **Downloads are track-level only** — no album/playlist "download all" and no
  background download manager (downloads run inline; no resume).
- **Single Jellyfin server** — one session at a time; no multi-server support.
- **Subsonic favorites & lyrics** — Navidrome/Subsonic streaming, offline cache,
  and casting work, but favorites, lyrics, and cover art are documented
  follow-ups (see [docs/providers.md](docs/providers.md)).
- **Direct play only** — no server-side transcoding fallback for exotic
  formats; Cloudflare Access / Zero Trust in front of Jellyfin is not supported.
- **On-device files can't be cast** — a Cast receiver can't reach a local file,
  so only Jellyfin streams hand off.
- **Connectivity is optimistic** — the "Wi-Fi only" gate relies on a placeholder
  detector for now.
- **Android only today** — Linux desktop is planned later from the same codebase.
- **Release signing not yet provisioned** — alpha APKs may be debug-signed (see
  [Install](#install)).

## Install

> Linthra is **not on Google Play or F-Droid**. It is distributed as a
> sideloadable APK from **GitHub Releases**. Alpha releases are GitHub
> **pre-releases**.

### Obtainium (recommended)

[Obtainium](https://github.com/ImranR98/Obtainium) installs apps straight from
GitHub Releases and keeps them updated — a great fit for alpha sideloading.

1. Install Obtainium (from its
   [GitHub Releases](https://github.com/ImranR98/Obtainium/releases) or F-Droid).
2. Tap **Add App** and paste the repository URL:
   `https://github.com/thezupzup/linthra`
3. Because alphas are **pre-releases**, open the app's settings in Obtainium and
   enable **"Include prereleases"** so it picks up the latest alpha APK.
4. Tap **Add**, then **Install**. Obtainium will notify you when a newer alpha
   is published.

> **Heads up:** until release signing is provisioned, some alpha APKs may be
> **debug-signed**. If a signature changes between builds, Obtainium may ask you
> to uninstall and reinstall before updating.

### Manual APK sideload

1. Open the [Releases page](https://github.com/thezupzup/linthra/releases) and
   download the `app-release.apk` (or `.apk`) attached to the latest alpha.
2. On your device, open the APK and allow **"install from unknown sources"** if
   prompted. Or, with the phone connected over ADB:
   ```bash
   adb install -r app-release.apk
   ```
3. On first launch (Android 13+), tap **Allow** on the notification prompt so
   the media notification and its controls can appear.

### Build it yourself

Linthra is a standard Flutter app (the committed `android/` scaffold means no
`flutter create` step is needed):

```bash
flutter pub get
flutter build apk --debug   # → build/app/outputs/flutter-apk/app-debug.apk
# or run on a connected device / emulator
flutter run
```

Full build, CI, and release details — including the GitHub **Android Debug APK**
workflow you can use without a local toolchain — are in
[Getting started](#getting-started) and
[Building release artifacts](#building-release-artifacts-android) below.

## Connect your Jellyfin server

Linthra can connect to your own [Jellyfin](https://jellyfin.org) server,
including one published over HTTPS through a Cloudflare domain or tunnel.

1. **Settings → Jellyfin → Server URL** — enter your address, e.g.
   `https://music.example.com` (a bare host gets `https://`; a LAN
   `http://host:8096` and reverse-proxy subpaths also work).
2. **Test connection** — confirms the address is reachable and really is a
   Jellyfin server, and shows its name/version.
3. **Username + password → Sign in** — authenticates and stores the resulting
   session encrypted on-device. Your **password is never saved**.
4. **Sync library** — pulls your artists/albums/tracks into the local catalog so
   they appear in the Library.
5. Tap a synced track to **stream** it, or use the download control to keep it
   **offline**.

Cloudflare-proxied domains and tunnels work out of the box. **Cloudflare Access
/ Zero Trust** (an extra auth layer in front of Jellyfin) is not supported yet.
Full setup notes, supported endpoints, compatibility, and troubleshooting are in
[Jellyfin (self-hosted music) — setup &amp; known limitations](#jellyfin-self-hosted-music--setup--known-limitations)
and [docs/jellyfin-compatibility.md](docs/jellyfin-compatibility.md).

## Privacy &amp; security

Linthra is built to respect the people who use it:

- **No telemetry, no analytics, no phoning home.** The app never uploads your
  library or reports usage.
- **No forced sync and no surprise downloads.** Offline downloads are always
  user-initiated; there is no automatic full-library sync, and a "Wi-Fi only"
  option is respected for remote downloads.
- **Minimal Android permissions.** Just foreground-service + notification (for
  background playback) and internet (to reach your Jellyfin server). **No broad
  storage permission** — folder access uses the Storage Access Framework grant
  you pick.
- **Your Jellyfin secrets stay safe.** The password is used once to obtain a
  token and then discarded — it is **never stored**. The session token is
  encrypted at rest (`flutter_secure_storage`, Android Keystore-backed), is
  **never logged** or shown in the UI, and authenticated stream/download URLs are
  minted only on demand. Diagnostics are secret-free by construction.

More detail lives in the
[Jellyfin security notes](#jellyfin-self-hosted-music--setup--known-limitations)
and the offline-downloads section below.

## Roadmap

**Working now:** local scanning + playback, background playback & media session,
Android Auto browsing, shuffle/repeat, Jellyfin and Navidrome/Subsonic
connect/sync/stream, explicit offline downloads with a smart cache, synced
favorites & lyrics (Jellyfin), and Chromecast with device-volume control.

**Next up (roughly in order):**

1. Tag/metadata parsing and album artwork.
2. Browse by artist/album, and search.
3. Subsonic favorites, lyrics, and cover art.
4. Playlist creation, editing, and queue reordering.
5. Album/playlist "download all" and a background download manager.
6. Real connectivity detection for the "Wi-Fi only" gate.
7. More sources behind the same interface — WebDAV, NAS.

**Later:** local-file lyrics (`.lrc`/tags), ReplayGain, MPRIS, smart playlists,
Linux desktop, and richer Android Auto (album/artist grouping, search) and
casting (local-file casting, receiver transport controls).

See [Roadmap (MVP)](#roadmap-mvp) below for the full breakdown.

## Project status

**Current alpha: `0.1.0-alpha.9`.** Linthra is a manually testable Android build
with several rounds of features and fixes since the first alpha. It is still
early software with honest, documented limitations — see
[Known limitations](#known-limitations) and the
[release notes](./docs/release-notes/v0.1.0-alpha.9.md). It is **not** on
F-Droid, **not** on Google Play, and nothing is published automatically. Release
signing is wired up but not yet provisioned, so some alpha APKs may be
debug-signed (and clearly labeled as such).

## Contributing &amp; deeper docs

Linthra aims to be contributor-friendly: small focused files, explicit naming,
and clean layers (features depend on interfaces in `core/`, never on concrete
services or storage). If you find Linthra useful, a **GitHub star** helps others
discover it.

- **Architecture & extension points:** [Architecture](#architecture)
- **Run it / build it:** [Getting started](#getting-started)
- **Feature deep-dives:** background playback & Android Auto, Now Playing
  controls, folder selection, offline downloads, and Jellyfin — all detailed in
  the sections below.
- **Release, F-Droid & Google Play planning:** [docs/](./docs) (release process,
  signing, F-Droid readiness, dependency/license audit, Jellyfin compatibility,
  and [Google Play closed-testing readiness](#google-play-closed-testing-work-in-progress)).

## Philosophy

- **Local-first & offline-first** — the UI always reads from a local cache.
- **Privacy-focused** — no telemetry, no forced sync.
- **User-controlled downloads** — never automatic; "Wi-Fi only" is respected.
- **No vendor lock-in** — sources (local, Jellyfin, WebDAV, NAS) sit behind a
  single interface.
- **Contributor-friendly** — small focused files, explicit naming, clean layers.

## Target platforms

Android first, Linux desktop later, and possibly Windows — all from one Flutter
codebase.

## Tech stack

| Concern          | Choice                                            |
| ---------------- | ------------------------------------------------- |
| Framework        | Flutter                                           |
| State management | Riverpod                                          |
| Navigation       | go_router (`StatefulShellRoute` for bottom nav)   |
| Local metadata   | SQLite via `drift`                                |
| Playback         | `just_audio` + `audio_service` (behind interface) |
| Remote sources   | `http` (behind `JellyfinClient`)                  |
| Secrets at rest  | `flutter_secure_storage` (Jellyfin session token) |

Dependencies are added when a feature needs them rather than up front, so
`pubspec.yaml` stays honest about what the code actually uses. Today that's
`flutter_riverpod`, `go_router`, `path` (for the local file scanner),
`drift` + `sqlite3_flutter_libs` + `path_provider` for SQLite persistence,
`just_audio` for playback, `audio_service` for the background media session
(notification / lock screen / Android Auto), `file_picker` for the native
folder chooser, `shared_preferences` for remembering the selected folder,
`http` for talking to a Jellyfin server (behind `JellyfinClient`), and
`flutter_secure_storage` for keeping the Jellyfin session token encrypted at
rest (`drift_dev` + `build_runner` are dev-only, for code generation).

## Architecture

Layered and feature-first. The golden rule: **features depend on interfaces in
`core/`, never on concrete services or storage.** That seam is what makes the
Jellyfin/WebDAV roadmap possible without rewriting the UI.

```
lib/
  main.dart                 entry point; hosts the Riverpod ProviderScope
  app/                      app-level wiring
    linthra_app.dart         root MaterialApp.router widget
    router.dart             go_router config (Riverpod provider)
    routes.dart             route path constants
    theme.dart              dark-first ThemeData (violet brand + orange accent)
    colors.dart / dimens.dart  design tokens (palette, spacing, radii)
  core/                     framework-free domain layer
    app_info.dart           static app metadata
    models/                 immutable entities: Track, Album, Artist,
                            Playlist, PlaybackState
    repositories/           persistence contracts: MusicLibraryRepository,
                            PlaylistRepository, DownloadRepository,
                            JellyfinSessionStore
    services/               device-facing contracts: PlaybackController,
                            MusicSource, ConnectivityService
    sources/                concrete MusicSource implementations:
                            local/ (LocalMusicSource + file scanning),
                            jellyfin/ (JellyfinClient + auth + source + mapper)
  data/                     concrete repository implementations + storage
    database/               LinthraDatabase (Drift) + tables/ (tracks_table.dart)
    mappers/                domain <-> Drift row conversion (track_mapper.dart)
    repositories/           drift_music_library_repository.dart (persistent),
                            in_memory_music_library_repository.dart (dev/tests),
                            secure_jellyfin_session_store.dart (encrypted token)
  features/                 one folder per screen/feature
    library/  player/  playlists/  downloads/  settings/ (+ jellyfin/)  shell/
  shared/
    widgets/                reusable UI (e.g. EmptyState)
```

### Key extension points

- **`MusicSource`** (`core/services/music_source.dart`) — a media backend.
  `LocalMusicSource` shipped first; `JellyfinMusicSource`
  (`core/sources/jellyfin/`) and `SubsonicMusicSource` (`core/sources/subsonic/`,
  for Navidrome and other Subsonic-compatible servers) now implement the same
  contract over their own HTTP clients, each with a separate authenticator,
  encrypted session store, and library fetcher — authentication, persistence,
  and library fetching kept apart. A small **capability model**
  (`core/sources/music_provider.dart`) declares what each provider supports
  (`canStream`/`canCache`/`canFavorite`/`canLyrics`/`canCast`) so the UI offers
  only the actions that work. `WebDavMusicSource` slots in the same way later;
  see [docs/providers.md](docs/providers.md).
- **`MusicLibraryRepository`** (`core/repositories/`) — the local SQLite cache
  the UI reads from. Sources *sync into* it; the UI never talks to a source
  directly. This is what keeps the app fast and fully offline.
- **`PlaybackController`** (`core/services/playback_controller.dart`) — playback
  *and* the up-next queue, fully decoupled from `just_audio`. It owns a pure
  [`PlaybackQueue`](lib/core/models/playback_queue.dart) model (current track +
  upcoming tracks) and exposes `playTracks`, `playNext`, `skipToNext`,
  `clearQueue`, and the **shuffle/repeat modes** (`setShuffleEnabled`,
  `setRepeatMode`); shuffle reorders the queue in place (keeping the current
  track playing) and repeat (off / all / one) is consulted when a track
  finishes. The UI reads the queue, `shuffleEnabled`, and `repeatMode` from
  `PlaybackState` and never edits them directly. `LinthraAudioHandler` wraps it
  for background audio / the platform media session (notification, lock screen,
  Android Auto), mirroring shuffle/repeat into the session, without touching
  feature code; MPRIS can attach the same way later.
- **`CastService`** (`core/services/cast/cast_service.dart`) — the seam for
  remote playback handoff (Chromecast). The UI renders a `CastState` and drives
  discovery/connection through this interface, never a cast SDK directly —
  mirroring how the audio engine is hidden behind `PlaybackController`. Android
  and iOS get the real `DefaultCastService`, which owns cast state and the
  playback handoff (resolve the current track's stream URL **at cast time**,
  load it on the receiver, pause local audio; resume on disconnect) while
  delegating the wire protocol to a thin `ChromecastCastTransport` over the
  pure-Dart `cast` package (no Google Play Services / Cast SDK). Other platforms
  keep `UnavailableCastService`, so the button stays honest. The
  network-touching transport is isolated so all of casting's decision-making is
  unit-tested with a fake; the resolved URL (with any token) is never logged or
  persisted. When connected, `CastService` also exposes the receiver's **device
  volume** (`setVolume`/`volumeUp`/`volumeDown`/`setMuted`, surfaced in
  `CastState` as `volume`/`muted`/`supportsVolumeControl`); the Cast sheet shows
  a "Cast volume" slider, and a failed volume command never interrupts playback.
- **`DownloadRepository`** (`core/repositories/`) — enforces the
  user-initiated, "Wi-Fi only"-respecting download policy in one place.
  `CacheDownloadRepository` implements it today over a `DownloadStore`
  (durable cached-ID set), a `DownloadPreferences` ("Wi-Fi only" switch), and a
  `ConnectivityService`. Remote (Jellyfin/WebDAV) downloads add a real
  byte-fetch in `_obtainOfflineCopy` without touching the policy or the UI.

## Getting started

This repository contains the Dart/Flutter source plus the committed **Android**
platform scaffold (`android/`). Other native platform folders (`linux/`, …)
are **not committed** — generate them locally when you need them so the repo
stays focused on the cross-platform Dart code.

```bash
# 1. Fetch dependencies
flutter pub get

# 2. Run on a connected Android device or emulator
flutter run

# (Optional) generate scaffolding for another platform, e.g. Linux desktop:
flutter create --platforms=linux .
```

> Note: `flutter create` may regenerate template files such as `main.dart`.
> If prompted, keep the existing versions in this repo.

### Building a debug APK (Android)

The `android/` scaffold is committed, so no `flutter create` step is needed.
You do need a working Android SDK (`ANDROID_HOME`/`ANDROID_SDK_ROOT` set) and a
JDK that matches the bundled Gradle wrapper — **JDK 17** is the safe choice
for the Gradle 8.3 / Android Gradle Plugin 8.1 the scaffold ships with. Run
`flutter doctor` to confirm your toolchain.

To install and test Linthra on an Android phone:

```bash
flutter pub get

# Build an unsigned debug APK
flutter build apk --debug
# → build/app/outputs/flutter-apk/app-debug.apk

# Or build and install straight onto a connected device
flutter run --debug          # hot-reloadable dev session
flutter install              # installs the last debug build
```

The debug APK is unsigned and meant for local testing only. Release builds and
optional release signing are handled separately by the **Android Release
Build** workflow — manual for test builds, automatic on `v*` tags (see
[Building release artifacts](#building-release-artifacts-android) and
[docs/release-signing.md](./docs/release-signing.md)); nothing is published to a
store or F-Droid. Alpha/beta/rc tags may auto-create a GitHub **pre-release** and
attach artifacts to it, but production release notes are never written for you.

#### Downloading a debug APK from CI

If you don't have a local Flutter/Android toolchain, the
**Android Debug APK** workflow (`.github/workflows/android-debug-apk.yml`)
builds the same `flutter build apk --debug` output on GitHub and attaches it as
a downloadable artifact.

- **How to run it:** open the repo's **Actions** tab → **Android Debug APK** →
  **Run workflow** (the `workflow_dispatch` trigger). It also runs
  automatically on pull requests.
- **Artifact:** `linthra-debug-apk`, containing
  `app-debug.apk` (built from `build/app/outputs/flutter-apk/app-debug.apk`).
- **Download:** open the completed workflow run and grab `linthra-debug-apk`
  from the run's **Artifacts** section. GitHub serves it as a `.zip`; unzip it
  to get `app-debug.apk`.
- **Install manually:** copy the APK to an Android device and open it (you may
  need to allow "install from unknown sources"), or with the device connected
  over ADB run:

  ```bash
  adb install -r app-debug.apk
  ```

This artifact is an **unsigned debug build for testing only** — it is not
signed for release, not published to any store or F-Droid, and no GitHub
release is created.

#### Manual smoke test on a real Android phone

After installing the debug APK on a physical device (most useful on **Android
13+**, where the runtime notification permission applies), walk this checklist —
it covers the paths that only behave correctly on real hardware:

1. **First launch & notification prompt.** Cold-start the app. On Android 13+ a
   **"Allow notifications?"** system prompt should appear shortly after the UI
   loads. Tap **Allow** (the media notification depends on it). If you tap
   **Don't allow**, playback still works but no notification appears — re-enable
   it later under *Settings → Apps → Linthra → Notifications*.
2. **Pick a folder & scan.** Library tab → folder icon → choose a folder with a
   few audio files (e.g. `Music`). It should list the tracks. Pick a folder a
   provider can't traverse (or an empty one) and confirm you get a **clear,
   friendly message or "No music found"**, never a raw error or an indefinite
   spinner.
3. **Play a local track.** Tap a track. It should start, and the **Now Playing**
   screen should show title/artist and working play/pause/next/stop.
4. **Background playback & notification.** Background the app (Home button). Audio
   should keep playing and a **media notification** should show the track with
   working transport controls. Lock the phone and confirm lock-screen controls
   work. Headset/Bluetooth play-pause buttons should work too.
5. **Jellyfin (optional).** Settings → Jellyfin → enter your server URL → **Test
   connection** → sign in → **Sync library** → play a synced track. Confirm
   streaming works over the network. Try a wrong URL / offline server and
   confirm you get a **friendly error** (unreachable / not-a-Jellyfin-server /
   expired session), not a raw failure.
6. **Friendly playback errors.** With Jellyfin signed out, try to play a synced
   Jellyfin track and confirm the Now Playing status line shows a precise,
   friendly message (e.g. "not signed in"), not an opaque engine error.
7. **Download a Jellyfin track for offline.** Signed in and online, tap the
   download icon on a synced Jellyfin track in the Library. It should show a
   spinner, then a filled "downloaded" icon. The track should also appear on the
   **Downloads** tab.
8. **Play a cached track fully offline.** Enable **airplane mode** (or stop the
   server). Play the downloaded track — it should play from the **local cached
   file** with no network error. Then try an *un-downloaded* Jellyfin track and
   confirm you get the friendly "couldn't reach your server" message, never a
   raw failure or a silent hang.
9. **Remove a download.** Back online or off, remove the download (Downloads tab
   trash icon, or the Library row's "remove" action). It should **disappear from
   the Downloads tab immediately** and the Library row should revert to the
   "download" action.
10. **Retry a failed download.** Start a Jellyfin download, then kill the server
    or connection mid-fetch so it fails. The Library row should show an **error
    icon with a "Retry download" tooltip**; tapping it re-attempts the download
    (it succeeds once the server is reachable again).
11. **Wi-Fi-only gate.** On the Downloads tab, turn on **Wi-Fi only**, switch to
    mobile data (or a future real detector), and start a download — it should be
    **queued** rather than run over mobile data. (See the connectivity note in
    *Offline downloads & known limitations*.)
12. **No secrets on screen.** Throughout, confirm no error, status line, or
    track subtitle ever shows a Jellyfin token, `api_key`, password, or raw URL.

See *Testing scanning on Android* below for the SAF-specific detail, and the
*Limitations still remaining* list at the end of this section.

**Android identity & permissions.** The app ships with a stable application ID
**`io.github.thezupzup.linthra`** (also the Kotlin/Gradle `namespace`) and the
display name **Linthra** — both chosen for future F-Droid / GitHub Releases
distribution. Permissions are kept deliberately minimal. The production manifest
declares only:

- **`FOREGROUND_SERVICE`** / **`FOREGROUND_SERVICE_MEDIA_PLAYBACK`** — so
  `audio_service` can keep playing while backgrounded (Android 14+ requires the
  typed `mediaPlayback` grant).
- **`POST_NOTIFICATIONS`** — required on Android 13+ for the media notification
  (and its transport controls) to appear; it is a *runtime* permission the app
  asks for once on first launch (see *Background playback* below).
- **`INTERNET`** — needed to reach a self-hosted Jellyfin server (connection
  test, sign-in, library sync, and streaming). The `debug`/`profile` manifests
  also add it for Flutter's tooling; the manifest merger de-duplicates.

**No storage permission is requested** — folder access uses the Storage Access
Framework grant the user picks. See *Android folder selection & known
limitations* for why a narrow `READ_MEDIA_AUDIO` flow is a deliberate later step
rather than a broad "all files" grant.

> The `audio_service` native wiring (foreground-service permissions, the
> playback `<service>`/`<receiver>`, the Android Auto media-app declaration, and
> `MainActivity` extending `AudioServiceActivity`) documented under *Background
> playback & Android Auto* is now **applied** to the committed scaffold.
> `connectMediaSession` still falls back gracefully if the session can't
> initialise (e.g. an unsupported platform or a test environment), so basic
> playback never depends on it.

### Building release artifacts (Android)

The **Android Release Build** workflow
(`.github/workflows/android-release-build.yml`) builds the Android **release**
artifacts. It runs **manually** for test builds and **automatically on version
tags** so a tagged release builds its APK/AAB without anyone clicking *Run
workflow*. It still never publishes to a store or F-Droid and never writes
production release notes.

- **Manual test builds:** open the repo's **Actions** tab → **Android Release
  Build** → **Run workflow** (`workflow_dispatch`). A `signed` input controls
  whether the build is release-signed (see
  [Signing status](#signing-status-important) below). Manual runs never touch
  any GitHub Release.
- **Automatic tag builds:** pushing a tag matching `v*` (e.g. `v0.1.0-alpha.1`)
  triggers the workflow automatically:

  ```bash
  git tag -a v0.1.0-alpha.1 -m "Linthra 0.1.0-alpha.1"
  git push origin v0.1.0-alpha.1
  ```

  Creating a Release in the GitHub UI on a *new* tag also creates+pushes that
  tag, which starts the same build — so you can write the Release notes first
  and let the build attach to it (see below). The workflow listens only to the
  tag push (not to `release: published`) so a tag never builds twice.
- **What it builds:** `flutter build apk --release` and
  `flutter build appbundle --release`.
- **Artifacts** are named with both the version (tag) and the signing label, so
  a debug-signed preview can never be mistaken for a production release:
  - Tag builds: `linthra-<tag>-<signing>.apk` / `.aab`, e.g.
    `linthra-v0.1.0-alpha.1-debug-signed.apk` or
    `linthra-v0.1.0-alpha.1-release-signed.aab`.
  - Manual builds (no tag): `linthra-<signing>.apk` / `.aab`.
  - The build job uploads each as a workflow artifact
    (`linthra-<signing>-apk` / `linthra-<signing>-aab`) from
    `build/app/outputs/flutter-apk/app-release.apk` and
    `build/app/outputs/bundle/release/app-release.aab`.
- **Release attachment (tag builds only):**
  - **Pre-release tags** — any tag containing `alpha`, `beta`, or `rc` — attach
    their APK/AAB to a GitHub **pre-release**. If no Release exists for the tag,
    one is **created as a pre-release** automatically. These tags may attach
    release-signed *or* clearly-labeled **debug-signed** artifacts; debug-signed
    builds are for **testing only** and are named and described as such.
  - **Stable tags** — e.g. `v1.0.0` — **require release signing**. If the
    `LINTHRA_*` secrets are missing the run **fails fast** rather than attaching
    a debug-signed build. Stable assets are only uploaded to a Release that
    **already exists** (notes stay manual); stable Releases are never
    auto-created.
  - When a Release already exists, assets are uploaded/replaced (`--clobber`).
- **Download:** open the completed run and grab the artifacts from the run's
  **Artifacts** section (GitHub serves each as a `.zip`; unzip to get the
  APK/AAB). For a published Release, download the attached APK/AAB directly from
  the Release page.

Build the same artifacts locally with:

```bash
flutter pub get
flutter build apk --release        # → build/app/outputs/flutter-apk/app-release.apk
flutter build appbundle --release  # → build/app/outputs/bundle/release/app-release.aab
```

#### Signing status (important)

Release signing is **wired up but not yet provisioned**. `android/app/build.gradle`
resolves a release signing config from environment variables (used by CI) or a
git-ignored `android/key.properties` (local). **Only if** complete signing
material is present does it sign with the release key; otherwise it falls back to
the **debug** key so `flutter run --release` still works. **No signing keys or
secrets are committed** to the repo.

- Manual run with **`signed = false`** (default) → **debug-key signed**
  artifacts, labeled `…-debug-signed-…`. Fine for previewing a release build,
  **not** suitable for store or F-Droid distribution.
- Manual run with **`signed = true`** → the workflow decodes a keystore from the
  `LINTHRA_*` repository secrets and produces **release-signed** artifacts
  (labeled `…-release-signed-…`). If a required secret is missing, the run
  **fails fast** rather than silently producing a debug-signed build.
- **Tag build** (`v*` push) → attempts release signing automatically:
  - If the `LINTHRA_*` secrets are present → **release-signed** artifacts,
    eligible for Release attachment.
  - If the secrets are missing on a **pre-release** tag (`alpha`/`beta`/`rc`) →
    the run does **not** pretend to be a production release: it emits a loud
    warning and builds **debug-key signed** artifacts labeled `…-debug-signed`,
    which are attached to a GitHub **pre-release** clearly marked as
    testing-only.
  - If the secrets are missing on a **stable** tag (e.g. `v1.0.0`) → the run
    **fails fast**. Stable releases must be release-signed; debug-signed
    artifacts are never attached to a stable Release.

The keystore secrets are not configured in this repository yet, so until they
are, **pre-release** tag builds fall back to clearly-labeled debug-signed
artifacts (attached to a pre-release for testing), and **stable** tag builds
fail until signing is provisioned. Configure the secrets (see
[docs/release-signing.md](./docs/release-signing.md)) to get release-signed tag
builds. Full details — required
secrets, how to generate/rotate a keystore, and how this relates to F-Droid (which
signs its own builds) — are in [docs/release-signing.md](./docs/release-signing.md).

#### Limitations & next steps

- The workflow **does not** upload anything to a store or submit to F-Droid, and
  it does **not** write production release notes. For **pre-release** tags it can
  create a GitHub pre-release and attach (debug- or release-signed) artifacts to
  it, with auto-generated placeholder notes you should edit. For **stable** tags
  it only attaches release-signed artifacts to a Release you created manually.
- Release signing **secrets are not yet provisioned**, so until they are,
  pre-release tag builds fall back to clearly-labeled debug-signed artifacts
  (for testing only) and stable tag builds fail until signing is configured.
- **Next steps:** provision the `LINTHRA_*` keystore secrets
  ([docs/release-signing.md](./docs/release-signing.md)), then follow the manual
  release/tagging and GitHub-Release flow in
  [docs/release-process.md](./docs/release-process.md). F-Droid readiness is
  tracked separately in [docs/fdroid-readiness.md](./docs/fdroid-readiness.md).

> **First alpha (`v0.1.0-alpha.1`).** The draft GitHub-Release body — what
> works, known limitations, sideload instructions, and the manual release
> steps — lives in
> [docs/release-notes/v0.1.0-alpha.1.md](./docs/release-notes/v0.1.0-alpha.1.md).
> It is a draft only; cutting the tag and publishing the Release stay manual.

### Background playback & Android Auto

Linthra registers a platform **media session** through `audio_service` so
playback survives backgrounding and shows up where the OS expects it:

- **Notification & lock screen.** A media notification mirrors the current
  track (title / artist / album) and exposes **play/pause**, **stop**, and
  **skip-next** (the skip control only appears when the up-next queue has a
  track). Position updates flow through so scrubbing/seek work from the system
  UI.
- **Skip controls.** Transport exposes **skip-previous** and **skip-next**
  alongside play/pause/stop. Each skip button only appears when the queue has a
  track in that direction (`hasPrevious` / `hasNext`), so the controls match what
  the queue can actually do.
- **Android Auto — browsable.** The same session is what Android Auto and other
  media browsers attach to, so the now-playing card and transport controls are
  reachable from the car head unit. On top of that, Linthra now serves a
  **browsable media library** so you can pick what to play from the car screen
  (see the tree below). Selecting a track starts it and queues the rest behind
  it, exactly like tapping a track in the in-app library.

**Media tree.** The browsable hierarchy served to Android Auto is intentionally
shallow:

```
root
├── Library   → every catalog track (tap to play; the rest of the library
│               becomes up-next)
└── Queue     → the current track followed by the up-next list (tap to jump)
```

Nodes are addressed by stable IDs: the `Library` and `Queue` categories, and
leaf IDs `library/<trackId>` and `queue/<index>` that a selection is resolved
back through. Playlists are **not** a node yet — there is no persisted playlist
store, so adding one would not be "safe/simple" (see limitations).

**Architecture.** `audio_service` is a pure infrastructure layer.
`LinthraAudioHandler` (`lib/core/services/linthra_audio_handler.dart`) is the
only file that imports it: it forwards session commands
(play/pause/stop/skip/seek) to the `PlaybackController` and mirrors the
controller's `PlaybackState` back out as the session's playback state + media
item. The browse tree itself is **pure Dart** — `MediaBrowserTree`
(`lib/core/services/media_browser_tree.dart`) builds neutral `MediaNode`s from
the `MusicLibraryRepository` (catalog) and a `PlaybackState` snapshot (the live
queue), and the handler maps those onto `audio_service` media items. So library
data still flows only through `MusicLibraryRepository`, playback still flows only
through `PlaybackController`, and **the UI continues to depend only on
`PlaybackController`** — never on `audio_service`. Attaching the session in
`main.dart` is best-effort: if it fails to initialise (e.g. an unsupported
platform) basic playback still works.

**Native setup (applied).** The required Android wiring lives in the committed
scaffold so the media session can run as a foreground service and be visible to
Android Auto:

- `android/app/src/main/AndroidManifest.xml` declares the playback permissions —
  `FOREGROUND_SERVICE` (run the playback service in the foreground so audio
  continues while backgrounded) and `FOREGROUND_SERVICE_MEDIA_PLAYBACK` (the
  typed-foreground grant Android 14+/API 34 requires for a `mediaPlayback`
  service) — plus `POST_NOTIFICATIONS` (Android 13+ runtime permission, without
  which the notification is silently suppressed). `INTERNET` is also declared
  for Jellyfin; no storage permission is added.
- **Notification permission prompt.** On Android 13+ the media notification only
  shows once the user grants `POST_NOTIFICATIONS`. `LinthraApp` asks for it once
  on first launch (after the first frame, via the `NotificationPermission` seam
  → `permission_handler`). The request is best-effort: if it's denied, playback
  still works but the notification / lock-screen controls won't appear until the
  permission is enabled in system settings.
- the same manifest declares the audio_service playback `<service>`
  (`com.ryanheise.audioservice.AudioService`, `foregroundServiceType`
  `mediaPlayback`, exposing the `MediaBrowserService` action Android Auto binds
  to) and the `<receiver>` (`com.ryanheise.audioservice.MediaButtonReceiver`)
  that handles hardware/Bluetooth/Android Auto media-button intents.
- the manifest also declares the `com.google.android.gms.car.application`
  meta-data pointing at `res/xml/automotive_app_desc.xml` (`<uses name="media"/>`),
  which is what lets Android Auto list Linthra as a media app and bind to the
  browser service to load the tree. Without it the session works but the app
  never appears in the car's browse UI.
- `android/app/.../MainActivity.kt` extends `AudioServiceActivity` (instead of
  the default `FlutterActivity`) so the Flutter activity binds to the session.

For reference, the manifest additions are:

```xml
<manifest ...>
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
  <uses-permission
      android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
  <!-- Android 13+ runtime permission for the media notification. -->
  <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
  <!-- Reaching a self-hosted Jellyfin server. -->
  <uses-permission android:name="android.permission.INTERNET" />

  <application ...>
    <!-- audio_service playback service -->
    <service
        android:name="com.ryanheise.audioservice.AudioService"
        android:foregroundServiceType="mediaPlayback"
        android:exported="true">
      <intent-filter>
        <action android:name="android.media.browse.MediaBrowserService" />
      </intent-filter>
    </service>

    <!-- Media button + Android Auto receiver -->
    <receiver
        android:name="com.ryanheise.audioservice.MediaButtonReceiver"
        android:exported="true">
      <intent-filter>
        <action android:name="android.intent.action.MEDIA_BUTTON" />
      </intent-filter>
    </receiver>

    <!-- Marks Linthra as an Android Auto media app -->
    <meta-data
        android:name="com.google.android.gms.car.application"
        android:resource="@xml/automotive_app_desc" />
  </application>
</manifest>
```

The notification channel id/name are configured in `connectMediaSession`
(`com.linthra.audio` / "Linthra playback").

**Limitations (this PR).**

- The browse tree is **flat**: `Library` is a single flat track list (no
  album/artist/folder grouping) and there is no search-from-Auto. Large
  libraries are not paged.
- **No Playlists node.** Playlists have a model and a repository *interface* but
  no persisted implementation yet, so exposing them would not be safe/simple —
  deferred to a later PR.
- Queue browsing is **read + jump only**: you can play from a queue position,
  but reordering/removing queue items from the car isn't supported.
- The car experience is **basic browsing**, not a polished/custom car UI
  (no tabs, content style hints, or now-playing artwork tuning).
- No MPRIS (Linux desktop media keys) yet.
- Lock-screen / car artwork depends on `Track.artworkUri`, which local scanning
  does not populate yet.

### Now Playing controls — shuffle, repeat, favorite, lyrics & casting

The Now Playing screen drives every transport action through
`PlaybackController`/`PlaybackState`; the widgets hold no playback logic of their
own.

- **Shuffle (working).** The shuffle button toggles a playback *mode* on the
  controller. Turning it on reorders the current queue with the playing track
  kept at the front (so the music never skips), and remembers the original order;
  turning it off restores that order with the current track still current. The
  mode persists, so a queue loaded while shuffle is on starts shuffled. State
  lives in `PlaybackState.shuffleEnabled`, and the button shows its on/off state
  with the accent colour + selected styling. The reordering itself is a pure
  `PlaybackQueue.shuffled()`/`unshuffled()` transform, unit-tested without an
  audio engine.
- **Repeat / loop (working).** The repeat button cycles **off → repeat all →
  repeat one → off**. When a track finishes the controller consults
  `PlaybackState.repeatMode`: *off* plays to the end and stops, *all* wraps from
  the last track back to the first, and *one* replays the current track (from the
  start, without re-resolving its URL — so a stream isn't re-fetched each loop).
  Next/previous keep working normally in every mode. The glyph switches to
  `repeat_one` for repeat-one and is tinted/selected whenever repeat is active.
- **Favorite (working).** The heart toggles a favourite through a
  `FavoritesRepository`. For a **Jellyfin** track the change is synced to the
  server (`POST`/`DELETE …/FavoriteItems/<id>`), so it follows the user across
  clients; for a **local** track it's stored on-device. Either way the UI updates
  optimistically from a single favourite-id set, and a failed server push keeps
  the local intent and reconciles on the next refresh (the signed-in user's
  server favourites are pulled at startup). Only non-secret ids are stored or
  sent — never a token.
- **Lyrics (working for Jellyfin).** The lyrics button fetches the track's
  lyrics from the signed-in Jellyfin server (`GET /Audio/<id>/Lyrics`) behind a
  `LyricsService` seam and shows the lines in a sheet. A track with no lyrics, a
  local track, or being signed out shows a calm "No lyrics available" placeholder
  (and a fetch failure a friendly "couldn't load" line) — never a blank sheet. A
  local `.lrc`/tag reader can slot in behind the same seam later.
- **Cast / Chromecast (working on Android/iOS).** The cast control in the Now
  Playing header opens a device sheet that drives **real Chromecast**: mDNS
  discovery of devices on the network, connect/disconnect, and handing the
  current track off to the receiver. It's built on the pure-Dart `cast` package
  (Google Cast **v2 protocol** over a TLS socket, `bonsoir` for discovery) — **no
  Google Play Services or proprietary Cast SDK**, so the F-Droid build keeps
  casting (see [docs](docs/dependency-license-audit.md#casting-chromecast--real-cast-without-google-play-services)).
  The handoff resolves the current track's stream URL **only at cast time**
  (Jellyfin's or Subsonic's authenticated URL, the credential woven in on demand
  and **never logged or persisted**), tells the receiver to fetch it, and pauses
  local audio so it isn't heard twice; disconnecting (or the receiver dropping)
  resumes local playback. **On-device files can't be cast** — a receiver can't
  reach a `file://` path — so those surface a clear limitation in the sheet
  rather than failing silently. The sheet shows every state honestly: searching,
  available devices, connecting, connected, the local-file notice, and
  error/no-devices.
- **Cast volume.** While connected, the Cast sheet shows a clearly labelled
  **Cast volume** slider plus mute, driving the *device's* own volume (not the
  phone's media volume) and following the receiver's reported level live. It's
  all behind `CastService` (`setVolume`/`volumeUp`/`volumeDown`/`setMuted`), with
  `CastState` exposing `volume`/`muted`/`supportsVolumeControl`; a device that
  reports a fixed volume shows an honest disabled state, and a failed volume
  command surfaces a calm notice **without ever interrupting playback**.
  Architecturally the UI still only touches `CastService`/`CastState`; the real
  `DefaultCastService` owns state + handoff and is fully unit-tested behind a
  faked `CastTransport`, while the thin `ChromecastCastTransport` (the only code
  that opens a socket) is verified by analysis and on-device testing. Platforms
  without a cast stack keep the honest `UnavailableCastService`.

Both shuffle and repeat are also mirrored into the `audio_service` media session
(`shuffleMode`/`repeatMode`), and the session forwards the system's
shuffle/repeat actions back to the controller, so the modes stay coherent
between the in-app screen, the notification, and Android Auto.

### Android folder selection & known limitations

**How scanning works now.** Tap the folder icon in the Library app bar → the
native folder chooser opens → the chosen folder is persisted and immediately
scanned. The selection survives restarts, and the empty state adapts: when no
folder is chosen it invites you to pick one; when a folder is chosen but nothing
playable is found it shows that folder and offers **Rescan folder** / **Change
folder**. On Linux/desktop the same flow uses the GTK/Win32 directory dialog and
returns a real filesystem path, which `LocalMusicSource` scans directly.

**How content:// folders are scanned.** On modern Android the folder chooser
hands back a `content://…/tree/…` URI under the Storage Access Framework (SAF)
rather than a filesystem path. `LocalMusicSource` handles such a selection in
two ways, in order:

1. **Content-resolver traversal (preferred).** A `SafDocumentLister` walks the
   picked tree through Android's content resolver (`DocumentsContract`) in
   native code (`MethodChannelSafDocumentLister` → `SafDocumentScanner.kt`) and
   returns the `content://` document URIs of the audio files it finds. This is
   the scoped-storage-correct path: it uses only the access the system granted
   when the user picked the folder, needs **no** storage permission, and never
   touches `MANAGE_EXTERNAL_STORAGE`. Tracks found this way are stored as their
   `content://` document URIs (titled from the SAF display name) and play back
   directly through that URI.
2. **Filesystem-path fallback.** When native SAF traversal isn't available on
   the build (desktop, or the channel isn't registered), the scan falls back to
   the earlier behaviour: `ContentUriAudioFileScanner` maps an external-storage
   tree URI to a real path via `SafTreeUriResolver` (`primary:Music` →
   `/storage/emulated/0/Music`, named SD-card volumes → `/storage/<volume>/…`,
   `raw:` absolute ids), probes it for readability (`DirectoryReadability`), and
   either walks it or raises a clear `FolderScanException` when scoped storage
   blocks the read.

Desktop/Linux selections are real filesystem paths and always take the
`IoAudioFileScanner` `dart:io` walk, unchanged. How a selection is addressed
(path vs `content://`) is decided once by `FolderLocation`; nothing downstream
re-parses the string, SAF traversal stays behind the `SafDocumentLister` seam,
and the UI never sees a platform channel.

> **Native verification note.** The Dart side of SAF traversal — the lister
> seam, routing, content-URI track mapping, and playback — is fully unit-tested
> with fakes. The native `DocumentsContract` walk compiles in the debug-APK
> workflow but is runtime-verifiable only on a real device/emulator (see the
> manual checklist below). The folder grant is taken best-effort
> (`takePersistableUriPermission`), so a folder picked once can be re-scanned
> after a restart when the picker granted persistable access.

Deliberate gaps the next PRs will close:

- **Content-resolver SAF scanning — landed.** The native `DocumentsContract`
  traversal above reads a picked folder the scoped-storage-correct way, so
  external-storage *and* other document-provider trees can be scanned without a
  filesystem path or a broad permission. The filesystem-path fallback (with its
  `DirectoryReadability` probe and friendly error) remains for builds without
  the native channel. Cross-restart access depends on the picker having granted
  a *persistable* URI permission; if it didn't, re-pick the folder.
- **No runtime storage permissions yet.** No `READ_MEDIA_AUDIO` request flow is
  wired up, and **`MANAGE_EXTERNAL_STORAGE` is intentionally *not* requested** —
  it is an "all files access" permission Google restricts on the Play Store and
  it is the opposite of the scoped-storage approach this project prefers. On
  Android 11+ a resolved path can still be unreadable without a media
  permission; granting `READ_MEDIA_AUDIO` (a narrow, audio-only permission) is
  the natural next step. Until then, point the scan at a folder the app can
  already read, or use the content-resolver follow-up above.
- **No tag/metadata parsing.** Tracks show their title (derived from the file
  name) and fall back to the file path when artist/album tags are absent.
- **Up-next queue with shuffle & repeat, no playlists.** Tapping a track in the
  Library plays it and queues the rest of the visible list behind it; the Now
  Playing screen shows the current track, an **Up next** list, a **Next** button,
  **Clear** (which empties up next but keeps the current track), and working
  **shuffle** and **repeat** controls. When a track finishes, playback follows
  the repeat mode (roll into the next track, wrap the queue, or replay the
  current one). Manual reordering and saved playlists are not part of this
  foundation yet.
- **Jellyfin streaming works; WebDAV pending.** A signed-in user can sync their
  Jellyfin catalog into the Library and stream it (see the Jellyfin section
  below). Other remote sources (WebDAV/NAS) are still pending.

### Testing scanning on Android

1. Build and install a debug APK (see *Building a debug APK* above) on a device
   or emulator.
2. Put a few audio files under a folder on shared storage, e.g.
   `/storage/emulated/0/Music`.
3. In **Library**, tap the folder icon and pick that folder. The chooser
   returns a `content://…/tree/primary:Music` URI; Linthra walks that tree
   through the content resolver and lists the audio files it finds — no path
   resolution or storage permission needed.
4. Tapping a scanned track plays it directly from its `content://` document URI.
5. Picking a folder a document provider can enumerate (including cloud/document
   providers that expose their tree) is scanned the same way. If a provider
   can't be traversed at all, or the build has no native SAF channel and the
   filesystem fallback can't read the resolved path under scoped storage, the
   Library shows a clear, secret-free error instead of a silent empty list.

This SAF traversal is the native step the earlier `content://` routing work set
up. A narrow `READ_MEDIA_AUDIO` permission flow (only relevant to the
filesystem fallback) and a playlist-editor foundation remain natural follow-ups.

### Offline downloads & known limitations

Linthra's offline model is **Plexamp/Plex Pass-style, but open-source and fully
user-controlled**:

- **The full library stays visible.** Syncing Jellyfin shows your whole catalog;
  nothing is hidden behind a download.
- **Downloads are explicit.** You mark the tracks you want offline. There is **no
  automatic full-library sync** and no surprise downloads.
- **Streaming is the default.** An un-downloaded Jellyfin track streams normally
  when you're online and signed in.
- **Cached items are playable offline.** Once a track is downloaded, playback
  **prefers the local cached file**; if it isn't cached and you're offline, the
  player shows a friendly "couldn't reach your server" message rather than
  failing opaquely.
- **The cache stays under a size limit.** You set a maximum (presets of 1, 2, 4,
  8, 16 GB or a custom value; **4 GB by default**), so Linthra never fills your
  phone unexpectedly. Both your downloads **and** any smart-pre-cached upcoming
  tracks (see below) count toward this one limit. When a new download would
  exceed it, space is freed by removing **pre-cached tracks first**, then the
  **least-recently-played, unpinned, not-currently-playing** downloads. Pin a
  track ("Keep offline") to protect it. If nothing safe can be freed, the
  download is refused with a friendly "not enough cache space" message instead of
  deleting something you wanted.

**How it works now.** Each Library row shows an offline-download control:
download an absent track, see a spinner while it's in flight, remove a cached
one, or retry a failed one. The **Downloads** tab lists everything currently
cached — with each track's **size** and a **Keep offline** pin — shows how much
of the limit is in use, and hosts the **Wi-Fi only** toggle. **Settings → Smart
pre-cache** turns automatic pre-caching on/off and sets how many upcoming tracks
to warm (1, 3, 5, or 10); **Settings → Offline cache** shows used / max / free
space and the **Change limit** and **Clear cache** (clear unpinned, or clear
all) actions. The download lifecycle flows through `DownloadRepository`, which
centralizes three guarantees:

- **Downloads are user-initiated.** A track's *download status* only ever changes
  in response to an explicit download/remove action. (Smart pre-cache, below,
  also caches bytes automatically — but a pre-cached track never takes on a
  download status, never shows as a download, and is evicted before any
  download.)
- **Source-aware.** A **Jellyfin** track has its bytes fetched (via
  `RemoteTrackDownloader` → `JellyfinTrackDownloader`) and written to an
  app-private offline directory (`OfflineFileStore`); an **on-device** track is
  already local, so it's recorded as available offline with no network fetch and
  no managed file.
- **Wi-Fi only is respected.** For remote downloads, with the toggle on a request
  made off Wi-Fi is *queued* instead of run; with it off, downloads proceed on
  any connection. (Local tracks are never queued — there are no bytes to fetch.)

**Smart pre-cache.** As playback moves, Linthra warms a small number of upcoming
queued tracks into the same cache ahead of time — the Plex/Plexamp-style "the
next track is already here" feel — so upcoming songs start instantly (and play
offline) instead of buffering a fresh stream at each track change, kept
deliberately modest so it never fills your phone or downloads the whole library.
A `SmartPrecacheService` watches the unified `PlaybackState` and, whenever the
inputs that decide *what to cache* change (the playing track, the up-next list,
shuffle, or repeat), asks a `TrackPrefetcher` (the `CacheDownloadRepository`
again) to warm the next **N** `upNext` entries — which is the **queue order** in
normal playback and the **shuffled order** when shuffle is on, since the
controller keeps `upNext` in effective play order. The same applies while
**casting**: the queue is always owned locally, so it pre-caches the active
queue either way. It is deliberately well-behaved: only remote, not-yet-cached
tracks are fetched, one at a time; it **honours "Wi-Fi only"** (skipping rather
than queueing off Wi-Fi); it respects the cache limit *before* spending data
(and **evicts pre-cached entries before any download**); a pre-cache that won't
fit or fails is silently skipped (the track still streams when reached); and it
never blocks or interrupts what's playing. Under **repeat-one** it stays calm —
the current track loops, so the up-next won't play soon and isn't pre-cached.
Pre-cached tracks count toward cache usage but never appear as downloads, and are
the first to be evicted. Configure it in **Settings → Smart pre-cache**: an
on/off switch (on by default) and the number of upcoming tracks to warm (1, 3,
5, or 10; **3 by default**). Smart pre-cache is automatic and *evictable*; to
keep a song for good, pin it with **Keep offline**, which is protected and never
auto-evicted.

**Storage & playback.** Downloaded bytes live in an app-controlled directory
(`path_provider`'s application-support location, not the OS cache that can be
reclaimed). The durable metadata is a small `CachedTrack` set behind
`DownloadStore`, persisted via `shared_preferences`; each record carries the
non-secret track id, the id-derived cache file name, the source's URI scheme,
the byte size, `cachedAt`/`lastAccessedAt` timestamps, and a `pinned` flag — the
signals the cache manager cleans up by. Playback goes through an
`OfflineFirstPlayableUriResolver`: it asks a `CachedTrackLocator` for a local
copy first and, on a miss, falls back to the source router (Jellyfin streaming,
or the on-device file); a cache **hit refreshes `lastAccessedAt`** so eviction
keeps what you actually listen to. `downloaded` is the only durable state;
`queued`/`downloading`/`failed` are in-memory and reset on restart.

**Smart cache management.** The limit and eviction live in one place. The
`CacheDownloadRepository` also implements an `OfflineCacheManager` (usage stream,
pin, note-played, clear), and delegates the *what to evict* decision to a pure,
exhaustively tested `CacheEvictionPolicy` — never the UI, which only calls the
manager. What can and can't be deleted is a hard line: only **app-managed cache
files** in the offline directory are ever removed (by id-derived file name);
the user's **local source files** in their music folder are never passed to the
file store, so they can't be touched. The **currently playing** track and
**pinned** tracks are never auto-evicted. A managed file the OS reclaimed is
detected on load — its stale metadata is pruned and playback falls back to
streaming rather than opening a missing file. "Clear all" removes everything
(pinned included); "Clear unpinned" keeps what you pinned. The maximum size is a
`DownloadPreferences` value (also `shared_preferences`), clamped to a sane range.

**Security (token handling).** The Jellyfin access token is **never** stored on
`Track.uri`, in the `DownloadStore` metadata, in a cache file name, in a log, or
in a user-facing error. A track's stored URI stays the token-free `jellyfin:<id>`;
the authenticated **download** URL is minted only at fetch time inside
`JellyfinTrackDownloader` (mirroring how the **stream** URL is minted at play
time), and a transport failure is re-raised as a generic message so a
`ClientException` carrying the tokenized URL can't escape. Cache file names are
derived only from the non-secret track id, sanitized to filename-safe characters.
The richer metadata the cache manager adds is likewise non-secret: the stored
**source type is the bare URI scheme** (`jellyfin` / `file`), never the full URL,
and the "not enough cache space" error carries no path, URL, or token.

Deliberate gaps the next PRs will close:

- **Track-level only.** Album- and playlist-level "download all" is intentionally
  out of scope for this PR. The seam is ready — `requestDownload(Track)` plus the
  `RemoteTrackDownloader` compose per-track — so a batch action is additive UI
  over the existing policy, with no architectural change.
- **No background download manager.** Downloads (and smart pre-cache) run inline;
  there is no worker, no Android download/notification service, no resume of a
  partial transfer, and no auto-flush of the queue when Wi-Fi returns (re-tap a
  queued track to retry). Smart pre-cache runs as a foreground side effect of
  playback, not a scheduled background job.
- **Eviction is inline, not a background sweeper.** Space is freed only when a
  new download needs it (and stale metadata only on load); there is no periodic
  reconciliation against the directory's actual on-disk size, and a remote track
  larger than the whole limit can't be cached at all.
- **Connectivity is optimistic.** `OptimisticConnectivityService` always reports
  Wi-Fi until `connectivity_plus` is wired in, so the "Wi-Fi only" gate currently
  blocks only when a test (or a future real detector) reports mobile/offline —
  the seam and its tests are in place for when it does.
- **No Drift table for downloads.** Persisting a small `CachedTrack` set is a
  key/value job; a `downloads` table (with byte progress) graduates from the
  `DownloadStore` seam when background/resumable downloads need it.

### Jellyfin (self-hosted music) — setup & known limitations

Linthra can connect to your own [Jellyfin](https://jellyfin.org) server,
including one published over HTTPS through a **Cloudflare** domain or tunnel.

> **Compatibility reference.** Supported use cases, exact endpoints, the tested
> version floor, Cloudflare Tunnel vs. Zero Trust, troubleshooting, and how to
> report an issue without leaking secrets are documented in
> [docs/jellyfin-compatibility.md](docs/jellyfin-compatibility.md).

**Setup.** Open **Settings → Jellyfin** and:

1. **Server URL** — enter your server address, e.g. `https://music.example.com`.
   A bare host gets `https://` automatically (the Cloudflare-proxied default);
   a `http://host:8096` on your LAN works too, and a reverse-proxy subpath like
   `https://example.com/jellyfin` is preserved.
2. **Test connection** — checks the address is reachable and is really a
   Jellyfin server (it reads the public `/System/Info/Public` endpoint, no
   credentials needed) and shows the server name/version. The server version is
   also classified for compatibility, and an older-than-tested server shows a
   gentle "untested" note (it is never blocked).
3. **Username + password → Sign in** — authenticates and stores the resulting
   session. The password field has a show/hide toggle. Sign-in also records the
   server name/version/product (reading `/System/Info/Public` if you didn't tap
   Test first) so diagnostics show them after a restart.
4. **Sync library** — once signed in, pulls your Jellyfin artists/albums/tracks
   and stores them in the local catalog so they show up in the Library. Shows a
   spinner while it runs and a friendly result/error line when it's done.
5. **Copy Jellyfin diagnostics** — copies a short, **secret-free** report (app
   version, connection state, server name/version/host-only, last error kind) to
   the clipboard for bug reports. It never includes your password, token,
   `Authorization` header, or any full authenticated URL.
6. **Sign out & clear** — forgets the saved session and clears the settings.

**Cloudflare notes.** A Cloudflare-proxied or Cloudflare Tunnel (`cloudflared`)
Jellyfin is just a normal HTTPS endpoint, so it works without any special
configuration — point the URL at your public domain. Two things to know:

- If the domain returns a Cloudflare **error page** (HTML / a 5xx like 521/522)
  or a challenge, Linthra reports a friendly "doesn't look like a Jellyfin
  server" / "couldn't reach the server" message rather than a raw failure —
  usually it means the tunnel is down or the domain isn't pointed at Jellyfin.
- **Cloudflare Access / Zero Trust** (an extra auth layer *in front of*
  Jellyfin) is **not** supported yet; Linthra speaks only to Jellyfin's own
  auth. Use a hostname that reaches Jellyfin directly.

**Security.** This integration is built so secrets don't leak:

- **Passwords are never persisted.** The password is sent once to obtain a
  token and then discarded; it's cleared from the form as soon as sign-in
  succeeds and never enters app state.
- **The token is encrypted at rest.** It's stored via `flutter_secure_storage`
  (Android Keystore-backed), not in plaintext `shared_preferences`.
- **Nothing logs the token or password.** `JellyfinSession.toString()` redacts
  the token, and a track's cached URI is a token-free `jellyfin:<id>` — both the
  authenticated streaming URL (at play time) and the download URL (at fetch time)
  are minted only on demand, never stored.
- **Offline downloads inherit the same handling.** A downloaded track's cache
  file name is derived only from the non-secret track id; the token never lands
  in the file name, the `DownloadStore` metadata, a log, or a download error.
- **Diagnostics are secret-free by construction.** The "Copy Jellyfin
  diagnostics" report (and the debug `PlaybackDiagnostics` log) have no field for
  a password, token, `Authorization` header, or full authenticated URL; the
  server address is reduced to its **host only**, and the persisted server
  version/product are non-secret display values. Tests assert no token reaches
  either sink.

**What works now.** Configuring a server, testing the connection, signing in
with friendly URL/connection/auth errors, persisting the session across
restarts, **syncing the library**, and **streaming playback**. The **Sync
library** action drives `JellyfinSyncController`, which reads the signed-in
`JellyfinMusicSource` (via `jellyfinMusicSourceProvider`), fetches
artists/albums/tracks, and upserts them into `MusicLibraryRepository` under the
stable `jellyfin` source id — the same upsert path local scanning uses. The
Library reloads automatically afterward, so synced tracks appear alongside local
ones. The sync surfaces loading / success / error states and friendly messages
for being **not signed in**, a **server it couldn't reach**, an
**expired/invalid session** (prompting a fresh sign-in), and an **empty Jellyfin
library** (which leaves any existing catalog untouched rather than wiping it).

**Streaming playback** routes through a `PlayableUriResolver` seam, so the
playback controller opens whatever URI it's given rather than assuming a local
file. A `JellyfinPlayableUriResolver` reads the live signed-in source, verifies
the session (a tiny `GET /Users/Me` check), then asks the source to mint the
authenticated **direct-play** stream URL — `/Audio/<id>/stream?static=true` —
**at play time**. `static=true` serves the original file bytes (the reliable
"direct streaming" path the engine can open), rather than a negotiated
transcode/HLS variant ExoPlayer may reject; auth rides in the `api_key` **query**
(not a header), because that is what the engine itself fetches with and query
auth survives the redirects a stripped header would not. Before the URL reaches
the engine the source **probes** it (a one-byte ranged GET, following any
Cloudflare/Jellyfin redirects) and checks the status + content type, so a
Cloudflare page, an expired token, or a non-audio response becomes a precise
message instead of the engine's opaque "couldn't play". The player surfaces
friendly errors — **not signed in**, **expired session**, **server
unreachable**, **a web page instead of audio (Cloudflare/Jellyfin access)**,
**not an audio stream**, a **track that isn't available** (a 404 from the stream
endpoint), an **unsupported server response** (an unexpected status or shape),
and a generic **couldn't stream** — branched on a typed error kind, not message
text (the full mapping is tabulated in the compatibility doc). All Jellyfin URLs
are built in one place (`JellyfinEndpoints`), so the stream, download, and probe
paths can't drift apart. Local and `content://` file playback are untouched
(they never enter the Jellyfin resolver), and a downloaded track still plays from
its cached copy; a cache miss falls straight through to streaming. Debug builds
emit a secret-free `PlaybackDiagnostics` line (source, resolver, HTTP status,
content type, hashed item id) to make field failures diagnosable — never the
token, password, full URL, or `Authorization` header.

**Offline downloads** let a signed-in user mark individual Jellyfin tracks for
offline use; the bytes are fetched from Jellyfin's `/Items/<id>/Download`
endpoint and cached on disk, and playback then prefers the local copy. The full
flow, storage, and token handling are covered in **Offline downloads & known
limitations** above.

**Token safety holds end to end.** A track's stored URI stays the token-free
`jellyfin:<id>`; the authenticated stream/download URLs are built only on demand
and are never stored on the track, written to the catalog, logged, shown in the
UI, or placed in player state. `JellyfinSession.toString()` redacts the token,
and both the playback error messages and the download path are asserted in tests
to contain no token (including when a transport error would otherwise echo the
tokenized URL).

**Deliberate gaps the next PRs will close:**

- **Track-level downloads only.** Album/playlist "download all" is deferred; the
  per-track seam already composes for it (see offline-downloads section above).
- **Single server only.** One session is stored; multi-server support comes
  later.
- **Direct play only (no transcoding fallback yet).** Streaming serves the
  original file (`static=true`), which the engine decodes for the common
  containers; a server-side transcode fallback for exotic formats is deferred.
- **No Android Auto browsing or sync-conflict handling** for Jellyfin in this
  foundation. (Lyrics and favourites now sync from Jellyfin — see **Now Playing
  controls** above.)

## Continuous integration

Every pull request and every push to `main` runs a small Flutter workflow
(`.github/workflows/ci.yml`). It needs to be green before a change merges.

CI runs the checks below, and you can run the exact same ones locally before
opening a PR:

```bash
flutter pub get                      # resolve dependencies
dart format --set-exit-if-changed .  # code must already match `dart format`
flutter analyze                      # static analysis + lints
flutter test                         # widget/unit tests
```

CI pins **Flutter 3.27.x (stable)** for reproducible results; using a matching
SDK locally avoids spurious `dart format` diffs from formatter changes in newer
Dart releases. The automatic `ci.yml` workflow is **code-quality only**. Native
builds and optional release signing live in **separate** workflows (**Android
Debug APK**, and **Android Release Build** — manual for test builds, automatic
on `v*` tags); nothing publishes to a store or F-Droid. See
[Building release artifacts](#building-release-artifacts-android) and
[docs/release-process.md](./docs/release-process.md).

### Generating Drift files in CI

Drift/SQLite persistence relies on `build_runner` code generation, which can be
unreliable to run locally. The **Generate Drift files** workflow
(`.github/workflows/generate-drift.yml`) runs that generation in CI and commits
the result back to the chosen branch. It is **manual only** (`workflow_dispatch`)
— it never runs on a normal push or PR, and it neither builds nor publishes
anything. It uses the same Flutter version as the main CI workflow, runs
`flutter pub get`, `dart run build_runner build --delete-conflicting-outputs`,
and `dart format .`, then commits **only if** something actually changed.

To regenerate Drift files on a PR:

1. Open the Drift PR.
2. Go to the **Actions** tab.
3. Select the **Generate Drift files** workflow.
4. Click **Run workflow** and choose the PR branch.
5. Wait for the bot to push the generated commit (`Generate Drift files`).
6. Let normal CI run against the updated branch.

The workflow pushes to whichever branch you launch it on, so run it on the PR
branch rather than `main`.

## Roadmap (MVP)

1. Local music library scanning
2. Artist / album / track views
3. Playlist creation & editing
4. Audio playback
5. Queue management
6. Search
7. Album artwork
8. Explicit offline downloads
9. "Wi-Fi only downloads" option
10. Settings

Later: Jellyfin (landed — settings, auth, encrypted session, a library source,
Library sync, streaming playback, explicit per-track offline downloads,
smart pre-cache of upcoming tracks, server-synced favourites, and lyrics;
album/playlist "download all" and a background download manager next), Android
Auto (foundation landed — browsable Library/Queue; album/artist grouping and
search next), Chromecast/casting (real device discovery + connect/disconnect +
Jellyfin-stream handoff landed on Android/iOS via a pure-Dart Cast protocol;
local-file casting and receiver transport controls next), WebDAV, NAS, local-file lyrics
(`.lrc`/tags), ReplayGain, MPRIS, smart playlists, and more.

## F-Droid metadata (work in progress)

Linthra is **not** on F-Droid yet, and no submission has been made. As
groundwork for a possible future submission, the repository now carries
F-Droid / Fastlane-style store metadata under
`fastlane/metadata/android/en-US/`:

- `title.txt` — app name.
- `short_description.txt` — one-line summary (kept under F-Droid's 80-char
  limit).
- `full_description.txt` — long description that deliberately separates what
  works today from what is still planned.
- `changelogs/1.txt` — release notes for `versionCode` 1 (the current
  `0.1.0-alpha.1+1`), shown by F-Droid if/when the app is listed.

**Branding (real, committed).** Linthra has a genuine app icon — a small
equalizer of four rounded bars carrying a single violet→orange gradient (the
brand's two colours) on a dark, premium squircle — generated deterministically
from one source design (`tool/branding/linthra_icon.svg` via
`tool/branding/generate_icons.py`, standard library only). That same mark backs:

- the Android launcher icons: regenerated legacy `mipmap-*/ic_launcher.png` plus
  an **adaptive icon** (`mipmap-anydpi-v26/ic_launcher.xml`) with the gradient
  equalizer foreground over a dark vector-gradient background — no longer the
  default Flutter icon;
- the listing graphics: real `images/icon.png` (512×512) and
  `images/featureGraphic.png` (1024×500);
- an in-app `LinthraLogoMark` (`lib/shared/widgets/`), the Dart twin of the same
  mark, shown in the Settings about footer so the identity reads from the home
  screen into the app.

The palette is centralized in `lib/app/colors.dart`: a vivid **violet** carries
the brand (logo, primary actions, structure) and a warm **orange** accent is
held in reserve for *live* states — the play button, active/selected controls,
and playback progress — over a dark, premium surface ramp.

**Still missing: screenshots.** No real screenshots have been captured from a
running build, so none are committed — `images/` carries them as a documented
gap only (`NEEDED-ASSETS.txt`). Placeholder/mock screenshots are intentionally
avoided so the listing never misrepresents the app. The full asset checklist,
exact sizes, and screenshot-capture steps are in
[docs/listing-assets.md](./docs/listing-assets.md).

The wording describes only shipped behaviour (folder selection, scanning, local
and Jellyfin playback, background playback, Android Auto browsing, and explicit
offline downloads) as done; tag parsing, artwork, playlists, and batch
downloads are described as planned. There are no claims of F-Droid availability
and no marketing language that overpromises.

### Release & F-Droid documentation

Planning/readiness docs (none of these publish or submit anything):

- [docs/fdroid-readiness.md](./docs/fdroid-readiness.md) — full F-Droid
  submission checklist: app identity, build requirements, dependency &
  anti-feature review, release/tagging plan, and remaining blockers.
- [docs/fdroid-build-recipe.md](./docs/fdroid-build-recipe.md) — F-Droid build
  recipe planning: expected metadata fields, build-source/toolchain
  expectations, reproducible-build notes, and a draft recipe snippet.
- [docs/dependency-license-audit.md](./docs/dependency-license-audit.md) —
  per-dependency licenses, native/bundled-component review, and the
  network/anti-feature assessment.
- [docs/release-process.md](./docs/release-process.md) — canonical versioning,
  tagging, and (manual) GitHub-Release process.
- [docs/release-signing.md](./docs/release-signing.md) — how release builds are
  signed, required CI secrets, and keystore generation/rotation.
- [docs/listing-assets.md](./docs/listing-assets.md) — store icon, feature
  graphic, and screenshot checklist with capture instructions.

> **Status:** Linthra is **not** on F-Droid and no submission has been made. The
> remaining blockers before a submission would be possible are listed in
> [docs/fdroid-readiness.md §8](./docs/fdroid-readiness.md#8-remaining-blockers-before-submission).

## Google Play closed testing (work in progress)

Linthra is **not** on Google Play, and no submission has been made. As
groundwork for a first **internal / closed testing** (alpha) submission — **not**
a production launch — the repository carries Play-oriented planning docs. None of
them publish or submit anything.

- [docs/play-store-readiness.md](./docs/play-store-readiness.md) — Play
  readiness checklist: identity, AAB vs APK, Play App Signing, testing tracks,
  required assets, blockers, the recommended submission path, versioning, and a
  permissions review.
- [docs/privacy-policy.md](./docs/privacy-policy.md) — privacy policy **draft**
  (needs review and a public URL before submission).
- [docs/google-play-listing.md](./docs/google-play-listing.md) — store listing
  **draft**: short/full description, features, what-works-today, alpha
  limitations, keywords, and a screenshot checklist.
- [docs/google-play-data-safety.md](./docs/google-play-data-safety.md) — Data
  Safety form prep (no ads, no analytics, no data sold; on-device storage and
  the user's own Jellyfin server).

> **Status:** alpha only. The blockers before closed testing — and the much
> longer list before production — are in
> [docs/play-store-readiness.md §9](./docs/play-store-readiness.md#9-known-blockers-before-production).

## License

[MPL-2.0](./LICENSE)
