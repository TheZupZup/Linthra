# Echora

A modern, **local-first**, privacy-focused music player. Echora is a clean
alternative to bloated streaming apps — your library lives on your device, and
downloads are always under your explicit control.

> Status: early foundation. The project scaffold, architecture, theming, and
> navigation are in place; feature implementations are landing incrementally.

## Philosophy

- **Local-first & offline-first** — the UI always reads from a local cache.
- **Privacy-focused** — no telemetry, no forced sync.
- **User-controlled downloads** — never automatic; "Wi-Fi only" is respected.
- **No vendor lock-in** — sources (local, Jellyfin, WebDAV, NAS) sit behind a
  single interface.
- **Contributor-friendly** — small focused files, explicit naming, clean layers.

## Tech stack

| Concern           | Choice                                            |
| ----------------- | ------------------------------------------------- |
| Framework         | Flutter                                           |
| State management  | Riverpod                                          |
| Navigation        | go_router (`StatefulShellRoute` for bottom nav)   |
| Local metadata    | SQLite (planned via `drift`)                      |
| Playback          | `just_audio` + `audio_service` (behind interface) |

Dependencies are added when a feature needs them rather than up front, so the
`pubspec.yaml` stays honest about what the code actually uses.

## Architecture

Layered and feature-first. Three horizontal layers, sliced vertically by
feature. The golden rule: **features depend on interfaces, never on concrete
services or storage.** That seam is what makes the Jellyfin/WebDAV roadmap
possible without rewriting the UI.

```
lib/
  core/        cross-cutting: theme, routing, constants
  models/      immutable domain entities (Song, Album, Artist, Playlist)
  storage/     persistence contract (MusicRepository) + impls
  services/    device-facing contracts (MusicSource, AudioController,
               ConnectivityService) + impls
  features/    UI + state per feature (library, player, playlists,
               downloads, settings, shell)
  widgets/     shared reusable widgets
```

### Key extension points

- **`MusicSource`** (`lib/services/music_source.dart`) — a media backend.
  `LocalMusicSource` ships first; `JellyfinMusicSource` / `WebDavMusicSource`
  implement the same contract later.
- **`MusicRepository`** (`lib/storage/music_repository.dart`) — the local
  SQLite cache the UI reads from. Sources *sync into* it; the UI never talks to
  a source directly. This is what keeps the app fast and fully offline.
- **`AudioController`** (`lib/services/audio_controller.dart`) — playback,
  fully decoupled from `just_audio`. Swappable/wrappable for background audio,
  MPRIS, and Android Auto without touching feature code.

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

## Roadmap (MVP)

1. Local music library scanning
2. Artist / album / song views
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
