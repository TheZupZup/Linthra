# Jellyfin compatibility

This document describes how Linthra talks to a [Jellyfin](https://jellyfin.org)
server: which use cases are supported, the exact REST endpoints it relies on,
how it stays robust across Jellyfin updates, and how to troubleshoot and report
streaming problems **without leaking secrets**.

It is meant to be stable reference material. The behavior here is enforced by
the Jellyfin source under `lib/core/sources/jellyfin/` and its tests under
`test/core/sources/jellyfin/`; if you change an endpoint or error mapping, update
this file in the same change.

## Supported use cases

Linthra connects to a single self-hosted Jellyfin **music** server and supports:

- **Test connection** — confirm an address is reachable and really is Jellyfin
  (reads the public server info; no credentials needed), and read its
  name/version/product.
- **Sign in** — username + password are exchanged once for an access token; the
  password is never stored.
- **Library sync** — pull artists, albums, and tracks into the local catalog.
- **Direct streaming** — play a synced track straight from the server (no
  download required).
- **Offline downloads** — cache a track's original file on device; playback then
  prefers the local copy.
- **Favourites** and **lyrics** — read/toggle server-side favourites and fetch
  time-synced or plain lyrics.

It targets servers reached over **HTTPS**, including those published through a
**Cloudflare** domain or **Cloudflare Tunnel** (see below). Plain `http://` on a
trusted LAN is also accepted.

### Server version support

Linthra is actively tested against the **Jellyfin 10.10.x and 10.11.x** line and
treats **Jellyfin 12** — the next release after 10.11, as there is no 11 — as
*forward-tolerant*: allowed, never blocked, and never version-branched. The
reported version is parsed only for a **diagnostic** classification — it never
changes which endpoints or parameters Linthra sends. Deliberately avoiding
version-sniffing keeps the integration robust against future server updates.

`jellyfinServerSupportFor` classifies the reported version into four bands, each
surfaced in the settings note and the diagnostics report:

| Band | When | What the user sees |
| --- | --- | --- |
| **supported** | major ≤ `kMaximumTestedJellyfinMajor` (10) **and** ≥ `kMinimumTestedJellyfinVersion` (10.8.0) | nothing — the normal case |
| **newer than tested** | major **above** the tested ceiling (Jellyfin 12+) | a calm "newer major version Linthra hasn't validated — streaming should still work; please report any issues" |
| **untested (older)** | below the 10.8.0 floor | "older than Linthra is tested against — should still work, but untested" |
| **unknown** | version absent or unparseable | nothing actionable; still recorded in diagnostics |

Both bounds are conservative *diagnostic* markers, never gates: a server outside
the tested range is gently flagged, not refused. The version parser tolerates the
usual shapes — `10.11.11`, `12.0`, `12.0.0`, `12.0.0-rc1`, a 4th segment, a
`+build` suffix — and falls back to *unknown* (not a crash) for anything it can't
read. Raise `kMaximumTestedJellyfinMajor` (or the floor) only once a newer
baseline has actually been tested.

## Expected server URL examples

The address is normalized by `JellyfinServerUrl.normalize`:

| You type | Linthra uses | Why |
| --- | --- | --- |
| `music.example.com` | `https://music.example.com` | A bare host defaults to **HTTPS** (the Cloudflare-proxied default). |
| `https://music.example.com` | `https://music.example.com` | Used as-is. |
| `http://192.168.1.10:8096` | `http://192.168.1.10:8096` | Explicit scheme + port kept (LAN). |
| `https://example.com/jellyfin` | `https://example.com/jellyfin` | A reverse-proxy **subpath** is preserved. |
| `https://example.com/jellyfin/` | `https://example.com/jellyfin` | A trailing slash is trimmed. |
| `https://example.com/path?a=1#x` | `https://example.com/path` | Query/fragment are dropped. |

## Cloudflare notes

A Cloudflare-proxied server or a **Cloudflare Tunnel** (`cloudflared`) is just a
normal HTTPS endpoint, so it works with no special configuration — point the URL
at your public hostname. Two things to know:

- If the domain returns a Cloudflare **error page** (HTML, or a 5xx like
  521/522) or a challenge, Linthra reports a friendly *"doesn't look like a
  Jellyfin server"* / *"couldn't reach the server"* / *"returned a web page
  instead of audio"* message instead of a raw failure. This usually means the
  tunnel is down or the hostname isn't pointed at Jellyfin.
- **Cloudflare Access / Zero Trust** (an extra auth layer placed *in front of*
  Jellyfin) is **not supported**. Linthra speaks only Jellyfin's own auth, so a
  Zero Trust challenge page is returned where audio/JSON is expected. Use a
  hostname that reaches Jellyfin directly.

Streaming auth deliberately rides in the URL's `api_key` **query parameter**
(not an `Authorization` header) because that is what the Android audio engine
(`just_audio`/ExoPlayer) fetches with, and query auth survives the redirects a
stripped header would not.

## Endpoints Linthra relies on

Every Jellyfin URL is built in **one place** — `JellyfinEndpoints`
(`lib/core/sources/jellyfin/jellyfin_endpoints.dart`) — so paths never drift
between call sites and the full surface is auditable here.

| Purpose | Method & path | Notes |
| --- | --- | --- |
| Server info | `GET /System/Info/Public` | No auth. Backs Test connection + version/capability read. |
| Sign in | `POST /Users/AuthenticateByName` | Body `{Username, Pw}`; returns the access token. |
| Verify session | `GET /Users/Me` | Tiny authenticated check before streaming (401 ⇒ expired). |
| List tracks | `GET /Items?IncludeItemTypes=Audio&Recursive=true&…` | Sorted; `Fields=RunTimeTicks`. Paged via `StartIndex`/`Limit`. |
| List albums | `GET /Items?IncludeItemTypes=MusicAlbum&Recursive=true&…` | `Fields=ProductionYear,ChildCount`. Paged. Best-effort (a failure doesn't sink the track sync). |
| List artists | `GET /Artists?…` | Dedicated artists endpoint. Paged. Best-effort. |
| Favourite ids | `GET /Items?Filters=IsFavorite&IncludeItemTypes=Audio&…` | `EnableImages=false`. |
| Toggle favourite | `POST` / `DELETE /Users/{userId}/FavoriteItems/{itemId}` | POST marks, DELETE clears. |
| Lyrics | `GET /Audio/{itemId}/Lyrics` | 404 = "no lyrics", a normal outcome. |
| Cover art | `GET /Items/{itemId}/Images/Primary` | **Token-free**; safe to cache/persist. |
| Direct stream | `GET /Audio/{itemId}/stream?static=true&ApiKey=…&UserId=…&DeviceId=…` | `static=true` serves the original file (no transcode). Token in the `ApiKey` query (see Authentication). |
| Download | `GET /Items/{itemId}/Download?ApiKey=…` | Original file for the offline cache. Token in the `ApiKey` query. |
| Report playback start | `POST /Sessions/Playing` | Body `{ItemId, PositionTicks, …}`; shows Linthra on the dashboard. Best-effort. |
| Report playback progress | `POST /Sessions/Playing/Progress` | Throttled heartbeat; `IsPaused` carries pause/resume. Best-effort. |
| Report playback stop | `POST /Sessions/Playing/Stopped` | Settles the server's session/play state. Best-effort. |

**Authentication.** Authenticated JSON calls send the standard Jellyfin
`Authorization: MediaBrowser Client="Linthra", Device="Linthra", DeviceId="…",
Version="…", Token="…"` header — the modern, non-legacy scheme — built once in
`JellyfinAuthHeader`. Media URLs the audio engine fetches directly (the stream,
download, and control-socket URLs) can't carry a header, so they carry the token
in the **`ApiKey`** query parameter instead.

Why `ApiKey` (PascalCase), not the older `api_key`? Jellyfin 12 disables *legacy*
authorization by default (the server's `EnableLegacyAuthorization` switch), which
gates the lowercase `api_key` query parameter and the `X-Emby-*` headers. The
PascalCase `ApiKey` is Jellyfin's canonical, non-legacy query key, read
*unconditionally* on both the 10.x line and Jellyfin 12 — so using it everywhere
keeps media URLs authenticated on a stock Jellyfin 12 server while staying fully
backward compatible with 10.8+. (A media URL sent with the legacy `api_key` would
arrive unauthenticated — a 401 — on a default-config Jellyfin 12.)

The token is woven into a header or the `ApiKey` query only at request time and
is **never** stored on a track, written to the catalog, logged, shown in the UI,
or placed in an error.

### How streaming responses are classified

Before a stream URL reaches the audio engine, Linthra probes it (a one-byte
ranged GET, following redirects) and maps the result to a precise, secret-free
error:

| Observation | Error kind | User sees |
| --- | --- | --- |
| 2xx + audio/octet-stream/no type | *(plays)* | — |
| HTML body (Cloudflare/login/error page) | `webPage` | "returned a web page instead of audio" |
| 401 / 403 | `unauthorized` | "session expired — sign in again" |
| 404 | `streamUnavailable` | "this track isn't available right now" |
| 5xx | `serverError` | "server reported an error" |
| other non-2xx (400/429/…) | `unsupportedResponse` | "response Linthra couldn't use" |
| 2xx but non-audio content type | `notAudioStream` | "didn't return an audio stream" |
| transport failure (DNS/TLS/timeout) | `notReachable` | "couldn't reach the server" |

## Compatibility notes for future Jellyfin updates

- **Endpoints are centralized.** If a future server version relocates a path,
  change it in `JellyfinEndpoints` (and this table) — nowhere else.
- **No version-gated request behavior.** The version is read for diagnostics
  only. Do not add `if (version >= x) useEndpointA else useEndpointB` branches;
  prefer endpoints stable across the 10.x line.
- **Tolerant parsing.** Unknown JSON fields are ignored and a missing **or
  `null`** `Items` array reads as empty. Every mapped field is read through a
  *coercing* helper, so an item that omits a field — or sends it with the
  **wrong type** (a number where a string is expected, a numeric string for
  `RunTimeTicks`, a restructured `ImageTags`, …) — yields a safe fallback for
  that one field instead of throwing. The same coercions now cover **every** wire
  DTO — server info, the auth result, and playlists/entries — not just library
  items, so a retyped `Version`, token, or playlist id fails *cleanly* (a clear
  "not a Jellyfin server" / sign-in error, or a skipped entry) rather than
  crashing with a `TypeError`. An entry too malformed to use at all (missing
  `Id`/`Name`, or not an object) is **skipped and counted**, never thrown, so one
  bad track can't fail the whole sync; the sync then reports "some items could
  not be synced" rather than an error.
- **Paginated, bounded reads.** Library listings are pulled in bounded pages
  (`StartIndex`/`Limit`) with a brief yield between them, so a large/slow
  library can't time out one unbounded request or hammer the server, and
  playback/UI stay responsive during a sync. A transient page failure (timeout,
  dropped connection, 5xx/408/429) is retried a **bounded** number of times with
  exponential backoff; auth (401/403) and other client errors are never retried.
  A page that ultimately fails aborts the sync (the previous catalog is kept)
  rather than committing a truncated library.
- **`static=true` direct play** is the safest streaming path: it serves the
  original bytes the engine can open, avoiding transcode/HLS negotiation that
  varies between server versions and codecs.
- **Bump the tested floor** (`kMinimumTestedJellyfinVersion`) only when you have
  actually tested against, and intend to require, a newer baseline.

### Stable API contract assumptions

Because Linthra never version-branches, it instead relies on a small set of
long-standing API contracts. They hold across the 10.x line and Jellyfin 12; if a
verified future Jellyfin release changes one, this is the list to check, and the
fix is centralized (usually one line in `JellyfinEndpoints`):

- **Auth rejection is `401`/`403`.** Only these statuses mean "token rejected"
  (and only from an auth-verifying call — `/Users/Me` or `AuthenticateByName`).
  A changed status would mis-message but **cannot** force a sign-out or wipe the
  catalog: sign-out is user-initiated only, and a failed/empty sync always keeps
  the existing library.
- **Token query auth is `ApiKey`.** The non-legacy, always-read query key (see
  Authentication). The legacy lowercase `api_key` is off by default on Jellyfin
  12.
- **Paging is `StartIndex`/`Limit`**, and a listing is `{ "Items": [...],
  "TotalRecordCount": n }`. A missing/`null` `Items` reads as empty; a
  missing/non-numeric `TotalRecordCount` falls back to short-page/empty-page
  termination (with a page-count backstop), so the worst case of a paging change
  is bounded truncation — never an infinite loop or a wipe.
- **Stable paths:** `/System/Info/Public`, `/Users/AuthenticateByName`,
  `/Users/Me`, `/Items`, `/Artists`, `/Playlists/{id}/Items`, the `/Sessions/*`
  reporting/capabilities endpoints, and the `/socket` control WebSocket.
- **Favourites use the per-user path form** `…/Users/{userId}/FavoriteItems/
  {itemId}`. Jellyfin has deprecated path-embedded user ids in favour of
  query-param forms but still honours this through Jellyfin 12. It is best-effort
  (a failure never wipes the catalog or signs the user out); if a future release
  removes it, treat a `404` on toggle as "favourites unsupported" rather than
  adding a version branch. Library and favourite *listing* already use the modern
  `/Items?UserId=…` query form.

## Safe troubleshooting steps

1. **Test connection first.** It checks reachability and that the address is
   really Jellyfin, and shows the server name/version.
2. **"Doesn't look like a Jellyfin server"** → the hostname likely reaches
   Cloudflare/another service, not Jellyfin (or Zero Trust is in front of it).
3. **"Couldn't reach the server"** → server offline, tunnel down, wrong
   address, or no connectivity.
4. **"Session expired"** → sign out and back in to mint a fresh token.
5. **"Returned a web page instead of audio"** → a Cloudflare challenge/error
   page; confirm the tunnel is healthy and Zero Trust isn't gating the host.
6. **"This track isn't available"** (404) → the item may have been moved/removed
   or lives in a library your user can't see; re-sync the library.
7. **Untested-version note** (older server) → streaming usually still works;
   upgrade the server if you hit issues.
8. **"Newer than tested" note** (Jellyfin 12+) → Linthra hasn't validated this
   major version yet; streaming should still work — please report any issues so
   the tested ceiling can be raised.

## Reporting a Jellyfin issue without leaking secrets

Use **Settings → Jellyfin → Copy Jellyfin diagnostics**. It puts a short,
**secret-free** report on the clipboard, for example:

```
Linthra Jellyfin diagnostics
App version: 0.1.0-alpha.9
Connection: connected
Server name: Home
Server version: 10.9.11
Version support: supported
Server host: music.example.com
Last error: none
```

What it includes: app version, connection state, server name/version/product,
the version-support classification (`supported` / `newer than tested` /
`untested (older than recommended)` / `unknown` — enough to spot a Jellyfin 12
server at a glance), the **host only** (never a full URL), and the **kind** of
the last error.

What it never includes: your **password**, the **access token**, the
`Authorization` header, or any **full authenticated URL** (the address is
reduced to its host so a tokenized query can't ride along). Paste it into a bug
report as-is.
