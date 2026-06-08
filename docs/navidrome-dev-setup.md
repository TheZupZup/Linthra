# Navidrome / Subsonic dev setup & testing

How to run a local [Navidrome](https://www.navidrome.org/) server to test
Linthra's Subsonic-compatible provider end to end, plus the URL rules, the error
messages you might see, and a manual test checklist — so the integration can be
exercised without a production server.

Linthra speaks the **Subsonic REST API**, so this also applies to other
Subsonic-compatible servers (Airsonic-Advanced, Gonic, …). The behavior here is
enforced by the Subsonic source under `lib/core/sources/subsonic/` and its tests
under `test/core/sources/subsonic/`.

## 1. Run Navidrome locally

A ready-to-use Docker Compose file lives in
[`tools/dev/navidrome/`](../tools/dev/navidrome/).

```bash
# 1. Put a few audio files in the music folder (anything Navidrome can read:
#    mp3, flac, m4a, ogg…). Tagged files browse best.
cp ~/some-music/*.mp3 tools/dev/navidrome/music/

# 2. Start the server
docker compose -f tools/dev/navidrome/docker-compose.yml up -d

# 3. Open the web UI to confirm it scanned your files
#    http://localhost:4533   (user: admin   pass: admin)

# Stop it later:
docker compose -f tools/dev/navidrome/docker-compose.yml down
```

The compose file auto-creates an **`admin` / `admin`** user on first run
(`ND_DEVAUTOCREATEADMINPASSWORD`) and rescans `./music` every minute. The
database lives in `./data` (delete it to start fresh). Both folders are
git-ignored.

> This is a **local-testing** server: plain http, a throwaway password. Don't
> expose it to the internet or reuse the password anywhere.

### No test music handy?

Any audio files work. For freely-licensed tracks to test with, the Free Music
Archive (https://freemusicarchive.org/) and the Internet Archive
(https://archive.org/details/audio) offer Creative Commons / public-domain
music. A handful of tagged files is enough to exercise browse, stream, cache,
and cast.

## 2. Connect Linthra to it

In Linthra: **Settings → Navidrome / Subsonic**, then enter the **server root
URL** — Linthra appends the `/rest/...` API paths itself, so you never type
`/rest`.

| Running Linthra on… | Server URL to enter |
| --- | --- |
| Android **emulator** (same machine as Docker) | `http://10.0.2.2:4533` |
| Android **device** on the same Wi-Fi | `http://<your-computer-LAN-IP>:4533` (e.g. `http://192.168.1.50:4533`) |
| Desktop / `flutter run -d linux` | `http://localhost:4533` |

Find your computer's LAN IP with `ip addr` / `ifconfig` (Linux/macOS) or
`ipconfig` (Windows). Username `admin`, password `admin`.

Tap **Test connection** (Subsonic's `ping` is authenticated, so a successful
test also confirms sign-in will work), then **Sign in**, then **Sync Navidrome
library**.

### HTTP / cleartext on Android

A LAN server reached over plain `http://` works because Linthra ships a
[network security config](../android/app/src/main/res/xml/network_security_config.xml)
that permits cleartext. Android blocks cleartext by default on modern targets;
without that config, `http://192.168.1.50:4533` would fail. HTTPS is still
preferred for anything reachable beyond your LAN. (This config also lets a
self-hosted **Jellyfin** server be reached over http on the LAN.)

## 3. URL normalization

`SubsonicServerUrl.normalize` cleans up what you type so the connection test and
sign-in always agree:

| You type | Linthra uses | Why |
| --- | --- | --- |
| `192.168.1.50:4533` | `https://192.168.1.50:4533` | A bare host defaults to **HTTPS**. Add `http://` for a LAN server. |
| `http://192.168.1.50:4533` | `http://192.168.1.50:4533` | Explicit scheme + port kept (LAN). |
| `music.example.com` | `https://music.example.com` | Bare host → HTTPS. |
| `https://example.com/navidrome` | `https://example.com/navidrome` | A reverse-proxy **subpath** is preserved. |
| `http://host:4533/rest` | `http://host:4533` | A trailing **`/rest`** is stripped — Linthra adds it itself, so keeping it would double to `/rest/rest/...`. |
| `https://host/?x=1#y` | `https://host` | Trailing slash, query and fragment dropped. |

Endpoints are built in **one place** — `SubsonicEndpoints`
(`lib/core/sources/subsonic/subsonic_endpoints.dart`) — as
`<base>/rest/<method>.view` with the token+salt auth woven into the query
(`u`,`t`,`s`,`v`,`c`,`f`). The salt/token ride in the query only, never the path,
and are never stored on a track or in the catalog.

## 4. Error messages you might see

Failures map to a typed `SubsonicErrorKind`, each with a friendly, **secret-free**
message (never the password, salt, token, or a credentialed URL):

| Situation | Kind | What the message tells the user |
| --- | --- | --- |
| Address isn't a usable URL | `invalidUrl` | "Enter your server address, e.g. …" / "must start with https://". |
| Wrong username/password | `unauthorized` | "Your username or password was not accepted by the server." |
| `http://` blocked by Android | `cleartextBlocked` | "The insecure http:// connection … was blocked. Use https://, or allow cleartext for a local-network server." |
| Self-signed / untrusted TLS cert | `insecureConnection` | "Couldn't verify your server's security certificate…" |
| Server down / wrong host / DNS / timeout | `notReachable` | "Couldn't reach the server. Check the address and that you're online." |
| Reachable, but not a Subsonic API (HTML page, 404 on `/rest`, reverse-proxy error, wrong path) | `notSubsonic` | "That address responded, but it doesn't look like a Subsonic-compatible server… point it at the server root, not a sub-page." |
| Server-side error (HTTP 5xx) | `serverError` | "Your music server reported an error (HTTP …)." |
| Item missing (Subsonic code 70) | `streamUnavailable` | "This track isn't available from your server right now." |
| Incompatible/odd response | `unsupportedResponse` | "…returned a response Linthra could not use. It may be an unsupported version." |

### Mapping the common failure reports

- **Wrong URL** → `invalidUrl` (format) or `notReachable` (host not found).
- **Wrong username/password** → `unauthorized`.
- **HTTP blocked / cleartext** → `cleartextBlocked` (with the cleartext config
  shipped, this is rare; it would mean a build/policy that re-blocked http).
- **Self-signed certificate** → `insecureConnection`. Linthra does **not**
  auto-trust self-signed certs (that would be unsafe); put the server behind a
  reverse proxy with a trusted certificate, or use `http://` on a trusted LAN.
- **Reverse-proxy path issue** → usually `notSubsonic`: the proxy serves the web
  UI but `/rest` isn't reachable at that base. Point the URL at the base where
  `/rest/ping.view` resolves.
- **Reachable in a browser but API ping fails** → `notSubsonic`: the browser
  loads the **web UI** at `/`, while the app calls the **API** at `/rest`. Make
  sure the `/rest` path is proxied/reachable and the address is the server root
  (not a sub-page).

## 5. Manual test checklist (Navidrome)

Run against the local server above (and, ideally, once over an HTTPS reverse
proxy). Tick what passes; file gaps via the **Navidrome / Subsonic compatibility
report** issue template.

**Connection & URL handling**
- [ ] `http://<LAN-IP>:4533` (root, no `/rest`) → Test connection succeeds and
      shows the product/version (e.g. "Connected to Navidrome 0.5x").
- [ ] Pasting `http://<LAN-IP>:4533/rest` also connects (trailing `/rest`
      stripped).
- [ ] Trailing slash / query (`…:4533/?x=1`) still connects.
- [ ] Wrong password → "username or password was not accepted" (`unauthorized`),
      and any existing connection is **kept**.
- [ ] Wrong host/port → "Couldn't reach the server" (`notReachable`).
- [ ] A non-Subsonic address (e.g. a random website) → "doesn't look like a
      Subsonic-compatible server" (`notSubsonic`).

**Library & playback**
- [ ] Sign in, then **Sync Navidrome library** → artists/albums/tracks appear.
- [ ] Tap an uncached track → it streams.
- [ ] Mark a track for **offline** → it downloads and then plays from cache
      (airplane mode confirms it plays offline).
- [ ] **Cast** a track to a Chromecast (if available) → it plays on the
      receiver.
- [ ] Sign out & clear → library/session cleared; a stale "Synced N" line is
      gone.

**Security spot-checks** (should always hold)
- [ ] No password/token/salt appears in any on-screen message, the connected
      server line, or copied diagnostics.
- [ ] The connected-server line shows the host/URL but no `t=`/`s=` query.

## 6. Notes & follow-ups

- **Jellyfin is unaffected** by the Subsonic error-handling changes (separate
  files under `lib/core/sources/jellyfin/`). The shared cleartext config benefits
  a LAN Jellyfin server too. Mirroring the granular `cleartextBlocked` /
  `insecureConnection` messages into the Jellyfin client is a possible follow-up.
- Favourites, lyrics, and cover art remain **planned** for the Subsonic provider
  (see [providers.md](providers.md)); they're declared unsupported in the
  capability model, so their actions stay hidden rather than failing.
