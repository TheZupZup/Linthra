# Music providers

Linthra is a **self-hosted / user-owned** music player. It plays music you
already have — on your device or on a server you run — and is built around one
extension point, the **`MusicSource`** (`lib/core/services/music_source.dart`),
so new backends slot in without touching the UI or storage layers.

Each provider declares what it can do through a small **capability model**
(`lib/core/sources/music_provider.dart`), so the UI only ever offers actions a
source actually supports:

| Capability             | Meaning                                                       |
| ---------------------- | ------------------------------------------------------------- |
| `canStream`            | Tracks play by resolving a stream URL at play time.           |
| `canCache`             | Tracks can be downloaded for offline use (token-free cache).  |
| `canFavoriteTracks`    | The heart can be toggled for this source's tracks.            |
| `canReadFavoriteState` | The source exposes a readable liked/favourite state.          |
| `canSyncFavorites`     | Favourites mirror two-way with this source's server.          |
| `canListPlaylists`     | The source's (server) playlists can be imported and listed.   |
| `canCreatePlaylist` / `canEditPlaylist` / `canDeletePlaylist` | Playlists of this kind can be created / edited / deleted. |
| `canSyncPlaylists`     | Playlists mirror with this source's server.                   |
| `canLyrics`            | Lyrics can be fetched for the source's tracks.                |
| `canCast`              | A track's playback URL is network-reachable, so it can cast.  |

A track carries an opaque `scheme:` URI (`subsonic:<id>`, `jellyfin:<id>`,
`plex:<ratingKey>`, or a file path) and **never** an authenticated URL —
stream/download URLs are minted on demand at play/download time and discarded,
so no secret reaches the persisted catalog.

## Provider matrix

| Provider              | sourceId   | Stream | Cache | Favorites | Playlists | Lyrics | Cast |
| --------------------- | ---------- | :----: | :---: | :-------: | :-------: | :----: | :--: |
| Local music           | `local`    |   ✅   |  —    | ✅ local  | ✅ local  |   ✅   |  —   |
| Jellyfin              | `jellyfin` |   ✅   |  ✅   | ✅ synced | ✅ synced |   ✅   |  ✅  |
| Navidrome / Subsonic  | `subsonic` |   ✅   |  ✅   | ✅ synced | ✅ synced |   ✅   |  ✅  |
| Plex                  | `plex`     |   ✅   |  ✅   |    🔜     |    🔜     |   ✅   |  🔜  |

✅ implemented · 🔜 planned follow-up · — not applicable. "local"
favourites/playlists stay on-device; "synced" ones mirror with the server
(server is the source of truth on refresh).

## One library across providers

Because two servers can expose the **same** music, Linthra unifies the catalog:
it **stores** every provider's copy of a song but **displays** one row per
logical track, and plays the copy from your active/default provider (the server
you most recently signed into), falling back to another source when that
provider doesn't have the song. De-duplication is conservative and never deletes
data. See [unified-library.md](unified-library.md) for the model, the matching
rules, and the "Playing from …" source indicator.

## Local files

