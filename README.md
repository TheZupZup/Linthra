# Sonara

A modern, **local-first**, privacy-focused music player for people who own
their music. Sonara is a clean alternative to bloated streaming apps — your
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
each overridden with a fake/in-memory binding in tests). See **Android folder
selection & known limitations** below for what still needs care on modern
Android.

A temporary `InMemoryMusicLibraryRepository` (`lib/data/repositories/`) also
implements the `MusicLibraryRepository` contract, so the app and its tests have
a concrete catalog to read from. It keeps tracks, albums, and artists in memory,
grouped by source — it is **not persistent** and exists only for development and
testing.

**Drift/SQLite persistence** has now landed for tracks.
`DriftMusicLibraryRepository` (`lib/data/repositories/`) is the persistent
catalog the UI will read from, backed by `SonaraDatabase`
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

Not built yet (planned, in roughly this order):

- Local music library scanning — *v1 done (scan → persist → list); native
  folder picker + persisted selection now done; tag parsing and Android
  runtime storage permissions still pending*
- Audio playback
- Playlists
- User-controlled offline downloads

Self-hosted sources (Jellyfin, WebDAV, NAS) come after the local MVP is solid.

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

Dependencies are added when a feature needs them rather than up front, so
`pubspec.yaml` stays honest about what the code actually uses. Today that's
`flutter_riverpod`, `go_router`, `path` (for the local file scanner),
`drift` + `sqlite3_flutter_libs` + `path_provider` for SQLite persistence,
`just_audio` for playback, `file_picker` for the native folder chooser, and
`shared_preferences` for remembering the selected folder (`drift_dev` +
`build_runner` are dev-only, for code generation).

## Architecture

Layered and feature-first. The golden rule: **features depend on interfaces in
`core/`, never on concrete services or storage.** That seam is what makes the
Jellyfin/WebDAV roadmap possible without rewriting the UI.

```
lib/
  main.dart                 entry point; hosts the Riverpod ProviderScope
  app/                      app-level wiring
    sonara_app.dart         root MaterialApp.router widget
    router.dart             go_router config (Riverpod provider)
    routes.dart             route path constants
    theme.dart              dark-first ThemeData
    colors.dart / dimens.dart  design tokens
  core/                     framework-free domain layer
    app_info.dart           static app metadata
    models/                 immutable entities: Track, Album, Artist,
                            Playlist, PlaybackState
    repositories/           persistence contracts: MusicLibraryRepository,
                            PlaylistRepository, DownloadRepository
    services/               device-facing contracts: PlaybackController,
                            MusicSource, ConnectivityService
    sources/                concrete MusicSource implementations:
                            local/ (LocalMusicSource + file scanning)
  data/                     concrete repository implementations + storage
    database/               SonaraDatabase (Drift) + tables/ (tracks_table.dart)
    mappers/                domain <-> Drift row conversion (track_mapper.dart)
    repositories/           drift_music_library_repository.dart (persistent),
                            in_memory_music_library_repository.dart (dev/tests)
  features/                 one folder per screen/feature
    library/  player/  playlists/  downloads/  settings/  shell/
  shared/
    widgets/                reusable UI (e.g. EmptyState)
```

### Key extension points

- **`MusicSource`** (`core/services/music_source.dart`) — a media backend.
  `LocalMusicSource` ships first; `JellyfinMusicSource` / `WebDavMusicSource`
  implement the same contract later.
- **`MusicLibraryRepository`** (`core/repositories/`) — the local SQLite cache
  the UI reads from. Sources *sync into* it; the UI never talks to a source
  directly. This is what keeps the app fast and fully offline.
- **`PlaybackController`** (`core/services/playback_controller.dart`) — playback,
  fully decoupled from `just_audio`. Swappable/wrappable for background audio,
  MPRIS, and Android Auto without touching feature code.
- **`DownloadRepository`** (`core/repositories/`) — enforces the
  user-initiated, "Wi-Fi only"-respecting download policy in one place.

## Getting started

This repository currently contains the Dart/Flutter source and config. Native
platform folders (`android/`, `linux/`, …) are **not committed** — they're
generated locally so the repo stays focused on the cross-platform Dart code.

```bash
# 1. Generate platform scaffolding (preserves lib/, pubspec.yaml, etc.)
flutter create --platforms=android,linux .

# 2. Fetch dependencies
flutter pub get

# 3. Run on a connected device or emulator
flutter run
```

> Note: `flutter create` may regenerate template files such as `main.dart`.
> If prompted, keep the existing versions in this repo.

### Building a debug APK (Android)

To install and test Sonara on an Android phone:

```bash
# Generate the Android scaffold (skip if android/ already exists locally)
flutter create --platforms=android .

flutter pub get

# Build an unsigned debug APK
flutter build apk --debug
# → build/app/outputs/flutter-apk/app-debug.apk

# Or build and install straight onto a connected device
flutter run --debug          # hot-reloadable dev session
flutter install              # installs the last debug build
```

The debug APK is unsigned and meant for local testing only. **Release signing,
store-ready bundles, and APK publishing are intentionally out of scope** for
this stage — there are no native build, signing, or publishing steps in CI.

### Android folder selection & known limitations

**How scanning works now.** Tap the folder icon in the Library app bar → the
native folder chooser opens → the chosen folder is persisted and immediately
scanned. The selection survives restarts, and the empty state adapts: when no
folder is chosen it invites you to pick one; when a folder is chosen but nothing
playable is found it shows that folder and offers **Rescan folder** / **Change
folder**. On Linux/desktop the same flow uses the GTK/Win32 directory dialog and
returns a real filesystem path, which `LocalMusicSource` scans directly.

Library scanning is exercisable on an Android device, with a few deliberate gaps
the next PRs will close:

- **Android returns a SAF tree URI, not always a filesystem path.** On modern
  Android the system folder chooser hands back a `content://…/tree/…` URI under
  Storage Access Framework. The current `dart:io`-based scanner
  (`IoAudioFileScanner`) reads real filesystem paths, so it can scan folders the
  app can already reach by path but cannot yet walk a raw SAF tree URI.
  Document-tree traversal (or resolving the URI to a path) is a planned
  follow-up; the picker + persistence seam is in place for it.
- **No runtime storage permissions yet.** No `READ_MEDIA_AUDIO` /
  `MANAGE_EXTERNAL_STORAGE` request flow is wired up, so on modern Android you
  may need to point the scan at a directory the app can already read. We are
  intentionally not requesting broad storage permissions in this PR.
- **No tag/metadata parsing.** Tracks show their title (derived from the file
  name) and fall back to the file path when artist/album tags are absent.
- **No queue, playlists, downloads, or remote sources** (Jellyfin/WebDAV) yet.

The next PR is expected to be queue polish or a playlist-editor foundation;
SAF document-tree scanning and Android runtime storage permissions remain the
natural follow-ups to this folder-selection work.

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
Dart releases. This is code-quality CI only — there are no native build,
signing, or store-publishing steps yet.

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

Later: Jellyfin, WebDAV, NAS, lyrics, ReplayGain, MPRIS, Android Auto, smart
playlists, and more.

## License

[MPL-2.0](./LICENSE)
