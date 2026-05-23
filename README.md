# Linthra

A modern, **local-first**, privacy-focused music player for people who own
their music. Linthra is a clean alternative to bloated streaming apps — your
library lives on your device, and downloads are always under your explicit
control.

> **Your music, beautifully yours.**

## Status

**Early-stage, but Library v1 is wired end to end.** Alongside the project
structure, dark-first theming, navigation, app shell, core domain models, and
the service/repository *interfaces*, the Library feature now works as a real
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

**Offline downloads — foundation landed.** The offline-cache lifecycle now
works end to end behind `DownloadRepository`. `CacheDownloadRepository`
(`lib/data/repositories/`) owns the policy in one place and tracks each item's
`DownloadStatus` (`notDownloaded → queued → downloading → downloaded`, plus
`failed`). Two promises are enforced here, not scattered through the UI:
**downloads are only ever user-initiated** (nothing downloads automatically),
and the **"Wi-Fi only" preference is respected** (a request made off Wi-Fi is
*queued* rather than run). Only the `downloaded` set is durable; the transient
states live in memory, so a restart never resurrects a half-finished download.

The durable bit — *which* track IDs are cached — sits behind a small
`DownloadStore` seam, persisted via `shared_preferences` in the app and held
in memory in tests (same reasoning as the selected-folder store: a list of IDs
is the wrong weight for the SQLite catalog). The "Wi-Fi only" switch is a
`DownloadPreferences` seam, also `shared_preferences`-backed. Connectivity is
read through a `ConnectivityService` seam; until real remote downloads land,
the default `OptimisticConnectivityService` reports Wi-Fi (there is no network
fetch to gate yet), and tests inject a fake to drive the mobile/offline paths.
The UI never touches file paths: the Library row shows a per-track
download/remove control and status, and the Downloads tab lists cached tracks
and hosts the "Wi-Fi only" toggle — both talk only to the repository
abstraction. **No actual bytes are fetched yet** (the only source is local
files already on disk); the byte-fetch for remote sources slots into one
private method without the policy changing. See **Offline downloads & known
limitations** below.

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
`jellyfin:<id>`; the streaming URL is minted only at play time). What's *not*
here yet: syncing the Jellyfin catalog into the Library and actual streaming
playback — the source and a `jellyfinMusicSourceProvider` seam are ready for
that next step. See **Jellyfin (self-hosted music) — setup & known limitations**
below.

Not built yet (planned, in roughly this order):

- Local music library scanning — *v1 done (scan → persist → list); native
  folder picker + persisted selection now done; Android `content://` tree URIs
  are now routed and resolved for external storage; tag parsing,
  content-resolver SAF scanning, and a narrow Android media permission still
  pending*
- Audio playback — *done (local playback + up-next queue with skip
  next/previous); background playback + media session via `audio_service` wired
  in Dart **and** with the native Android setup applied (foreground-service
  permissions, playback service, media-button receiver, `AudioServiceActivity`,
  Android Auto media-app declaration); Android Auto now **browsable** (Library /
  Queue nodes, tap-to-play) — not yet a full car UI*
- Playlists
- User-controlled offline downloads — *foundation done (status lifecycle,
  mark/remove offline, Wi-Fi-only seam, UI hooks); real remote byte-fetch and a
  background download manager still pending*
- Lyrics