Pick a folder with the Android Storage Access Framework picker and scan it.
Tracks play from their on-device path. The scan **reads each file's audio tags**
(title/artist/album/track number/duration) so a local library indexes and groups
like a server source, falling back cleanly to the file name and
`…/Artist/Album/Track` folders when a tag is missing — see
[local-music.md](local-music.md). The chosen folder and the scanned catalog
survive a restart. No broad storage permission is requested (tags are read
through the same folder grant). A file's **embedded** cover art is read during
the same scan and cached privately, so local tracks show their artwork too.
A track's **lyrics** are read on demand from a sidecar file sitting next to the
audio — `Song.lrc` (synced) or `Song.txt` (plain) beside `Song.mp3` — located
through the same folder grant (never a raw `/storage/…` path); when present they
appear in the normal Lyrics panel, synced highlighting included, and a track
with none (or one that can't be read) keeps the calm "no lyrics" state. Reading
**embedded** lyrics tags from the audio file is a planned follow-up.
On-device files cannot be cast (a receiver can't reach a file on your phone).

## Jellyfin

Connect to your own Jellyfin server, test the connection, sign in, sync your
library, and stream — including over an HTTPS/Cloudflare-proxied domain. A sync
also imports your **playlists** and adopts your **liked/favourite** tracks by
default, and synced lyrics work; tracks can be marked for offline use and cast
to a Chromecast. The access token is stored encrypted on-device; the password is
never persisted. See [jellyfin-compatibility.md](jellyfin-compatibility.md) for
connectivity, and [jellyfin-sync.md](jellyfin-sync.md) for what syncs (playlists
+ favourites), the documented limitations, and the token-free guarantees.

## Navidrome / Subsonic

Linthra speaks the **Subsonic-compatible REST API**, so it works with
[Navidrome](https://www.navidrome.org/) and other Subsonic-compatible servers.

### What works now

- **Configure** a server (`Settings → Navidrome / Subsonic`): server URL,
  username, password. HTTPS reverse-proxy / self-hosted domains are supported;
  no personal domain is hardcoded.
- **Test connection** and **sign in** — both verify the credentials against the
  server's `ping` endpoint.
- **Sync library** (“Sync Navidrome library”): artists, albums, and tracks are
  fetched (walking the ID3 album lists) and upserted into the local catalog
  under the `subsonic` source id. The same sync also imports **playlists** and
  adopts server **favourites** (below), best-effort.
- **Favourites / hearts**: the heart on a Subsonic track mirrors two-way with
  the server. Hearting sends `star`, un-hearting sends `unstar`, and a **Sync
  library** (or app launch) reads `getStarred2` to reflect stars set on another
  client. A failed push keeps the local heart and reconciles on the next sync;
  the local favourite state is never lost silently.
- **Playlists**: your Navidrome playlists are imported and listed alongside
  local ones (with a subtle “· Navidrome” source tag), preserving remote ids and
  track order, and never duplicating on repeated sync. Creating a playlist for
  Navidrome tracks can create it on the server; adding, removing, reordering, and
  renaming a synced playlist update the server (Subsonic replaces the full
  ordered song list in one idempotent `createPlaylist` call). Deleting a synced
  playlist removes it from the server only behind the same explicit confirmation
  as every delete — a local-only playlist delete never touches the server.
- **Stream** a track: tapping an uncached Subsonic track streams it directly,
  resolving the URL at play time. A cached copy is preferred automatically.
- **Offline cache**: a Subsonic track can be downloaded for offline use (the
  original file via `download.view`).
- **Cast**: a Subsonic track casts to a Chromecast as a live stream.
- **Cover art**: album/artist/track artwork shows across the app. The catalog
  stores only a credential-free `subsonic-cover:<coverArtId>` reference; the
  authenticated `getCoverArt` URL is resolved on demand at render time (the
  salt+token are woven in then, never persisted), exactly like stream URLs.
  - **Media session (lock screen / Android Auto).** The platform session loads
    `MediaItem.artUri` in its **own process** — where the render-time resolver
    can't reach and a credentialed URL must never go — so Linthra fetches a
    **server-downscaled** cover itself, caches it to a private file keyed by a
    hash of the credential-free reference, and pre-warms the now-playing + next
    covers off the playback path. The handler then hands the session a
    credential-free **`content://` URI** (`MediaArtworkFileProvider`, authority
    `…linthra.mediaartwork`, serving only that hashed-filename cover cache —
    `res/xml/media_artwork_paths.xml`). The provider is `exported="false"` and
    grants the media hosts (Android Auto / SystemUI / Bluetooth) **read-only**
    access to each cover URI when Linthra opens it — so their own processes can
    read it — and `audio_service` also decodes it in-process; the embedded
    album-art bitmap is downscaled (`artDownscale*`) so it survives delivery to
    the car. The credential is used once and never stored, logged, exposed, or
    put in the URI / filename. A failed/slow fetch leaves the card art-less and
    never blocks playback. Pending real-car confirmation; see
    `docs/android-auto.md`.
  - Cast still omits Subsonic artwork (a credentialed URL must not reach the
    receiver).
- **Lyrics**: synced or plain lyrics are fetched on demand via the OpenSubsonic
  `getLyricsBySongId` extension (how Navidrome exposes embedded/sidecar lyrics),
  with a fallback to the legacy `getLyrics` (plain text, matched by artist +
  title) for servers without the extension. When a server has none, the lyrics
  panel keeps its calm "no lyrics" state; the credential is never logged or put
  in an error.

### Server URL & local testing

Enter the **server root** (e.g. `http://192.168.1.50:4533`) — Linthra appends
the `/rest/<method>.view` API paths itself, so you never type `/rest` (and a
trailing `/rest` you paste is stripped). A bare host defaults to HTTPS; an
explicit `http://` is kept for a LAN server, and reverse-proxy subpaths are
preserved. A shipped Android network-security config permits cleartext so a LAN
`http://` server is reachable.

No production server? A one-command local Navidrome (Docker Compose) and a manual
test checklist live in
**[navidrome-dev-setup.md](navidrome-dev-setup.md)** /
[`tools/dev/navidrome/`](../tools/dev/navidrome/).

### Authentication & security (token+salt)

Subsonic's modern auth sends, on every request,
`u=<user>&t=<token>&s=<salt>` where `token = md5(password + salt)`. Linthra
computes **one** random salt and its token at sign-in and stores **only those**
(encrypted on-device, via `flutter_secure_storage`). The password is used to
derive the token and then **discarded — never persisted, never logged**. This
mirrors how Jellyfin stores a derived access token rather than the password.

Concretely, Linthra:

- never stores the plaintext password;
- never logs the password, salt, or token;
- never stores an authenticated stream/download URL in `Track.uri` or the
  database (the URI is the opaque `subsonic:<id>`);
- never stores an authenticated cover-art URL in `Track.artworkUri` or the
  database (it stores the credential-free `subsonic-cover:<id>` reference, and
  weaves the salt+token in only when an image is actually rendered);
- never puts a credential in a cache filename or cache metadata (the offline
  audio cache file extension comes from the response content type, not the URL;
  the media-session artwork cache filename is a hash of the credential-free
  `subsonic-cover:` reference — never the server URL or auth query);
- never surfaces a credential or credentialed URL in a UI error message;
- resolves stream/download URLs **only at play/download time**, and cover-art
  URLs **only at render time**.

### What remains (follow-ups)

These are declared **unsupported** in the capability model today, so their
actions stay hidden/disabled rather than failing:

- **Synced lyrics from the legacy endpoint** — the OpenSubsonic
  `getLyricsBySongId` path returns synced lyrics today; the legacy `getLyrics`
  fallback is treated as plain text, so any LRC-style timestamps embedded in its
  value aren't time-synced yet. That refinement is a follow-up.
- **Per-track cast content type** — the cast receiver is sent a generic
  `audio/mpeg` hint; an exact per-track type / transcode profile is a follow-up.
- **In-app browse/search by artist/album** — the synced catalog lists tracks;
  richer browsing is shared work across all providers.

## Plex

A **read-only** [Plex Media Server](https://www.plex.tv/) provider built behind
the same `MusicSource` seam — see [plex.md](plex.md) for the full design and
issue #178 for the history. **Connect from Settings** with your Plex account
(the in-app *Connect with Plex* sign-in) or, under *Manual setup (advanced)*, a
server URL + Plex token. Linthra verifies the server, persists the session
encrypted at rest, and — unlike Jellyfin/Subsonic, which sync the whole
server — asks the user to **pick which music libraries** to include (the
selection is saved with the session and scopes every fetch; connected with
nothing selected simply means an empty library).

**Syncing follows the selection.** Choosing a library kicks a background
catalog sync automatically (rapid checkbox changes coalesce into one re-run),
and a *Sync Plex library* button reruns it on demand; the synced tracks then
appear in the Library like any other source's. Because the selection scopes
the Plex library, a sync **replaces** the catalog's Plex slice even when the
result is empty — deselecting a library really removes its tracks. A library
deleted on the server is pruned from the selection on the next refresh.
**Disconnecting** removes the Plex session *and* the synced Plex rows (without
a session, streaming can't resolve a play URL again); reconnecting to the
**same** server keeps the library selection, while a different server starts
clean.

Underneath, the full plumbing is wired: recognition of `plex:<ratingKey>` track
URIs in the playback router (two-step play resolution, minting the tokenized
stream URL only at play time), and render-time resolution of credential-free
`plex-thumb:` cover references. **Streaming, lyrics, and offline caching are
supported**, alongside the plex.tv *Connect with Plex* sign-in; **favorites,
playlists, and cast stay unsupported** — declared off so their actions stay
hidden rather than offered and failing. Plex follows the same token-safety
rules as every other provider (token encrypted at rest, never logged, never
shown again after saving, never woven into a persisted URI or cache filename).

Linthra also reports a playback **timeline**, so it appears as an active player
in the server's Now Playing dashboard. That report is one-way, though, so the
player does not yet *react* to remote play/pause/skip commands from other Plex
apps — receiving those is the separate **Plex Companion** protocol, designed in
[plex-remote-control.md](plex-remote-control.md).

## Future provider possibilities

The `MusicSource` seam is designed so more **self-hosted / user-owned** backends
can be added the same way Jellyfin and Subsonic were:

- **WebDAV** — play from a WebDAV share (Nextcloud, etc.).
- **SMB / NAS** — browse and stream from a network file share.
- **DLNA / UPnP** — discover and play from a media server on the LAN.

Each would implement `MusicSource` (and the narrow stream/download seams),
declare its capabilities, and add a settings section — with the same rule that
credentials are stored securely and never woven into a persisted URI.

## Non-goals

Linthra stays focused on music you own or host yourself. It does **not**, and
will not:

- play from **Spotify** or other closed streaming services;
- **bypass DRM** of any kind;
- perform **unauthorized downloads**;
- **rip** or extract content from closed streaming services.
