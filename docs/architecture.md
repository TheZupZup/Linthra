# Architecture

Linthra is a Flutter app, layered and feature-first. The golden rule:
**features depend on interfaces in `core/`, never on concrete services or
storage.** That seam is what makes the Jellyfin / Subsonic / WebDAV roadmap
possible without rewriting the UI.

> This doc covers the *why*. For *where things live and how to navigate the
> code*, see the [codebase tour](codebase-tour.md).

## Philosophy

- **Local-first & offline-first** — the UI always reads from a local cache.
- **Privacy-focused** — no telemetry, no forced sync.
- **User-controlled downloads** — never automatic; Wi-Fi only by default, with
  an explicit "Allow mobile data" opt-in.
- **No vendor lock-in** — sources (local, Jellyfin, Subsonic, WebDAV, NAS) sit
  behind a single interface.
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
| Remote sources   | `http` (behind `JellyfinClient` / Subsonic client)|
| Secrets at rest  | `flutter_secure_storage` (session tokens)         |

Dependencies are added when a feature needs them rather than up front, so
`pubspec.yaml` stays honest about what the code actually uses.

## Layout

```
lib/
  main.dart                 entry point; hosts the Riverpod ProviderScope
  app/                      app-level wiring (router, theme, design tokens)
  core/                     framework-free domain layer
    models/                 immutable entities: Track, Album, Artist,
                            Playlist, PlaybackState, …
    repositories/           persistence contracts: MusicLibraryRepository,
                            PlaylistRepository, DownloadRepository, …
    services/               device-facing contracts: PlaybackController,
                            MusicSource, ConnectivityService, CastService, …
    sources/                concrete MusicSource implementations:
                            local/, jellyfin/, subsonic/
  data/                     concrete repository implementations + storage
    database/               LinthraDatabase (Drift) + tables/
    mappers/                domain <-> Drift row conversion
    repositories/           persistent + in-memory implementations
  features/                 one folder per screen/feature
    library/ player/ playlists/ downloads/ settings/ favorites/ shell/
  shared/
    widgets/                reusable UI (e.g. EmptyState, LinthraLogoMark)
```

## Key extension points

- **`MusicSource`** (`core/services/music_source.dart`) — a media backend.
  `LocalMusicSource` shipped first; `JellyfinMusicSource` and
  `SubsonicMusicSource` (Navidrome and other Subsonic-compatible servers) now
  implement the same contract over their own HTTP clients, each with a separate
  authenticator, encrypted session store, and library fetcher. A small
  **capability model** (`core/sources/music_provider.dart`) declares what each
  provider supports (`canStream` / `canCache` / `canFavorite` / `canLyrics` /
  `canCast`) so the UI offers only the actions that work. `WebDavMusicSource`
  slots in the same way later; see [providers.md](providers.md).
- **`MusicLibraryRepository`** (`core/repositories/`) — the local SQLite cache
  the UI reads from. Sources *sync into* it; the UI never talks to a source
  directly. This is what keeps the app fast and fully offline.
- **Unified library layer** (`core/catalog/track_unifier.dart`) — a pure,
  display-time transform that collapses the per-provider rows the repository
  stores (*source tracks*) into one *logical track* per song, keeping every copy
  as an ordered playback candidate. The browse UI reads the logical tracks; the
  repository and storage are untouched (no migration). Source preference
  (active/default-first, with deterministic fallback) decides which copy plays.
  See [unified-library.md](unified-library.md).
- **`PlaybackController`** (`core/services/playback_controller.dart`) — playback
  *and* the up-next queue, fully decoupled from `just_audio`. It owns a pure
  `PlaybackQueue` model (current track + upcoming tracks) and exposes
  `playTracks`, `playNext`, `skipToNext`, `clearQueue`, and the shuffle/repeat
  modes. `LinthraAudioHandler` wraps it for background audio / the platform
  media session (notification, lock screen, Android Auto); MPRIS can attach the
  same way later. The UI depends only on this interface, never on the engine.
- **`PlayableUriResolver`** (`core/services/playable_uri_resolver.dart`) — turns
  a `Track` into a URI the engine can open. A routing resolver composes
  per-source resolvers (Jellyfin / Subsonic / local) behind an offline-first
  wrapper that prefers a downloaded copy. Remote URL minting — and the secrets it
  weaves in — lives here, never in the audio layer. See
  [streaming.md](streaming.md).
- **`CastService`** (`core/services/cast/cast_service.dart`) — the seam for
  remote playback handoff (Chromecast). The UI renders a `CastState` and drives
  discovery/connection through this interface, never a cast SDK directly. See
  [cast.md](cast.md).
