# Codebase tour

New to the code? Start here. This is the map — *where things live and how they
fit together* — so you can find the file you need without reading all 250 of
them first.

It's a companion to [architecture.md](architecture.md), which explains the
*why* (the layering, the golden rule, the extension points). This doc is the
*where*. When a section gets deep, it hands off to the focused per-feature doc.

A quick orientation, then a "where does X live?" index, then a short tour of
each area, and finally the rule that matters most: **what must never leak.**

## The 30-second mental model

Linthra is a layered Flutter app. Four directories, one rule:

```
lib/
  app/        wiring: router, theme, design tokens
  core/       the domain layer — framework-free. models, interfaces, source impls
  data/       concrete storage: the Drift database, repository implementations
  features/   one folder per screen (library, player, settings, …)
  shared/     a few reusable widgets
```

**The golden rule:** `features/` depend on *interfaces* in `core/`, never on a
concrete service or a database. That seam is why a new provider or a swapped
playback engine doesn't ripple into the UI.

Two data-flow ideas explain almost everything:

1. **Sources sync *into* a local catalog; the UI reads the catalog.** A
   `MusicSource` (local folder, Jellyfin, Subsonic) fetches tracks and writes
   them into the on-device SQLite cache (`MusicLibraryRepository`). Screens
   watch that repository — never a server directly. That's what makes the app
   instant and fully offline.
2. **All playback goes through one controller.** The now-playing screen,
   mini-player, lock screen, and Android Auto all read a single
   `PlaybackState` from one `PlaybackController`. Whether sound comes from the
   phone or a Cast device, the UI follows that one seam.

