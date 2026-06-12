# Remote playback cache & prebuffer foundation

Remote playback can cut out when the network or the server response is unstable:
a skip, or the natural roll into the next track, otherwise pays the full
"verify the session → mint the stream URL → open the stream" round trip *at the
moment the track changes*. This document describes the provider-neutral
foundation Linthra uses to prepare remote playback **earlier and more
aggressively** — without persisting secrets and without changing how local music
or any existing provider behaves.

It is the seam the future on-disk offline/cache system will hang off; this phase
ships the in-memory prebuffer and the credential-free key/metadata model, not a
user-facing cache UI or downloads.

## What it does

As playback advances, the app warms the **current** remote track and the
**next** queue item's stream URL into a short-lived, in-memory cache, so the
next play is served from a pre-resolved URL instead of re-running the
session-check + mint. If a warmed URL has expired, the cache resolves a fresh one
rather than replaying a stale one.

It is deliberately **not** the offline cache: it never writes bytes to disk,
never marks a track as downloaded, and never blocks the current track. (Warming
upcoming tracks *to disk* remains `SmartPrecacheService`'s job; the two are
complementary.)

## The pieces

All live under `lib/core/services/remote_cache/` and are provider-neutral — they
know nothing about Jellyfin, Plex, or Subsonic beyond a track's URI scheme.

| Class | Role |
| --- | --- |
| `RemoteCacheKey` | Derives a **credential-free** identity from a `Track` (its opaque `uri`). The security boundary: decides what may be keyed, and refuses local/`content://`/tokenized inputs. |
| `RemoteCacheEntry` | One prebuffered resolution: the credential-free key + metadata, plus the token-bearing stream URL held **in memory only**. |
| `RemoteCachePolicy` | The pure rules — what may be prebuffered, what may be stored (only a direct stream), the TTL, and whether an entry may be reused. |
| `RemotePlaybackCache` | The in-memory store. `store` / `peek` / `consume` (consume-on-read) / `sweep` / `clear`. Persists nothing. |
| `RemoteCacheCleanup` | The pure cleanup rule: which entries are expired and should be dropped. |
| `RemoteStreamPrebufferer` | The **write side**: pre-resolves the current + next remote URLs through the source router and stores them. Best-effort; never throws. |
| `RemoteCacheResolver` | The **read side**: a `PlayableUriResolver` that serves a fresh warmed URL once, else delegates to the router. |
| `RemotePrebufferService` | Drives the prebufferer from the live `PlaybackState` (current + next, calm under repeat-one, off the playback path). |

### Wiring

In `lib/features/player/player_providers.dart` the read side
(`remoteCacheResolverProvider`) and the write side
(`remoteStreamPrebuffererProvider`) share one session-pinned
`remotePlaybackCacheProvider` and one `remoteSourceRouterProvider` (Jellyfin →
Subsonic → Plex → on-device catch-all). The controller resolves through the
offline-first resolver, which falls through to the remote cache resolver on a
download miss. `RemotePrebufferService` is started once from `main`.

## Security rules (non-negotiable)

A remote stream URL carries its credential in the URL itself (Jellyfin/Subsonic
in the query, Plex's `X-Plex-Token`). The whole foundation is built so that
credential **never** lands anywhere durable:

- **Never persist a tokenized stream or artwork URL.** The cache is in-memory
  only and serializes nothing. The token-bearing URL lives solely inside a
  `RemoteCacheEntry.streamUri` for the life of the process.
- **Cache keys, filenames, and metadata are credential-free.** `RemoteCacheKey`
  is built only from the track's opaque `uri` (`jellyfin:<id>`, `subsonic:<id>`,
  `plex:<ratingKey>`). `fileSafeName` (for the future on-disk cache) sanitizes
  that already-secret-free value; it can never contain a token. `RemoteCacheKey`
  also refuses to key any input that *looks* tokenized (a query string or a known
  secret marker) as defence in depth.
- **No tokens in logs, diagnostics, or errors.** `RemoteCacheEntry.diagnosticLabel`
  exposes the key + source only and omits the stream URL. The prebufferer
  swallows resolution errors and never logs the URL it resolved.
- **Plex identities stay stable and safe.** `Track.uri` remains `plex:<ratingKey>`
  and `artworkUri` remains `plex-thumb:<path>`; the token is woven into the
  stream URL on demand, never onto the track or into the cache key.

These are enforced by tests in `test/core/services/remote_cache/` (see the
"credential safety" groups, the tokenized-URL-refusal cases, and the
local/`content://`-are-never-cached cases).

## Failure behaviour

Prebuffering is **best-effort and non-fatal**. Every warm is wrapped: a failure
is swallowed and the track simply resolves normally when it is reached. A slow
warm runs off the playback path (one pass at a time) and never stalls or
restarts the current track. Playback can never fail *because* prebuffering
failed.

## Out of scope (this phase)

No on-disk offline download UI, no user-facing cache settings, no lyrics,
playlists/favorites, Plex.tv OAuth, Android Auto-specific work, version bump, or
release changes. This foundation only reduces remote playback cuts and prepares
the future offline/cache system.
