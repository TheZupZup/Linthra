# Linthra

A modern, **local-first**, privacy-focused music player for people who own
their music. Linthra is a clean alternative to bloated streaming apps — your
library lives on your device, and downloads are always under your explicit
control.

> **Your music, beautifully yours.**

## Status

**First alpha: `0.1.0-alpha.1`.** Linthra is now a manually testable Android
build. Local scanning, local playback, background playback with a media
notification, an Android Auto browse foundation, Jellyfin connect/sync/stream,
and explicit user-initiated offline downloads all work end to end. It is still
early software with honest, documented limitations — see the per-feature
"known limitations" sections below and the
[v0.1.0-alpha.1 release notes](./docs/release-notes/v0.1.0-alpha.1.md). It is
**not** on F-Droid yet, and nothing is published automatically.

**Library v1 and beyond, wired end to end.** Alongside the project
structure, dark-first theming, navigation, app shell, core domain models, and
the service/repository *interfaces*, the Library feature works as a real
vertical slice.

**Library v1.** The Library screen can scan a local folder, persist the
discovered tracks through `MusicLibraryRepository`, and list them back. The
flow is: `LocalMusicSource` discovers audio files under a folder →
`LibraryController` persists them via `MusicLibraryRepository.upsertCatalog`
→ `LibraryScreen` renders the stored tracks (each as title + artist/album, or
the uri/path when no tags exist). The screen renders four states — **loading,
empty, populated, and error** (with retry) — and the UI only ever talks to
`LibraryController`/`LibraryState` and the repository abstraction, never to
Drift or a `MusicSource` directly. Scanning, persistence, and UI state stay in
separate, individually testable layers. See **Android readiness & known
limitations** below for what is intentionally deferred.

`LocalMusicSource` (`lib/core/sources/local/`) discovers audio files under a
configured folder and maps them into `Track`s. It does no tag parsing yet —
it's the first concrete `MusicSource` and the seam future metadata parsing will
extend.

**Folder selection now uses the native picker.** The folder icon in the Library
app bar opens the OS folder chooser (Android Storage Access Framework / desktop
GTK) via a `FolderPickerService` seam, persists the chosen folder through a
`SelectedMusicFolderRepository`, and then scans it. The choice survives restarts
(`shared_preferences` in the app; in-memory in tests). All of this stays behind
interfaces: the UI talks only to `SelectedFolderController` and
`LibraryController`, never to `file_picker` or `shared_preferences` directly.
The scan itself is still exposed as `LibraryController.scanFolder(path)` and runs
through `LocalMusicSource`, so the flow stays fully testable without a real disk
or OS dialog (the picker, the file-system seam, and the selected-folder store are
each overridden with a fake/in-memory binding in tests). The scan seam now also
routes Android `content://` Storage Access Framework selections to a SAF-aware
scanner rather than assuming a filesystem path. See **Android folder selection &
known limitations** below for what still needs care on modern Android.

A temporary `InMemoryMusicLibraryRepository` (`lib/data/repositories/`) also
implements the `MusicLibraryRepository` contract, so the app and its tests have
a concrete catalog to read from. It keeps tracks, albums, and artists in memory,
grouped by source — it is **not persistent** and exists only for development and
testing.

**Drift/SQLite persistence** has now landed for tracks.
`DriftMusicLibraryRepository` (`lib/data/repositories/`) is the persistent
catalog the UI will read from, backed by `LinthraDatabase`
(`lib/data/database/`). At schema **v1** only the `tracks` table is persisted:
`getAllTracks`, `getTrackById`, and `upsertCatalog` are real, while
`getAllAlbums`/`getAllArtists` return empty lists for now. Domain models
(`core/models/`) stay separate from Drift rows; conversion lives in small,
explicit mappers (`lib/data/mappers/`). The generated `*.g.dart` files are
produced by the **Generate Drift files** workflow (see below), not committed by
hand. The running app now persists through the Drift repository: `main`
applies `driftMusicLibraryRepositoryOverride` over `musicLibraryRepositoryProvider`
so scanned tracks survive a restart, while tests keep the in-memory default
(no `path_provider`/SQLite needed) unless they opt into the Drift binding. The
UI is untouched by the swap — it still reads only `LibraryController`/the
repository abstraction.

