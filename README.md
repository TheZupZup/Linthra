# Sonara

A modern, **local-first**, privacy-focused music player for people who own
their music. Sonara is a clean alternative to bloated streaming apps — your
library lives on your device, and downloads are always under your explicit
control.

> **Your music, beautifully yours.**

## Status

**Early-stage. This is the foundation/scaffold only.** What exists today is the
project structure, dark-first theming, navigation, the app shell, placeholder
screens, the core domain models, and the service/repository *interfaces* that
future features will implement.

The **local library scanning foundation** has now started: `LocalMusicSource`
(`lib/core/sources/local/`) discovers audio files under a configured folder and
maps them into `Track`s. It does no tag parsing and isn't wired into the UI yet
— it's the first concrete `MusicSource` and the seam future metadata parsing
will extend.

A temporary `InMemoryMusicLibraryRepository` (`lib/data/repositories/`) now
implements the `MusicLibraryRepository` contract, so the app and its tests have
a concrete catalog to read from before storage lands. It keeps tracks, albums,
and artists in memory, grouped by source — it is **not persistent** and exists
only for development and testing. Drift/SQLite-backed persistence is planned
next, once Dart code generation (`build_runner`) can be verified in CI.

Not built yet (planned, in roughly this order):

- Local music library scanning — *foundation started; tag parsing & UI pending*
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
| Local metadata   | SQLite (planned via `drift`)                      |
| Playback         | `just_audio` + `audio_service` (behind interface) |

Dependencies are added when a feature needs them rather than up front, so
`pubspec.yaml` stays honest about what the code actually uses. Today that's
`flutter_riverpod`, `go_router`, and `path` (for the local file scanner).

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
  data/                     concrete repository implementations
    repositories/           in_memory_music_library_repository.dart (dev/tests)
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
platform folders are generated locally (they're git-ignored for now):

```bash
# 1. Generate platform scaffolding (preserves lib/, pubspec.yaml, etc.)
flutter create --platforms=android,linux .

# 2. Fetch dependencies
flutter pub get

# 3. Run
flutter run
```

> Note: `flutter create` may regenerate template files such as `main.dart`.
> If prompted, keep the existing versions in this repo.

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
