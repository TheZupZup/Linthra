# Plex (self-hosted music) — design

> **Status: design only.** This page captures the agreed design for a
> **read-only Plex music provider** so a contributor can build it in small,
> reviewable PRs. **No Plex code ships with this document.** It is the first PR
> in the sequence described in [issue #178](https://github.com/TheZupZup/Linthra/issues/178)
> and the [Suggested PR steps](#suggested-pr-steps) below; it does **not** touch
> Jellyfin, Navidrome/Subsonic, or Local music, and it does **not** register a
> provider, change playback, or bump the version.

[Plex Media Server](https://www.plex.tv/) (PMS) is a self-hosted media server
many people already run for their own music. A Plex `MusicSource` lets those
users play their library in Linthra the same way Jellyfin and Navidrome/Subsonic
users already can. Plex Media Server is the user's **own** server, not a closed
streaming service, so it fits Linthra's "music you own or host yourself" stance
(see [providers.md → Non-goals](providers.md)).

This design slots **behind the existing `MusicSource` seam**
(`lib/core/services/music_source.dart`) and the capability model
(`lib/core/sources/music_provider.dart`) described in
[architecture.md](architecture.md) and [providers.md](providers.md), without
changing any existing provider path.

## Scope — phase 1 (read-only)

Phase 1 is a **read-only** Plex provider, mirroring how Subsonic shipped
streaming first and deferred the rest:

- Connect to a Plex Media Server.
- **Token-based authentication**, starting with a **manual server URL + manual
  token** (the plex.tv PIN/OAuth flow is a documented follow-up).
- Discover and let the user **select** which music libraries (sections) to use.
- List artists, albums, and tracks.
- **Stream** tracks — **direct play only** (no server-side transcoding).
- Load cover art.
- **No writes to the server.**

### Out of scope for phase 1

Declared **unsupported** in the capability model so their actions stay
hidden/disabled rather than failing — exactly how Subsonic deferred
favorites/etc:

- Offline downloads / caching.
- Cache management.
- Lyrics.
- Playlist sync.
- Favorites sync.
- Android Auto-specific artwork changes.
- Server-side transcoding.
- Any change to existing providers (Jellyfin, Subsonic/Navidrome, Local).

## Plex API endpoints (music libraries)

PMS exposes an HTTP API. Default responses are **XML**; pass
`Accept: application/json` to get JSON (the first big difference from
Jellyfin/Subsonic, which are JSON-native — see [Risks](#risks-vs-jellyfin-and-navidrome)).
Plex uses three numeric metadata types for music: **8 = artist, 9 = album,
10 = track**. Every item carries a stable per-server **`ratingKey`**.

All endpoints are relative to the chosen server base URL.

| Purpose | Endpoint | Notes |
| --- | --- | --- |
| Server identity / reachability | `GET /identity` (or `/`) | `machineIdentifier`, version. Mirrors Jellyfin `/System/Info/Public` and Subsonic `ping`. |
| List libraries (sections) | `GET /library/sections` | `Directory` entries; keep those with `type == "artist"` (music). Each has `key`, `title`, `uuid`. |
| Artists | `GET /library/sections/{key}/all?type=8` | |
| Albums | `GET /library/sections/{key}/all?type=9` | Album carries `parentRatingKey` → artist. |
| Tracks | `GET /library/sections/{key}/all?type=10` | Track carries `grandparentRatingKey` → artist, `parentRatingKey` → album. |
| Drill-down (alternative to flat lists) | `GET /library/metadata/{ratingKey}/children` | An artist's albums or an album's tracks. |
| Single item (needed at play time) | `GET /library/metadata/{ratingKey}` | `Media[].Part[].key` is the actual stream path. |
| Stream (direct play) | `GET {server}{Part.key}?X-Plex-Token=…` | e.g. `/library/parts/12345/…/file.flac`. The Part `key` is **not** the `ratingKey`. |
| Cover art | `GET {server}{thumb}?X-Plex-Token=…` | Items carry a `thumb` path, e.g. `/library/metadata/123/thumb/…`. |

- **Pagination:** large libraries page via `X-Plex-Container-Start` /
  `X-Plex-Container-Size` (header or query); `MediaContainer.totalSize` reports
  the total. Reuse the paged-walk shape Subsonic already uses for album lists.
- **Direct play only:** the transcoder (`/music/:/transcode/universal`) is
  explicitly out of scope for phase 1. A sizing photo transcoder
  (`/photo/:/transcode?url=…&width=…&height=…`) exists for art but is optional.
- **Two-step play resolution:** because the Part `key` differs from the
  `ratingKey`, a track's playable URL needs a `GET /library/metadata/{ratingKey}`
  lookup at play time (see [MusicSource mapping](#musicsource-mapping)).

## Authentication

Plex auth centers on the **`X-Plex-Token`**, sent either as the `X-Plex-Token`
header (API calls) or a query param (unavoidable for stream/art URLs handed to
the audio/image layers). Every request also needs client-identity headers:
`X-Plex-Client-Identifier` (a stable per-install UUID), `X-Plex-Product`,
`X-Plex-Version`, `X-Plex-Platform`, `X-Plex-Device`. This is analogous to
Jellyfin's device id + `Authorization` client header.

### Two ways to obtain a token

- **Manual token + server URL — phase 1 first cut (recommended).** The user
  pastes their `X-Plex-Token` and server URL; Linthra verifies it against
  `/identity`. Closest to the existing Jellyfin/Subsonic "URL + credential,
  verify against the server" flow, with no browser handoff.
- **PIN / OAuth via plex.tv — later (nicer UX, more moving parts).**
  `POST https://plex.tv/api/v2/pins?strong=true` → `{id, code}`; the user opens
  `https://app.plex.tv/auth#?clientID=…&code=…`; Linthra polls
  `GET https://plex.tv/api/v2/pins/{id}` until `authToken` is populated.
  Optionally `GET https://plex.tv/api/v2/resources?includeHttps=1` then returns
  the user's servers, **each with its own per-server `accessToken`** and
  connection URIs.

### Token scope (key safety decision)

Prefer the **per-server `accessToken`** from the resources endpoint over the
**account token**: the account token grants access to the whole Plex account,
not just one server — a far bigger blast radius if it ever leaks. The design
defaults to the **narrowest token that works**.

## Token safety rules

These follow the existing non-negotiables documented in
[providers.md](providers.md) and enforced for Jellyfin/Subsonic — Plex adds one
extra concern (the token rides in **query params** for stream/art URLs).

- **Store only the token** (prefer the server-scoped `accessToken`), encrypted
  via `flutter_secure_storage`, in a `secure_plex_session_store.dart` under a
  single versioned key (e.g. `plex_session_v1`), with an
  `InMemoryPlexSessionStore` for tests.
- **Never persist a password.** If the PIN flow is used later, only the
  resulting token is kept.
- **No token in `Track.uri` or `Track.artworkUri`** (or the DB). Keep the
  opaque, credential-free `plex:<ratingKey>` and `plex-thumb:<…>` references;
  mint credentialed URLs **only** at play/render time and discard them.
- **No token in logs, diagnostics, cache filenames, or errors.** Never log the
  token (header **or** query param), never surface it in a UI error, never put
  it in a cache filename. `PlexSession.toString()` must redact the token.
- **Guard URL logging centrally.** Because the token rides in stream/art
  **query params**, a single leaked URL log line exposes the whole token.
  Redact `X-Plex-Token=…` centrally in the HTTP layer.
- **Diagnostics are secret-free by construction** — reduce the server address to
  its **host only** and assert in tests that no token reaches any sink.

## MusicSource mapping

The `MusicSource` contract is small (`id`, `displayName`,
`fetchTracks/Albums/Artists`, `resolvePlayableUri`). Proposed mapping, mirroring
`JellyfinTrackMapper` / `SubsonicTrackMapper`:

- **`id`** → `plex`; **`displayName`** → `Plex · <server name>`.
- **URI scheme** → `plex:` (opaque, credential-free), registered in
  `MusicProviders.forTrackUri` (`lib/core/sources/music_provider.dart`) next to
  the existing `jellyfin:` / `subsonic:` prefixes. This is the **only** shared-
  code edit phase 1 makes (plus a new provider-matrix row in docs).
- **Type mapping** → Plex **8 → `Artist`**, **9 → `Album`**, **10 → `Track`**,
  using `parentRatingKey` / `grandparentRatingKey` to fill artist/album names,
  mirroring Jellyfin's mapper, with missing-field fallbacks.
- **Track URIs** → `plex:<ratingKey>`. The `ratingKey` is the stable per-server
  id; it is **not** the Part key, so it carries no credential and never names a
  file path.
- **Artwork references** → `plex-thumb:<…>` stored in `Track.artworkUri`
  (mirroring Subsonic's `subsonic-cover:`), with the token woven in only at
  render time.
- **`resolvePlayableUri`** → resolve at play time: `GET /library/metadata/{ratingKey}`
  → read `Media[0].Part[0].key` → build `{baseUrl}{partKey}?X-Plex-Token=…`.
  This keeps `Track.uri` opaque and mints the credentialed URL on demand, exactly
  like Jellyfin/Subsonic. (Design check: confirm the extra round trip is
  acceptable, or probe like `JellyfinStreamProbe`.)
- **Library selection** → unlike Jellyfin/Subsonic (which sync the whole
  server), Plex asks the user to pick which music sections to include. The
  selected section keys live in the Plex session and scope
  `fetchArtists/Albums/Tracks`.

### Capabilities (phase 1)

`MusicProviderCapabilities` for Plex declares **stream-only**:

| Capability | Phase 1 |
| --- | :---: |
| `canStream` | ✅ |
| `canCache` | ❌ |
| `canFavoriteTracks` / `canReadFavoriteState` / `canSyncFavorites` | ❌ |
| `canListPlaylists` / `canSyncPlaylists` (and create/edit/delete) | ❌ |
| `canLyrics` | ❌ |
| `canCast` | ❌ |

Cast is a natural later add (the stream URL is network-reachable) but stays off
in phase 1 to keep the credential-in-URL surface small.

## Playback reporting / Now Playing (shipped after phase 1)

Phase 1 above is read-only. The one deliberate exception added since:
**timeline reporting**, so a Plex Media Server shows Linthra as an active
player in its Now Playing dashboard while a `plex:` track plays. It is a
benign, ephemeral write (PMS updates its session list; nothing in the library
is modified) and is **best-effort by contract** — a failed report is silently
dropped and can never stall, stop, or alter playback.

### How Plex sees a player

A client reports its playback to `GET /:/timeline` (verified against
python-plexapi's `updateTimeline` and the community API docs):

| Param | Value |
| --- | --- |
| `ratingKey` | the playing item's id (from the opaque `plex:<ratingKey>` uri) |
| `key` | `/library/metadata/{ratingKey}` |
| `identifier` | `com.plexapp.plugins.library` (fixed protocol constant) |
| `state` | `playing` / `paused` / `stopped` (`buffering` exists; unused) |
| `time` | playback position, **milliseconds** |
| `duration` | item length, **milliseconds** — omitted when unknown |

The token rides in the `X-Plex-Token` **header** (like every API call), so a
timeline URL is token-free and safe to log. The `X-Plex-*` identity headers
name the player: `X-Plex-Product` / `X-Plex-Device` / `X-Plex-Device-Name`
are `Linthra`, and `X-Plex-Client-Identifier` is the stable per-install id
persisted with the session — PMS keys the session on it, so pause/resume
update one player entry instead of spawning new ones. `state=stopped` clears
the entry.

### Architecture (provider-neutral seam)

- **`ServerPlaybackReporter`** (`core/services/server_playback_reporter.dart`)
  — the neutral contract: `onPlaybackStarted/Progress/Paused/Resumed/Stopped`
  + `onTrackChanged`, with a `NoOpServerPlaybackReporter` for providers
  without reporting.
- **`RoutingServerPlaybackReporter`** — selects the reporter whose `handles`
  claims the track's uri; `plex:` routes to Plex, everything else reports
  nowhere, so local/Jellyfin/Subsonic playback can never trigger a Plex call.
  `onTrackChanged` is forwarded to the owners of *both* sides, so a Plex
  session closes even when the next track belongs to another provider.
- **`PlaybackReportingService`** (`core/services/playback_reporting_service.dart`)
  — listens to the unified `PlaybackState` stream and derives the lifecycle:
  first play → started, pause/resume → immediate, idle/completed/error →
  stopped, queue move → track change. Progress is **throttled** (one report
  per 10s of steady play) so position ticks never spam the server; reports
  dispatch strictly in order, off the playback path, with every failure
  swallowed. `loading`/`buffering` are not transitions (no pause/resume flap
  on a re-buffer; a track that never starts is never reported).
- **`PlexPlaybackReporter`** (`core/sources/plex/plex_playback_reporter.dart`)
  — every Plex-specific detail (state mapping, ratingKey extraction, ms
  units) stays here, behind the neutral interface. It reads the live session
  and client lazily — signed out means silent no-op — exactly like the
  playable-uri resolver.

### Token safety (same non-negotiables)

The timeline path adds **no** new token surface: the token goes only to the
`PlexClient` (header), never into the URL, a log, an error, or diagnostics;
the reporter never throws, so no failure can carry anything out; timeline
URLs are minted per report and discarded — nothing about reporting is ever
persisted. Tests prove the URL builder is token-free, the HTTP errors are
token-free, and the reporter swallows every failure kind.

## Risks vs Jellyfin and Navidrome

- **XML-first API.** PMS defaults to XML; we rely on `Accept: application/json`,
  and some endpoints/older servers may still return XML. → Decide JSON-only with
  a clear error, or tolerate XML.
- **Token blast radius.** A Plex **account** token is far more powerful than a
  Jellyfin access token or a Subsonic salt+token (both server-scoped). → Prefer
  the per-server `accessToken`.
- **Token in URL query params.** Stream/art URLs must carry the token as a query
  param (the image/audio layers can't easily set headers), a bigger leak surface
  than Jellyfin's `api_key` param or Subsonic's salt+token. → Centralize URL
  redaction.
- **Auth-flow complexity.** Plex's modern path is a plex.tv PIN/browser handoff,
  unlike a single username/password POST. → Phase 1 starts with manual token
  paste.
- **Two-step play resolution.** `ratingKey` ≠ Part `key`, so playback needs an
  extra metadata round trip. Jellyfin/Subsonic build the stream URL straight
  from the id.
- **Connectivity / `.plex.direct` TLS & relay.** Plex servers are often reached
  via plex.tv-discovered connections (relay, `*.plex.direct` certs) rather than
  a plain typed URL. → Phase 1: typed URL + token; document relay/discovery as a
  follow-up.
- **Direct-play codec fit.** Without the transcoder, a Part may be a codec the
  device can't decode. → Phase 1 is direct-play only; transcoding is a later
  capability.
- **Library selection (new UX).** Jellyfin/Subsonic sync the whole server; Plex
  needs a section-picker, a small new surface to design and test.

## Proposed file layout (for the eventual implementation)

```
lib/core/sources/plex/
  plex_api.dart            # DTOs (MediaContainer / Metadata / Part)
  plex_endpoints.dart      # pure URL builders
  plex_client.dart         # interface (HTTP behind this seam)
  http_plex_client.dart    # package:http impl, JSON via Accept header
  plex_authenticator.dart  # token verify (+ optional PIN flow)
  plex_track_mapper.dart   # type 8/9/10 -> Artist/Album/Track, plex: scheme
  plex_music_source.dart   # implements MusicSource (+ PlexStreamSource)
  plex_stream_source.dart  # narrow stream seam
lib/core/models/plex_session.dart
lib/core/repositories/plex_session_store.dart
lib/data/repositories/secure_plex_session_store.dart
lib/data/repositories/in_memory_plex_session_store.dart
lib/features/settings/plex/  # section + controller + state + providers
docs/plex.md
```

## Tests to add (mirrors the Jellyfin/Subsonic layout)

Tests use hand-written `Fake*` clients (no mocking library) and Riverpod
overrides.

- `plex_endpoints_test.dart` — pure URL builders (sections, items by type,
  metadata, part stream, thumb), incl. token placement and pagination params.
- `plex_track_mapper_test.dart` — type 8/9/10 → Artist/Album/Track,
  parent/grandparent wiring, `plex:` scheme, `plex-thumb:` artwork reference,
  missing-field fallbacks.
- `http_plex_client_test.dart` — JSON parsing via `Accept: application/json`,
  error → `PlexException` mapping, **token never in exception/log**, paging.
- `plex_authenticator_test.dart` — token-paste verify against `/identity`;
  (if PIN flow) pin create/poll; per-server vs account token selection.
- `fake_plex_client.dart` — reusable canned-response/error fake.
- `plex_music_source_test.dart` — fetch + `resolvePlayableUri` (part-key
  lookup), library-selection scoping.
- `plex_settings_controller_test.dart` — connect/select-libraries/sign-out,
  state holds **no** token, password/token cleared after use.
- Capability-matrix test — Plex declares stream-only in phase 1.
- A guard test that `MusicProviders.forTrackUri` still routes existing
  `jellyfin:` / `subsonic:` / local URIs unchanged (no regression).

## Suggested PR steps

Small, incremental, each independently reviewable:

1. **Design doc** — this `docs/plex.md` (endpoints, auth choice, token-scope
   rule, capability matrix). **No code wiring.** ← *this PR*
2. **DTOs + endpoints** — `plex_api.dart`, `plex_endpoints.dart`, fully
   unit-tested, no UI, no wiring.
3. **Client** — `plex_client.dart` + `http_plex_client.dart` +
   `fake_plex_client.dart` (identity, sections, items, metadata) + tests. No UI.
4. **Auth + session + secure store** — token-paste verify (PIN flow optional /
   behind a follow-up), `plex_session.dart`, secure + in-memory stores + tests.
5. **Mapper + source** — `plex_track_mapper.dart`,
   `plex_music_source.dart` / `plex_stream_source.dart`, register `plex:` in
   `MusicProviders` with a stream-only capability set + tests (incl. the
   no-regression routing guard).
6. **Library selection + settings UI** — section discovery/picker,
   `plex_settings_section/controller/state`, Riverpod providers + tests.
7. **Cover art** — `plex-thumb:` reference resolver at render time; update the
   [providers.md](providers.md) provider matrix to add the Plex row.
8. **Real-device hardening & phase-1 polish** — the catalog sync
   (`plex_sync_controller`: a *Sync Plex library* action plus an automatic,
   coalesced sync after every committed library-selection change; the sync
   **replaces** the catalog's Plex slice even when empty, so the catalog
   always mirrors the selection), explicit loading/empty/error + retry states
   in the library picker, selection pruning when a section vanishes
   server-side, same-server reconnects keeping the selection, startup-restore
   race guards and a friendly restore-failure message, and disconnect also
   removing the synced (now unplayable) Plex rows — with tests for each state
   and for token redaction on every new message path.
9. **Playback & artwork final polish** (the last phase-1 PR before
   real-device testing) — precise playback errors: a track whose metadata
   resolves but carries **no playable Part** says so (instead of a generic
   "couldn't stream"), a `plex:` uri with no ratingKey fails typed without a
   junk request, and a malformed Part key fails typed instead of escaping as
   an untyped error or splicing into the server URL. Artwork hardening:
   `plex-thumb:` references round-trip query-carrying (sizing-transcoder)
   thumb paths byte-for-byte — including a `url=` value PMS itself
   percent-encoded — the minted stream/art URLs **merge** the token into an
   existing query rather than replacing it, splicing the existing pairs
   through raw (and dropping any token-named param a stored path might
   smuggle, however encoded), and the render-time resolver never throws —
   a degenerate session, a non-absolute thumb path, or an unparseable
   reference all degrade to the row's placeholder. Tests sweep every failure
   kind for token/URL-free messages and re-prove the Jellyfin/Subsonic/local
   artwork chain is untouched.

## Notes

- This design must **not** change existing providers; the only edits to shared
  code (in later PRs) are the new `plex:` branch in `MusicProviders.forTrackUri`
  and a new row in the provider matrix/docs.
- Reuse, don't reinvent: `package:http`, `flutter_secure_storage`, `crypto`, the
  capability model, and the `Fake*`-client test style are all already in place.
- Credentials follow the same non-negotiables as every other provider: never
  logged, encrypted at rest, never woven into a persisted URI.