**Offline downloads — Jellyfin downloads now real (Plexamp-style).** The
offline-cache lifecycle works end to end behind `DownloadRepository`, and
**Jellyfin tracks are now actually fetched and cached for offline playback** —
the model is Plexamp/Plex Pass-style but open-source and fully user-controlled:
the whole library stays visible and streamable, and you mark exactly the tracks
you want offline. `CacheDownloadRepository` (`lib/data/repositories/`) owns the
policy in one place and tracks each item's `DownloadStatus`
(`notDownloaded → queued → downloading → downloaded`, plus `failed`). Three
promises are enforced here, not scattered through the UI:
**downloads are only ever user-initiated** (nothing downloads automatically — no
full-library sync), the policy is **source-aware** (a Jellyfin track has its
bytes fetched and cached; an on-device track is already local, so it's recorded
as available offline with no network fetch), and the **"Wi-Fi only" preference
is respected** for remote downloads (a request made off Wi-Fi is *queued* rather
than run). Only the `downloaded` set is durable; the transient states live in
memory, so a restart never resurrects a half-finished download.

The durable bit — *which* tracks are cached and the file holding each one — sits
behind a small `DownloadStore` seam (a `CachedTrack` record: non-secret track id
+ a track-id-derived file name), persisted via `shared_preferences` in the app
and held in memory in tests. The bytes themselves live behind an
`OfflineFileStore` seam, written to an app-private directory on disk
(`path_provider`'s application-support location) in the app and faked in tests.
The remote byte-fetch is a `RemoteTrackDownloader` seam, implemented for Jellyfin
by `JellyfinTrackDownloader`, which mints the authenticated download URL **only
at fetch time** and never stores or logs it. The "Wi-Fi only" switch is a
`DownloadPreferences` seam, and connectivity a `ConnectivityService` seam
(`OptimisticConnectivityService` reports Wi-Fi by default; tests inject a fake to
drive the mobile/offline paths). The UI never touches file paths: the Library
row shows a per-track download/remove/retry control and status, the Downloads
tab lists cached tracks and hosts the "Wi-Fi only" toggle, and **playback
prefers the cached file** (via an `OfflineFirstPlayableUriResolver`) before
streaming — all talking only to download-state and resolver abstractions. See
**Offline downloads & known limitations** below.

**Jellyfin (self-hosted) — foundation landed.** The first remote source is
wired from the Settings screen through to a `MusicSource`. A user can enter
their server URL, **test the connection**, **sign in**, and **clear** their
settings; the session token is then persisted in encrypted on-device storage
(`flutter_secure_storage`) so it survives restarts. HTTPS **Cloudflare-proxied**
domains are a first-class case. The layering mirrors local scanning and keeps
the three concerns apart: all networking sits behind `JellyfinClient`
(`HttpJellyfinClient` is the only place that builds URLs, sets the auth header,
and parses JSON); `JellyfinAuthenticator` validates the URL and produces a
session; `JellyfinSessionStore` persists it; and `JellyfinMusicSource` lists
and maps artists/albums/tracks into Linthra's `Track`/`Album`/`Artist` models.
The Settings UI talks only to `JellyfinSettingsController`/`JellyfinSettingsState`
— never to HTTP or storage. **Passwords are never stored** (used once to obtain
a token, then discarded) and **tokens are never logged** (the session redacts
its token in `toString`, and a track's stored URI is a token-free
`jellyfin:<id>`; the streaming URL is minted only at play time). **Library sync
now works:** once signed in, a **Sync library** action pulls your Jellyfin
artists/albums/tracks and upserts them into the same `MusicLibraryRepository`
the Library reads from, under the stable `jellyfin` source id (driven by
`JellyfinSyncController`/`JellyfinSyncState` over the existing
`jellyfinMusicSourceProvider` seam). **Streaming playback now works too:**
tapping a synced Jellyfin track plays it. Playback resolves through a
`PlayableUriResolver` seam — a `JellyfinPlayableUriResolver` verifies the
session and mints the authenticated stream URL *at play time*, so the token is
never stored on the track, in the catalog, in logs, or in player state. The
player shows precise, secret-free errors (not signed in / expired session /
unreachable server / unavailable stream). **Jellyfin offline downloads now work
too** — see the offline-downloads section above and **Jellyfin (self-hosted
music) — setup & known limitations** below.

Not built yet (planned, in roughly this order):

- Local music library scanning — *v1 done (scan → persist → list); native
  folder picker + persisted selection now done; Android `content://` tree URIs
  are now routed and resolved for external storage, **and SAF folders are now
  scanned through the content resolver** (native `DocumentsContract` traversal,
  scoped-storage friendly, no broad permission); tag parsing and a narrow
  Android media permission still pending*
- Audio playback — *done (local + **Jellyfin streaming** playback, behind a
  `PlayableUriResolver`, plus an up-next queue with skip next/previous);
  background playback + media session via `audio_service` wired in Dart **and**
  with the native Android setup applied (foreground-service permissions,
  playback service, media-button receiver, `AudioServiceActivity`, Android Auto
  media-app declaration); Android Auto now **browsable** (Library / Queue nodes,
  tap-to-play) — not yet a full car UI*
- Playlists
- User-controlled offline downloads — *done for tracks (Plexamp-style explicit
  downloads: real Jellyfin byte-fetch, app-private cache, cache-first playback,
  remove/retry); album/playlist-level "download all" and a background download
  manager still pending*
- Lyrics

Self-hosted sources (Jellyfin, WebDAV, NAS) build on the local MVP. The
**Jellyfin foundation has landed** (settings, connection test, authentication,
encrypted session persistence, and a library source), **library sync is wired
in**, **streaming playback works**, and **explicit offline downloads now work**
— a signed-in user can pull their Jellyfin catalog into the Library, play it,
and mark individual tracks for offline use.

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
    theme.dart              dark-first ThemeData
    colors.dart / dimens.dart  design tokens
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
  (`core/sources/jellyfin/`) now implements the same contract over a
  `JellyfinClient` (HTTP behind one interface), with `JellyfinAuthenticator`
  for sign-in and `JellyfinSessionStore` for the encrypted token —
  authentication, persistence, and library fetching kept separate.
  `WebDavMusicSource` slots in the same way later.
- **`MusicLibraryRepository`** (`core/repositories/`) — the local SQLite cache
  the UI reads from. Sources *sync into* it; the UI never talks to a source
  directly. This is what keeps the app fast and fully offline.
- **`PlaybackController`** (`core/services/playback_controller.dart`) — playback
  *and* the up-next queue, fully decoupled from `just_audio`. It owns a pure
  [`PlaybackQueue`](lib/core/models/playback_queue.dart) model (current track +
  upcoming tracks) and exposes `playTracks`, `playNext`, `skipToNext`, and
  `clearQueue`; the UI reads the queue from `PlaybackState` and never edits it
  directly. `LinthraAudioHandler` wraps it for background audio / the platform
  media session (notification, lock screen, Android Auto) without touching
  feature code; MPRIS can attach the same way later.
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
- **Basic up-next queue, no playlists.** Tapping a track in the Library plays it
  and queues the rest of the visible list behind it; the Now Playing screen shows
  the current track, an **Up next** list, a **Next** button, and **Clear** (which
  empties up next but keeps the current track). When a track finishes, playback
  rolls into the next queued track. Reordering, saved playlists, shuffle, and
  repeat are not part of this foundation yet.
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

**How it works now.** Each Library row shows an offline-download control:
download an absent track, see a spinner while it's in flight, remove a cached
one, or retry a failed one. The Downloads tab lists everything currently cached
and hosts the **Wi-Fi only** toggle. All of this flows through
`DownloadRepository`, which centralizes three guarantees:

- **User-initiated only.** A track's status only ever changes in response to an
  explicit download/remove action — nothing is fetched automatically or in the
  background.
- **Source-aware.** A **Jellyfin** track has its bytes fetched (via
  `RemoteTrackDownloader` → `JellyfinTrackDownloader`) and written to an
  app-private offline directory (`OfflineFileStore`); an **on-device** track is
  already local, so it's recorded as available offline with no network fetch and
  no managed file.
- **Wi-Fi only is respected.** For remote downloads, with the toggle on a request
  made off Wi-Fi is *queued* instead of run; with it off, downloads proceed on
  any connection. (Local tracks are never queued — there are no bytes to fetch.)

**Storage & playback.** Downloaded bytes live in an app-controlled directory
(`path_provider`'s application-support location, not the OS cache that can be
reclaimed). The durable metadata is a small `CachedTrack` set (track id + cache
file name) behind `DownloadStore`, persisted via `shared_preferences`. Playback
goes through an `OfflineFirstPlayableUriResolver`: it asks a `CachedTrackLocator`
for a local copy first and, on a miss, falls back to the source router (Jellyfin
streaming, or the on-device file). `downloaded` is the only durable state;
`queued`/`downloading`/`failed` are in-memory and reset on restart.

**Security (token handling).** The Jellyfin access token is **never** stored on
`Track.uri`, in the `DownloadStore` metadata, in a cache file name, in a log, or
in a user-facing error. A track's stored URI stays the token-free `jellyfin:<id>`;
the authenticated **download** URL is minted only at fetch time inside
`JellyfinTrackDownloader` (mirroring how the **stream** URL is minted at play
time), and a transport failure is re-raised as a generic message so a
`ClientException` carrying the tokenized URL can't escape. Cache file names are
derived only from the non-secret track id, sanitized to filename-safe characters.

Deliberate gaps the next PRs will close:

- **Track-level only.** Album- and playlist-level "download all" is intentionally
  out of scope for this PR. The seam is ready — `requestDownload(Track)` plus the
  `RemoteTrackDownloader` compose per-track — so a batch action is additive UI
  over the existing policy, with no architectural change.
- **No background download manager.** Downloads run inline in response to the
  tap; there is no worker, no Android download/notification service, no resume of
  a partial transfer, and no auto-flush of the queue when Wi-Fi returns (re-tap a
  queued track to retry).
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

**Setup.** Open **Settings → Jellyfin** and:

1. **Server URL** — enter your server address, e.g. `https://music.example.com`.
   A bare host gets `https://` automatically (the Cloudflare-proxied default);
   a `http://host:8096` on your LAN works too, and a reverse-proxy subpath like
   `https://example.com/jellyfin` is preserved.
2. **Test connection** — checks the address is reachable and is really a
   Jellyfin server (it reads the public `/System/Info/Public` endpoint, no
   credentials needed) and shows the server name/version.
3. **Username + password → Sign in** — authenticates and stores the resulting
   session. The password field has a show/hide toggle.
4. **Sync library** — once signed in, pulls your Jellyfin artists/albums/tracks
   and stores them in the local catalog so they show up in the Library. Shows a
   spinner while it runs and a friendly result/error line when it's done.
5. **Sign out & clear** — forgets the saved session and clears the settings.

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
authenticated `/Audio/<id>/universal` URL **at play time**. The player surfaces
precise, friendly errors — **not signed in**, **expired session**, **server
unreachable**, **stream unavailable** — branched on a typed error kind, not
message text. Local file playback is untouched (it never enters the Jellyfin
resolver).

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
- **Single server only.** One session is stored; multi-server support and
  richer transcoding/streaming parameters come later.
- **No Android Auto browsing, lyrics, or sync-conflict handling** for Jellyfin
  in this foundation.

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
Library sync, streaming playback, and explicit per-track offline downloads;
album/playlist "download all" and a background download manager next), Android
Auto (foundation landed — browsable Library/Queue; album/artist grouping and
search next), WebDAV, NAS, lyrics, ReplayGain, MPRIS, smart playlists, and more.

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

**Branding (real, committed).** Linthra now has a genuine app icon — four
rounded white equalizer bars on the brand violet gradient — generated
deterministically from one source design (`tool/branding/linthra_icon.svg` via
`tool/branding/generate_icons.py`, standard library only). That same mark backs:

- the Android launcher icons: regenerated legacy `mipmap-*/ic_launcher.png` plus
  an **adaptive icon** (`mipmap-anydpi-v26/ic_launcher.xml`) with a white-bars
  foreground over a vector gradient background — no longer the default Flutter
  icon;
- the listing graphics: real `images/icon.png` (512×512) and
  `images/featureGraphic.png` (1024×500).

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

## License

[MPL-2.0](./LICENSE)
