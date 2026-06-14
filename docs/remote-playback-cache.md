# Remote playback cache & prebuffer foundation

Remote playback can cut out when the network or the server response is unstable:
a skip, or the natural roll into the next track, otherwise pays the full
"verify the session → mint the stream URL → open the stream" round trip *at the
moment the track changes*. This document describes the provider-neutral
foundation Linthra uses to prepare remote playback **earlier and more
aggressively** — without persisting secrets and without changing how local music
or any existing provider behaves.

It is the seam the future on-disk offline/cache system hangs off. This phase
ships the in-memory prebuffer, the credential-free key/metadata model, and a
durable, credential-free **on-disk index** of what has been prepared (so the
cache's knowledge survives a restart) — but still no user-facing cache UI and no
downloads: the audio *bytes* remain the offline download cache's job.

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
| `RemoteStreamPrebufferer` | The **write side**: pre-resolves the current + next remote URLs through the source router, stores them, and (optionally) records each warm's credential-free key in the durable index. Best-effort; never throws. |
| `RemoteCacheResolver` | The **read side**: a `PlayableUriResolver` that serves a fresh warmed URL once, else delegates to the router. |
| `RemotePrebufferService` | Drives the prebufferer from the live `PlaybackState` (current + next, calm under repeat-one, off the playback path). |
| `RemoteCacheRecord` | The **persistable, credential-free projection** of an entry: its key + timestamps, with the token-bearing stream URL cut away. There is no field that could hold a URL or token. |
| `RemoteCacheStore` | The persistence seam — `load` / `save` a list of records. The app impl is `FileRemoteCacheStore` (a JSON manifest under `remote_cache/`); tests use an in-memory fake. |
| `RemoteCacheIndex` | The durable index orchestrator: loads once, records each warm's credential-free key, sweeps expired records, and clears — every step best-effort and off the playback path. |

### Wiring

In `lib/features/player/player_providers.dart` the read side
(`remoteCacheResolverProvider`) and the write side
(`remoteStreamPrebuffererProvider`) share one session-pinned
`remotePlaybackCacheProvider` and one `remoteSourceRouterProvider` (Jellyfin →
Subsonic → Plex → on-device catch-all). The controller resolves through the
offline-first resolver, which falls through to the remote cache resolver on a
download miss. `RemotePrebufferService` is started once from `main`, which also
kicks a best-effort `remoteCacheIndexProvider.load()` to warm and prune the
durable index off the first-frame path.

## On-disk index (durable, credential-free)

The in-memory cache forgets everything when the process ends — and holds the
token-bearing URL only for its short TTL. The on-disk **index** is its durable
complement: as the prebufferer warms a remote track it records that track's
*credential-free* identity through a `RemoteCacheStore`, so the cache's
*knowledge* survives a restart even though the (expiring, tokenized) URL
deliberately does not.

What is persisted is only a `RemoteCacheRecord` — the opaque key
(`jellyfin:<id>` / `subsonic:<id>` / `plex:<ratingKey>`) plus two timestamps. The
type has **no field** for a stream URL, an artwork URL, or a token, so the JSON
manifest (`<app-support>/remote_cache/index.json`) physically cannot carry one.
On the way back in, `RemoteCacheRecord.fromJson` re-validates every key through
`RemoteCacheKey.forUri` and drops anything local, `content://`, or even
*looks* tokenized — so a corrupt or hand-edited manifest can't reintroduce a
secret either.

Because no URL is stored, a restart can never replay a stale stream: the index
remembers *that* a track was prepared (and the credential-free name its future
on-disk bytes will use), and the resolver still mints a **fresh** URL on the next
play. The index is the seam the future on-disk byte cache and its eviction sweep
hang off — `RemoteCacheIndex.sweep` already drops records past a generous
retention window, and `clear` empties both the index and the manifest.

Everything here is **best-effort and non-fatal**, exactly like the prebufferer it
rides behind: the load runs once and lazily, every store call is wrapped, and a
slow or failing disk degrades to a cold index rather than throwing into the
playback path. `RemoteStreamPrebufferer` takes the index as an *optional*
collaborator, so the write side is byte-for-byte unchanged when none is wired.

### Disconnect / sign-out cleanup

When a user disconnects a provider, its prepared-track records should not linger.
Each provider's disconnect/sign-out flow (`PlexSettingsController.disconnect`,
`JellyfinSettingsController.clear`, `SubsonicSettingsController.clear`) calls
`RemoteCacheIndex.removeSource(sourceId)`, which drops only that provider's
records — `jellyfin` / `subsonic` / `plex`, keyed off `RemoteCacheKey.sourceId` —
and persists the rest, so signing out of one server never discards another's
records. The call is **best-effort** and runs *after* the settings UI has already
returned to its signed-out state, so this credential-free cleanup can never throw
into, or delay, the disconnect (the whole-index `clear` remains for a future
"forget everything"). Records are credential-free either way, so this is privacy
hygiene — no token is ever at stake.

## Security rules (non-negotiable)

A remote stream URL carries its credential in the URL itself (Jellyfin/Subsonic
in the query, Plex's `X-Plex-Token`). The whole foundation is built so that
credential **never** lands anywhere durable:

- **Never persist a tokenized stream or artwork URL.** The token-bearing URL
  lives solely inside a `RemoteCacheEntry.streamUri` for the life of the process;
  the in-memory cache serializes nothing, and the durable on-disk index persists
  only a `RemoteCacheRecord` (the opaque key + timestamps), which has no field a
  URL or token could ever occupy.
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

These are enforced by tests in `test/core/services/remote_cache/` and
`test/data/repositories/file_remote_cache_store_test.dart` (see the "credential
safety" groups, the tokenized-URL-refusal cases, the local/`content://`-are-
never-cached cases, and the assertion that the written manifest file itself
carries no token, URL, or `api_key`).

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
