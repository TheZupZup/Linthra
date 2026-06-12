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

Linthra is tested against **Jellyfin 10.8.0 and newer**. The REST endpoints it
uses (below) are long-standing across the 10.x line, so an older server is
labelled *untested* (and the user is gently warned) rather than blocked. The
reported version is parsed only for this **diagnostic** classification — it never
changes which endpoints or parameters Linthra sends. Deliberately avoiding
version-sniffing keeps the integration robust against future server updates.

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
| List tracks | `GET /Items?IncludeItemTypes=Audio&Recursive=true&…` | Sorted; `Fields=RunTimeTicks`. |
| List albums | `GET /Items?IncludeItemTypes=MusicAlbum&Recursive=true&…` | `Fields=ProductionYear,ChildCount`. |
| List artists | `GET /Artists?…` | Dedicated artists endpoint. |
| Favourite ids | `GET /Items?Filters=IsFavorite&IncludeItemTypes=Audio&…` | `EnableImages=false`. |
| Toggle favourite | `POST` / `DELETE /Users/{userId}/FavoriteItems/{itemId}` | POST marks, DELETE clears. |
| Lyrics | `GET /Audio/{itemId}/Lyrics` | 404 = "no lyrics", a normal outcome. |
| Cover art | `GET /Items/{itemId}/Images/Primary` | **Token-free**; safe to cache/persist. |
| Direct stream | `GET /Audio/{itemId}/stream?static=true&api_key=…&UserId=…&DeviceId=…` | `static=true` serves the original file (no transcode). Token in query. |
| Download | `GET /Items/{itemId}/Download?api_key=…` | Original file for the offline cache. Token in query. |
| Report playback start | `POST /Sessions/Playing` | Body `{ItemId, PositionTicks, …}`; shows Linthra on the dashboard. Best-effort. |
| Report playback progress | `POST /Sessions/Playing/Progress` | Throttled heartbeat; `IsPaused` carries pause/resume. Best-effort. |
| Report playback stop | `POST /Sessions/Playing/Stopped` | Settles the server's session/play state. Best-effort. |

**Authentication header.** Authenticated JSON calls send the standard Jellyfin
`Authorization: MediaBrowser Client="Linthra", Device="Linthra", DeviceId="…",
Version="…", Token="…"` header, built once in `JellyfinAuthHeader`. The token is
woven into a header or an `api_key` query only at request time and is **never**
stored on a track, written to the catalog, logged, shown in the UI, or placed in
an error.

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
- **Tolerant parsing.** Unknown JSON fields are ignored, a missing `Items`
  array reads as empty, and malformed entries are skipped, so a server that adds
  fields won't break listing.
- **`static=true` direct play** is the safest streaming path: it serves the
  original bytes the engine can open, avoiding transcode/HLS negotiation that
  varies between server versions and codecs.
- **Bump the tested floor** (`kMinimumTestedJellyfinVersion`) only when you have
  actually tested against, and intend to require, a newer baseline.

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
7. **Untested-version note** → streaming usually still works; upgrade the server
   if you hit issues.

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
the version-support classification, the **host only** (never a full URL), and
the **kind** of the last error.

What it never includes: your **password**, the **access token**, the
`Authorization` header, or any **full authenticated URL** (the address is
reduced to its host so a tokenized query can't ride along). Paste it into a bug
report as-is.
