# Jellyfin (self-hosted music)

Linthra can connect to your own [Jellyfin](https://jellyfin.org) server,
including one published over HTTPS through a **Cloudflare** domain or tunnel. This
page is the setup overview; deeper references live in
[jellyfin-compatibility.md](jellyfin-compatibility.md) (endpoints, version floor,
Cloudflare, troubleshooting) and [jellyfin-sync.md](jellyfin-sync.md) (playlists
& favourites sync).

## Setup

Open **Settings → Jellyfin** and:

1. **Server URL** — enter your address, e.g. `https://music.example.com`. A bare
   host gets `https://` automatically; a LAN `http://host:8096` and a
   reverse-proxy subpath like `https://example.com/jellyfin` also work.
2. **Test connection** — confirms the address is reachable and really is a
   Jellyfin server (reads the public `/System/Info/Public` endpoint, no
   credentials) and shows its name/version. An older-than-tested server shows a
   gentle "untested" note; it is never blocked.
3. **Username + password → Sign in** — authenticates and stores the resulting
   session encrypted on-device. Your **password is never saved**.
   - **Linthra starts a first sync automatically** right after you sign in, so
     your library fills in on its own — you don't have to find the Sync button.
     The Jellyfin card shows _"Syncing your Jellyfin library…"_ while it runs and
     a short summary when it's done, and the Library shows a friendly _"Your
     Jellyfin library is syncing"_ note instead of looking empty.
   - This first sync runs **once per server/account**. Reconnecting the same
     account (or just reopening Settings or relaunching the app) won't kick off
     another full sync on its own. Connecting a **different** server or signing
     in as a **different** user starts a fresh first sync.
4. **Sync library** — the manual sync is always available for an on-demand
   refresh. It pulls your artists/albums/tracks **and your playlists and
   liked/favourite tracks** into the local catalog so they appear in Library,
   Playlists, and Favorites. If the first sync didn't finish (e.g. the server
   was briefly unreachable), the card shows a friendly message and a **Retry**.
5. Tap a synced track to **stream** it, or use the download control to keep it
   **offline** (see [offline-cache.md](offline-cache.md)).
6. **Copy Jellyfin diagnostics** — a short, **secret-free** report for bug
   reports (app version, connection state, server name/version/host-only, last
   error kind). It never includes a password, token, `Authorization` header, or
   full authenticated URL.
7. **Sign out & clear** — forgets the saved session and clears the settings.

## Cloudflare

A Cloudflare-proxied or Cloudflare Tunnel (`cloudflared`) Jellyfin is just a
normal HTTPS endpoint — point the URL at your public domain. Two things to know:

- If the domain returns a Cloudflare **error page** (HTML / a 5xx like 521/522)
  or a challenge, Linthra reports a friendly "doesn't look like a Jellyfin
  server" / "couldn't reach the server" message rather than a raw failure.
- **Cloudflare Access / Zero Trust** (an extra auth layer *in front of* Jellyfin)
  is **not** supported yet; Linthra speaks only to Jellyfin's own auth. Use a
  hostname that reaches Jellyfin directly.

## Streaming playback

Streaming routes through a `PlayableUriResolver` seam, so the controller opens
whatever URI it's given rather than assuming a local file. A
`JellyfinPlayableUriResolver` reads the live signed-in source, verifies the
session (a tiny `GET /Users/Me` check), then asks the source to mint the
authenticated **direct-play** stream URL — `/Audio/<id>/stream?static=true` — **at
play time**. `static=true` serves the original file bytes (the reliable "direct
streaming" path the engine can open) rather than a negotiated transcode/HLS
variant; auth rides in the `api_key` **query** (not a header), because that is
what the engine itself fetches with and query auth survives redirects.

Before the URL reaches the engine the source **probes** it (a one-byte ranged GET,
following any Cloudflare/Jellyfin redirects) and checks the status + content type,
so a Cloudflare page, an expired token, or a non-audio response becomes a precise
message instead of the engine's opaque "couldn't play". The player surfaces
friendly errors — **not signed in**, **expired session**, **server unreachable**,
**a web page instead of audio**, **not an audio stream**, **track not available**,
**unsupported response**, and a generic **couldn't stream** — branched on a typed
error kind, not message text. Buffering, preload, and interruption recovery are in
[streaming.md](streaming.md).

## Security (token handling)

This integration is built so secrets don't leak:

- **Passwords are never persisted.** The password is sent once to obtain a token,
  then discarded; it never enters app state.
- **The token is encrypted at rest** via `flutter_secure_storage` (Android
  Keystore-backed), not plaintext `shared_preferences`.
- **Nothing logs the token or password.** `JellyfinSession.toString()` redacts
  the token; a track's stored URI is a token-free `jellyfin:<id>`. The
  authenticated stream URL (play time) and download URL (fetch time) are minted
  only on demand, never stored, never logged, never shown in the UI.
- **Offline downloads inherit the same handling** — a cache file name is derived
  only from the non-secret track id; the token never lands in the file name, the
  download-store metadata, a log, or an error.
- **Diagnostics are secret-free by construction** — the server address is reduced
  to its **host only**, and tests assert no token reaches either sink.

## Known limitations

- **Track-level downloads only** — album/playlist "download all" is deferred.
- **Single server only** — one session at a time; no multi-server support.
- **Direct play only** — no server-side transcoding fallback for exotic formats.
- **No two-way conflict resolution** — for a synced playlist the server is the
  source of truth on refresh; playlist rename/reorder are local-only. See
  [jellyfin-sync.md](jellyfin-sync.md).