Dependencies are wired with [Riverpod](https://riverpod.dev) providers. When
you want to know "what's the real implementation behind this interface?", find
the `*_provider.dart` (or `*_providers.dart`) file — that's where a concrete
class is bound to its interface, and where tests swap in fakes.

## Where does X live?

| Looking for… | Start at |
| --- | --- |
| Playback & the queue | `lib/core/services/playback_controller.dart` (interface), `active_playback_controller.dart` (router) |
| The actual audio engine | `lib/core/services/just_audio_playback_controller.dart` |
| Background playback / lock screen / Android Auto | `lib/core/services/linthra_audio_handler.dart`, `media_browser_tree.dart` |
| Turning a track into a playable URL | `lib/core/services/playable_uri_resolver.dart` + the resolvers beside it |
| Cast / Chromecast | `lib/core/services/cast/` and `lib/features/player/cast/` |
| Local-files provider | `lib/core/sources/local/` |
| Jellyfin provider | `lib/core/sources/jellyfin/` |
| Navidrome / Subsonic provider | `lib/core/sources/subsonic/` |
| What each provider can do (capabilities) | `lib/core/sources/music_provider.dart` |
| Downloads & offline cache | `lib/data/repositories/cache_download_repository.dart` |
| Smart pre-cache | `lib/core/services/smart_precache_service.dart` |
| The local library the UI reads | `lib/core/repositories/music_library_repository.dart` + `lib/data/database/` |
| Search | `lib/features/library/library_search.dart` |
| Albums / artists grouping + text folding | `lib/core/catalog/library_grouping.dart`, `lib/core/catalog/text_folding.dart` (shared by the Library UI and the Android Auto browse tree) |
| Playlists & favorites | `lib/features/playlists/`, `lib/features/favorites/` |
| Smart mixes | `lib/features/smart_mixes/`, `lib/core/services/smart_playlist_resolver.dart` |
| Diagnostics & "Report a bug" | `lib/core/diagnostics/`, `lib/features/settings/bug_report/` |
| Settings UI | `lib/features/settings/settings_screen.dart` + section folders beside it |
| Stored preferences vs. secrets | `lib/data/repositories/shared_preferences_*.dart` vs. `secure_*_session_store.dart` |

## Playback

Everything that makes sound lives under `lib/core/services/`, and the UI only
ever talks to **one** thing: `PlaybackController`
(`playback_controller.dart`). It owns playback *and* the up-next queue —
`playTracks`, `skipToNext`, `seek`, shuffle, and repeat — and emits immutable
`PlaybackState` snapshots. The widgets hold no playback logic of their own.

Three layers sit behind that interface:

- **`ActivePlaybackController`** (`active_playback_controller.dart`) is the
  router. It picks the active output — the phone or a Cast device — and merges
  the receiver's position/play-state onto the local queue while casting, so the
  UI follows whatever is actually playing. This is the seam that prevents Cast
  desync.
- **`JustAudioPlaybackController`** (`just_audio_playback_controller.dart`) is
  the real engine and the *only* file that knows `just_audio` exists. It owns
  the `PlaybackQueue`, the shuffle/repeat modes, volume normalization, and
  error recovery.
- **`LinthraAudioHandler`** (`linthra_audio_handler.dart`) bridges to
  `audio_service` — the media notification, lock-screen controls, and the
  Android Auto browse tree (`media_browser_tree.dart`). It's a thin adapter,
  not a second engine: it listens to the controller's state and forwards
  platform button presses back.

The models are plain data: `PlaybackState`, `PlaybackQueue` (a pure value type
with `shuffled()`/`unshuffled()` transforms), and `RepeatMode`.

**How a `Track` becomes something the engine can open** is a small chain of
`PlayableUriResolver`s (`playable_uri_resolver.dart`), composed offline-first:

1. `OfflineFirstPlayableUriResolver` — if a downloaded copy exists, play the
   local file and stop here.
2. `RemoteCacheResolver` — otherwise reuse a pre-warmed (prebuffered) remote
   stream URL if one is still fresh (`core/services/remote_cache/`).
3. `RoutingPlayableUriResolver` — otherwise route to the per-source resolver
   (`jellyfin_playable_uri_resolver.dart`, `subsonic_playable_uri_resolver.dart`,
   or the local one), which mints the real URL.

Remote URL minting — and the credentials woven into those URLs — lives *here*,
never in the audio layer. The remote prebuffer/cache foundation that warms those
URLs ahead of a skip (credential-free keys in memory, plus a durable
credential-free on-disk index that never stores the URL) is described in
[remote-playback-cache.md](remote-playback-cache.md). The UI entry point that
wires all of this is `lib/features/player/player_providers.dart`. Deeper dives:
[streaming.md](streaming.md), [background-playback.md](background-playback.md),
[queue.md](queue.md).

## Cast / Chromecast

Cast lives in two places: the seam in `lib/core/services/cast/` and the UI in
`lib/features/player/cast/`. As with playback, the UI only touches an
interface — `CastService` (`cast_service.dart`) — and renders a `CastState`.

- **`DefaultCastService`** (`default_cast_service.dart`) owns discovery,
  session lifecycle, and the hand-off when the playing track changes.
- **`ChromecastCastTransport`** (`chromecast_cast_transport.dart`) is the thin
  layer that actually speaks the Cast protocol (mDNS discovery, the TLS
  session). It's pure Dart — no Google Play Services.
- **`CastMediaResolver`** turns a track into a castable media item.
  `RoutingCastMediaResolver` dispatches to `jellyfin_cast_media_resolver.dart`
  or `subsonic_cast_media_resolver.dart`. `CastLoadMessage` builds the Cast v2
  `LOAD` payload.
- On platforms without Cast, `UnavailableCastService` is bound instead, so the
  rest of the app doesn't special-case it.

**What's sent to the receiver:** the authenticated stream URL plus display
metadata (title, artist, album, and — for Jellyfin — a token-free artwork URL).
That's it. The receiver never sees your queue, your other tracks, or app state.

**Token rules (read this before touching Cast).** The stream URL carries the
credential, and it is minted on demand at cast time and lives *only* on the
`CastMedia` object handed to the transport. It is never written to `CastState`,
never logged, never persisted. `CastMedia.toString()` deliberately redacts the
URL down to `scheme://host/path` so it's safe to interpolate into a log line.
Subsonic cover-art URLs embed the credential, so Subsonic artwork is
intentionally *omitted* from the cast payload rather than leaked. Full picture:
[cast.md](cast.md).

## Providers (where your music comes from)

A "provider" is a music backend. They all implement one contract —
`MusicSource` (`lib/core/services/music_source.dart`) — and each declares what
it can actually do through a small **capability model** in
`lib/core/sources/music_provider.dart` (`canStream`, `canCache`, `canCast`,
`canSyncFavorites`, `canLyrics`, and friends). The UI reads those flags so it
only offers actions that work, instead of scattering `if (jellyfin)` checks
everywhere.

Three sources ship today, each in its own folder under `lib/core/sources/`:

- **Local files** — `local/`. `LocalMusicSource` scans a folder you pick.
  On Android the picker returns a Storage Access Framework tree URI, so
  `audio_file_scanner.dart` walks it through the content resolver
  (`saf_document_lister.dart`) with **no broad storage permission**. See the
  SAF section in [architecture.md](architecture.md#android-folder-selection-saf).
- **Jellyfin** — `jellyfin/`. `JellyfinMusicSource` orchestrates an HTTP
  client (`http_jellyfin_client.dart` behind the `JellyfinClient` interface),
  with URL building in `jellyfin_endpoints.dart`, wire-to-`Track` conversion in
  `jellyfin_track_mapper.dart`, and sign-in in `jellyfin_authenticator.dart`.
- **Navidrome / Subsonic** — `subsonic/`. Same shape:
  `SubsonicMusicSource`, `http_subsonic_client.dart`, `subsonic_endpoints.dart`,
  `subsonic_track_mapper.dart`, `subsonic_authenticator.dart`.

Jellyfin and Subsonic look like near-mirror images on purpose — they're two
independent protocols, so the duplication is healthy, not accidental. If you're
adding **WebDAV/NAS**, copy that shape: implement `MusicSource`, declare your
capabilities, and let the rest of the app stay unchanged.

**The sync seam:** a source's job is to fetch tracks and hand them to
`MusicLibraryRepository.upsertCatalog(...)`, which writes them into the local
SQLite cache (`lib/data/database/`, Drift). The library/sync controllers in
`features/` drive that. The UI then reads the catalog, never the server. More:
[providers.md](providers.md), [jellyfin.md](jellyfin.md),
[streaming.md](streaming.md).

## Offline cache & downloads

The whole download policy lives in one place:
`lib/data/repositories/cache_download_repository.dart` (the `DownloadRepository`
interface is in `core/`). Keeping it in one file is deliberate — there's a
single place to reason about *when* a download is allowed, *whether* it fits,
and *what* gets evicted.

- **Manual "Keep offline."** A user tap calls `requestDownload(track)`. Remote
  tracks get fetched and pinned; on-device tracks are just recorded (nothing to
  fetch). Bytes land in an app-private directory via
  `file_system_offline_file_store.dart`; the track↔file mapping persists in
  shared preferences. The UI for this is `lib/features/downloads/`.
- **Smart pre-cache.** `lib/core/services/smart_precache_service.dart` watches
  playback and quietly warms the next few upcoming tracks. It's best-effort and
  invisible: pre-cached entries don't show up as downloads and are evicted
  before any track you explicitly kept. Settings live in
  `features/settings/precache/`.
- **Wi-Fi vs. mobile data.** There is exactly one chokepoint — the
  `_networkDecision()` check inside `CacheDownloadRepository`. Both manual
  downloads and pre-cache pass through it: Wi-Fi is always allowed, mobile data
  only with the explicit opt-in (`features/settings/network/`), offline never.
  Default is Wi-Fi only.
- **Half-written files.** A download fetches its bytes fully, then *commits*
  under a serialized lock so concurrent downloads can't jointly overshoot the
  cache limit. If you remove or clear the track while its bytes are still in
  flight, a cancellation guard makes the commit a no-op — no file, no metadata,
  no status — so a partial fetch can never masquerade as a finished download.
  The cache file name is derived from the **non-secret track id** (sanitized so
  an odd id can't escape the directory), never from a token or URL.

Deeper dive (including the eviction policy): [offline-cache.md](offline-cache.md).

## Library

The library is the browsing half of the app, in `lib/features/library/`. It
reads the local catalog through `MusicLibraryRepository`
(`library_controller.dart` watches it) and never touches a source directly.

- **Search** is client-side and instant: pure functions in
  `library_search.dart` filter the in-memory list as you type, normalizing case
  and accents so "Bjork" finds "Björk".
- **Albums & artists** aren't stored as separate rows — they're *derived* from
  the track list by `lib/core/catalog/library_grouping.dart`, which is the one
  place grouping and stable IDs live so the list, the detail screens, and the
  Android Auto browse tree never disagree.
- **Playlists** (`lib/features/playlists/`) are user-authored and have their own
  lifecycle (`PlaylistRepository`), separate from the source-derived catalog;
  they sync to Jellyfin where supported.
- **Favorites** (`lib/features/favorites/`) are a hybrid: local for on-device
  tracks, synced with Jellyfin as the source of truth for remote ones, toggled
  optimistically and token-free.
- **Smart mixes** (`lib/features/smart_mixes/`) are automatic collections
  (recently added/played, most played, favorites, downloaded, random, never
  played) computed on-device by the pure `SmartPlaylistResolver`
  (`core/services/smart_playlist_resolver.dart`) from signals that stay on the
  device.

Reusable list rows (`widgets/track_tile.dart`, `album_tile.dart`,
`artist_tile.dart`, `alphabet_track_list.dart`) keep these screens consistent.
More: [library.md](library.md), [playlists-and-delete.md](playlists-and-delete.md),
[smart-mixes.md](smart-mixes.md).

## Diagnostics & "Report a bug"

The friendliest way to report a bug is built into the app — **Settings → Report
a bug** — and the whole point is that it's **secret-free by construction.**

- `lib/features/settings/bug_report/` is the screen and form; it composes a
  Markdown report from a diagnostics snapshot plus a short event log, which you
  review and then copy or open as a prefilled GitHub issue. Nothing is ever
  auto-sent.
- `lib/core/diagnostics/app_diagnostics.dart` builds the snapshot. The data
  object can *only* hold report-safe values by design: server addresses are
  reduced to host (`hostOnly`), filesystem paths to `…/basename`
  (`redactPath`), and track ids are hashed, never raw.
- `lib/core/diagnostics/safe_event_log.dart` is a small ring buffer of recent
  events. Each event is a fixed *category* plus a *structural* detail
  (`lifecycle`, `bg-playback`, `output`, `precache`, `error`-by-kind) — there's
  no free-text field for a secret to slip into. `StabilityDiagnostics`
  (`core/services/`) is what writes to it.

**Never included:** tokens, passwords, authenticated/stream URLs, full server
URLs, raw track ids, track titles, or local file paths. If you add a diagnostic,
keep it on that side of the line. Details: [reporting-bugs.md](reporting-bugs.md).

## Settings

`lib/features/settings/settings_screen.dart` is just a host: it stacks one
section widget per concern, each in its own folder beside it — `jellyfin/`,
`subsonic/`, `cache/`, `network/`, `precache/`, `playback/`, `bug_report/`,
`diagnostics/`. Each section follows the same small pattern: a widget for the
UI and a controller that reads/writes persistence. The repetition is
intentional — each controller is a handful of trivial lines, and a generic
abstraction would hide more than it saved.

Persistence comes in **two tiers**, and the split is a security boundary:

- **Plain preferences** (non-secret scalars: "allow mobile data", cache size,
  "normalize volume", pre-cache count) go in shared preferences —
  `lib/data/repositories/shared_preferences_*.dart`.
- **Secrets** (your Jellyfin / Subsonic session token) go in
  `flutter_secure_storage`, encrypted at rest —
  `secure_jellyfin_session_store.dart`, `secure_subsonic_session_store.dart`.
  The settings *state* objects deliberately hold no token: only the URL,
  username, and server name needed to render the screen.

## What must never leak

A single rule runs through playback, Cast, providers, downloads, and
diagnostics — it's worth stating in one place:

- **The password is used once, then discarded.** Sign-in trades it for a
  session token; the password is never stored.
- **Tokens are encrypted at rest** (`flutter_secure_storage`), never written to
  shared preferences, logs, or diagnostics, and never shown on screen.
- **Authenticated stream URLs are minted on demand** and never persisted — not
  to disk, not to the cache (file names come from the non-secret track id), not
  to logs, not to a bug report.
- **Logs and the event log are secret-free by design.** They carry categories
  and counts, not ids, URLs, or credentials. Keep them that way.

If your change touches auth, streaming, Cast, or diagnostics, say so in the PR
description so reviewers can check this quickly. The same rules are summarized
for contributors in [CONTRIBUTING.md](../CONTRIBUTING.md#privacy--security).

## Where to go next

- [architecture.md](architecture.md) — the layering, the golden rule, and the
  extension points (this is the natural next read).
- [development.md](development.md) — setup in two commands, the verify script,
  and how CI runs.
- The per-feature docs linked throughout, and the table in the
  [README](../README.md#documentation).

Found something here that's out of date? Fixing it is a genuinely useful first
contribution — this map only stays helpful if it tracks the code.