- **`DownloadRepository`** (`core/repositories/`) — enforces the user-initiated,
  mobile-data-respecting download policy in one place. See
  [offline-cache.md](offline-cache.md).

## The single playback seam (local + cast)

The now-playing screen, mini-player, and lyrics read from **one**
`ActivePlaybackController`, which presents a single unified `PlaybackState`:

- The queue (current track, up-next, shuffle, repeat) is always owned by the
  on-device `LocalPlaybackController` (`JustAudioPlaybackController`), regardless
  of which output is making sound.
- While casting, the receiver's position / play-state / duration are folded onto
  that queue, so the UI follows the *device* rather than the silenced engine.
- Transport commands (play/pause/seek) route to whichever output is active;
  queue commands (skip/playTracks) always go to the local controller, whose track
  changes the cast service mirrors onto the receiver.

This is the seam that prevents Cast desync, and it is the reason the engine can
be swapped or wrapped (background playback, MPRIS) without touching feature code.

## Now Playing controls

Every transport action is driven through `PlaybackController` / `PlaybackState`;
the widgets hold no playback logic of their own.

- **Shuffle** is a playback *mode*: turning it on reorders the queue with the
  playing track kept at the front and remembers the original order. The reorder
  is a pure `PlaybackQueue.shuffled()` / `unshuffled()` transform.
- **Repeat** cycles off → all → one. When a track finishes the controller
  consults `repeatMode`: *off* stops at the end, *all* wraps, and *one* replays
  the current track without re-resolving its URL.
- **Favorite** toggles through a `FavoritesRepository` (synced to Jellyfin for
  remote tracks, on-device for local ones), optimistically and token-free.
- **Lyrics** are fetched behind a `LyricsService` seam. The shipped
  implementation is a `LyricsResolver` that routes each track, by the source
  that owns its URI (`MusicProviders.forTrackUri` — the same registry playback
  and capabilities key off), to that source's registered `LyricsProvider`:
  Jellyfin, Subsonic/Navidrome, the local sidecar `.lrc`/`.txt` reader, and an
  explicit `NoLyricsProvider` placeholder for Plex until its lyrics path lands.
  Missing lyrics are `null` (the calm "no lyrics" state), never an error;
  lookups run on demand off the playback path; failures are logged by type
  only through the secret-free `LyricsDiagnostics`.
- **Cast** drives real Chromecast through `CastService`; see [cast.md](cast.md).

## Android folder selection (SAF)

On modern Android the folder chooser returns a `content://…/tree/…` URI under the
Storage Access Framework (SAF) rather than a filesystem path. `LocalMusicSource`
handles a selection in two ways, in order:

1. **Content-resolver traversal (preferred).** A `SafDocumentLister` walks the
   picked tree through Android's content resolver (`DocumentsContract`) in native
   code and returns the `content://` document URIs of the audio files it finds.
   This is the scoped-storage-correct path: it uses only the access the system
   granted, needs **no** storage permission, and never touches
   `MANAGE_EXTERNAL_STORAGE`.
2. **Filesystem-path fallback.** When native SAF traversal isn't available
   (desktop, or the channel isn't registered), the scan maps an external-storage
   tree URI to a real path, probes it for readability, and either walks it or
   raises a clear `FolderScanException` when scoped storage blocks the read.

How a selection is addressed (path vs `content://`) is decided once by
`FolderLocation`; nothing downstream re-parses the string, SAF traversal stays
behind the `SafDocumentLister` seam, and the UI never sees a platform channel.

**Resilience.** Neither walk lets one bad entry zero out the library. The native
SAF walk skips (and counts) a subfolder whose listing fails — a provider hiccup,
a vanished entry on a removable SD card — instead of aborting; only a *total*
access denial (a revoked grant) still surfaces as a clear error. The filesystem
walk likewise skips an unreadable subtree rather than throwing. An audio file is
kept when **either** its name has a known extension **or** the provider reports
an `audio/*` MIME type, so a file recognised only by content type isn't dropped.

**Diagnostics.** Each scan records a secret-free `LocalScanReport` into
`LocalScanDiagnostics` — files visited, audio candidates, skipped-unsupported,
read failures, and the last error *kind* (an enum name, never a path/URI). The
Settings ▸ Diagnostics report surfaces these alongside whether a folder is
selected and whether a persisted SAF read grant is still held, so a "no music
found" report distinguishes an empty folder from a permission loss (the common
removable-SD-card cause) without revealing anything private.

> **No broad storage permission is requested.** `MANAGE_EXTERNAL_STORAGE` ("all
> files access") is intentionally *not* used — it is the opposite of the
> scoped-storage approach this project prefers. A narrow `READ_MEDIA_AUDIO` flow
> (only relevant to the filesystem fallback) is a deliberate later step.