Self-hosted sources (Jellyfin, WebDAV, NAS) build on the local MVP. The
**Jellyfin foundation has landed** (settings, connection test, authentication,
encrypted session persistence, and a library source); wiring it into the
Library and streaming playback come next.

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
optional release signing are handled separately by the manual **Android Release
Build** workflow (see [Building release artifacts](#building-release-artifacts-android)
and [docs/release-signing.md](./docs/release-signing.md)); nothing is published
to a store or F-Droid, and no GitHub Release is created automatically.

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

**Android identity & permissions.** The app ships with a stable application ID
**`io.github.thezupzup.linthra`** (also the Kotlin/Gradle `namespace`) and the
display name **Linthra** — both chosen for future F-Droid / GitHub Releases
distribution. Permissions are kept deliberately minimal: the production
manifest declares **no** permissions, and `INTERNET` is added only in the
`debug`/`profile` manifests (Flutter needs it for hot reload). No storage
permissions are requested — see *Android folder selection & known limitations*
for why a narrow `READ_MEDIA_AUDIO` flow is a deliberate later step rather than
a broad "all files" grant.

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
artifacts so we can validate a release build ahead of any GitHub Releases /
F-Droid distribution. It is a build-only foundation:

- **How to run it:** open the repo's **Actions** tab → **Android Release
  Build** → **Run workflow**. It is **manual only** (`workflow_dispatch`) — it
  never runs on a push or PR. A `signed` input controls whether the build is
  release-signed (see [Signing status](#signing-status-important) below).
- **What it builds:** `flutter build apk --release` and
  `flutter build appbundle --release`.
- **Artifacts** (names reflect how the build was signed, so a preview can't be
  mistaken for a real release):
  - `signed = false` (default): `linthra-debug-signed-apk` / `linthra-debug-signed-aab`.
  - `signed = true`: `linthra-release-signed-apk` / `linthra-release-signed-aab`.
  - Each contains `app-release.apk` (`build/app/outputs/flutter-apk/app-release.apk`)
    or `app-release.aab` (`build/app/outputs/bundle/release/app-release.aab`).
- **Download:** open the completed run and grab the artifacts from the run's
  **Artifacts** section (GitHub serves each as a `.zip`; unzip to get the
  APK/AAB).

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

- Run the workflow with **`signed = false`** (default) → **debug-key signed**
  artifacts, labeled `…-debug-signed-…`. Fine for previewing a release build,
  **not** suitable for store or F-Droid distribution.
- Run with **`signed = true`** → the workflow decodes a keystore from the
  `LINTHRA_*` repository secrets and produces **release-signed** artifacts
  (labeled `…-release-signed-…`). If a required secret is missing, the run
  **fails fast** rather than silently producing a debug-signed build.

The keystore secrets are not configured in this repository yet, so a real
release-signed build requires setting them up first. Full details — required
secrets, how to generate/rotate a keystore, and how this relates to F-Droid (which
signs its own builds) — are in [docs/release-signing.md](./docs/release-signing.md).

#### Limitations & next steps

- The workflow **does not** create a GitHub release, upload anything to a store,
  or submit to F-Droid. It only produces downloadable build artifacts.
- Release signing **secrets are not yet provisioned**, so until they are, builds
  fall back to the debug key (and are labeled accordingly).
- **Next steps:** provision the `LINTHRA_*` keystore secrets
  ([docs/release-signing.md](./docs/release-signing.md)), then follow the manual
  release/tagging and GitHub-Release flow in
  [docs/release-process.md](./docs/release-process.md). F-Droid readiness is
  tracked separately in [docs/fdroid-readiness.md](./docs/fdroid-readiness.md).

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

- `android/app/src/main/AndroidManifest.xml` declares two minimal permissions —
  `FOREGROUND_SERVICE` (run the playback service in the foreground so audio
  continues while backgrounded) and `FOREGROUND_SERVICE_MEDIA_PLAYBACK` (the
  typed-foreground grant Android 14+/API 34 requires for a `mediaPlayback`
  service). No storage or network permissions are added.
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
hands back a `content://…/tree/…` URI under the Storage Access Framework rather
than a filesystem path. Scanning now routes each selection through a single seam
(`PlatformAudioFileScanner`):

- **Filesystem paths** (desktop/Linux, and any path Android hands back) go to
  `IoAudioFileScanner` — the existing `dart:io` walk, unchanged.
- **`content://` tree URIs** go to `ContentUriAudioFileScanner`, which uses
  `SafTreeUriResolver` to map an external-storage tree URI to a real path
  (`primary:Music` → `/storage/emulated/0/Music`, named SD-card volumes →
  `/storage/<volume>/…`, and `raw:` ids that already carry an absolute path),
  then walks that path. Folders selected this way are stored as ordinary file
  paths, so playback resolution is unchanged.

  Before walking, the scanner probes the resolved path for readability
  (`DirectoryReadability`). On Android 11+ a path the SAF URI resolves to is
  often **not** readable through `dart:io` — picking a folder in the system
  chooser does not by itself grant read access under scoped storage. When the
  path resolves but cannot be listed, the scan now raises a clear
  `FolderScanException` ("Android is not letting it read that location…")
  instead of returning an empty list that would look like "no music found".

How a selection is addressed (path vs `content://`) is decided once by
`FolderLocation`; nothing downstream re-parses the string, and the UI never
sees any of it.

Deliberate gaps the next PRs will close:

- **Scoped storage / content-resolver scanning.** `SafTreeUriResolver` covers
  the common `com.android.externalstorage.documents` provider. Other SAF
  providers (downloads, media, cloud/document providers) don't expose a stable
  path, so a selection from one of those surfaces a clear `FolderScanException`
  in the Library error state instead of a silent empty list. On Android 11+,
  even an external-storage path that resolves cleanly may be unreadable under
  scoped storage; the `DirectoryReadability` probe now turns that into the same
  clear error rather than a silent empty library. The full follow-up is reading
  a SAF tree through Android's content resolver (via a native plugin), which is
  what actually lifts the scoped-storage restriction for picked folders. The
  routing, readability, and error seams are all in place for it.
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
- **No downloads or remote sources** (Jellyfin/WebDAV) yet.

### Testing scanning on Android

1. Build and install a debug APK (see *Building a debug APK* above) on a device
   or emulator.
2. Put a few audio files under a folder on shared storage, e.g.
   `/storage/emulated/0/Music`.
3. In **Library**, tap the folder icon and pick that folder. The chooser
   returns a `content://…/tree/primary:Music` URI; Linthra resolves it to a
   path and, if that path is readable on the device, scans it.
4. On Android 11+ the resolved path is frequently **not** readable under scoped
   storage (the system chooser grants access to the SAF tree, not to the
   underlying filesystem path). In that case the Library shows a clear error
   explaining Android blocked the read — that's the documented limitation, not
   a crash or a silent empty library.
5. Picking a folder from a provider that has no filesystem mapping (for example
   a cloud "Documents" provider) likewise shows the Library error state with a
   clear message.

The next PR is expected to be a playlist-editor foundation or Android SAF
content-resolver folder scanning; a narrow `READ_MEDIA_AUDIO` permission flow
remains a natural follow-up to this work.

### Offline downloads & known limitations

**How it works now.** Each Library row shows an offline-download control:
download an absent track, see a spinner while it's in flight, and remove a
cached one. The Downloads tab lists everything currently cached and hosts the
**Wi-Fi only** toggle. All of this flows through `DownloadRepository`, which
centralizes two guarantees:

- **User-initiated only.** A track's status only ever changes in response to an
  explicit download/remove action — nothing is fetched automatically or in the
  background.
- **Wi-Fi only is respected.** With the toggle on, a request made off Wi-Fi is
  *queued* instead of run; with it off, downloads proceed on any connection.

`downloaded` is the only durable state (persisted as a set of track IDs via
`shared_preferences`); `queued`/`downloading`/`failed` are in-memory and reset
on restart.

Deliberate gaps the next PRs will close:

- **No real downloads yet.** The only source is local files already on disk, so
  "downloading" just records the track as offline-available. Fetching bytes from
  a remote source (Jellyfin/WebDAV) is the follow-up; it slots into
  `CacheDownloadRepository._obtainOfflineCopy` without changing the policy.
- **No background download manager.** Downloads run inline in response to the
  tap; there is no worker, no Android download/notification service, and no
  auto-flush of the queue when Wi-Fi returns (re-tap a queued track to retry).
- **Connectivity is optimistic.** `OptimisticConnectivityService` always reports
  Wi-Fi until `connectivity_plus` is wired alongside real remote downloads, so
  the "Wi-Fi only" gate has nothing to block in the current local-only build —
  the seam and its tests are in place for when it does.
- **No Drift table for downloads.** Persisting a flat ID set is a key/value job;
  a `downloads` table (with file paths and byte progress) graduates from the
  `DownloadStore` seam when real downloads need it.

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
4. **Sign out & clear** — forgets the saved session and clears the settings.

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
  the token, and a track's cached URI is a token-free `jellyfin:<id>` — the
  authenticated streaming URL is minted only at play time, never stored.

**What works now.** Configuring a server, testing the connection, signing in
with friendly URL/connection/auth errors, and persisting the session across
restarts. Under the hood, `JellyfinMusicSource` can already list and map
artists/albums/tracks (and resolve a streaming URL), and is exposed via
`jellyfinMusicSourceProvider`, but is **not yet wired into the Library UI**.

**Deliberate gaps the next PRs will close:**

- **No Library sync or playback yet.** The source isn't fed into
  `MusicLibraryRepository`, so Jellyfin tracks don't appear in the Library and
  remote streaming isn't started from the UI. That's the recommended next PR:
  add a "Sync Jellyfin library" action that calls
  `MusicLibraryRepository.upsertCatalog(sourceId: 'jellyfin', …)` and route
  `resolvePlayableUri` into playback.
- **No offline downloads from Jellyfin.** Fetching bytes for offline use slots
  into `CacheDownloadRepository._obtainOfflineCopy` later (see above).
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
builds and optional release signing live in **separate, manual** workflows
(**Android Debug APK**, **Android Release Build**); nothing publishes to a store
or F-Droid. See [Building release artifacts](#building-release-artifacts-android)
and [docs/release-process.md](./docs/release-process.md).

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

Later: Jellyfin (foundation landed — settings, auth, encrypted session, and a
library source; Library sync + streaming next), WebDAV, NAS, lyrics, ReplayGain,
MPRIS, Android Auto, smart playlists, and more.

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
- `changelogs/1.txt` — placeholder release notes for `versionCode` 1 (the
  current `0.1.0+1`); replaced with real notes once a published version exists.

**Known missing assets.** No real screenshots, feature graphic, or store icon
have been captured from a running build, so none are committed. `images/` only
contains `NEEDED-ASSETS.txt`, which documents the expected F-Droid image layout
to fill in later. Placeholder/mock images are intentionally avoided so the
listing never misrepresents the app — and the default Flutter launcher icons are
not real Linthra branding, so they are not reused as the store icon. The full
asset checklist, exact sizes, and screenshot-capture steps are in
[docs/listing-assets.md](./docs/listing-assets.md).

The wording describes only shipped behaviour (folder selection, scanning, and
persisted listing) as done; playback, playlists, and offline downloads are
described as planned. There are no claims of F-Droid availability and no
marketing language that overpromises.

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
