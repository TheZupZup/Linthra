# WebDAV / NAS provider (design)

**Status: design only.** This document is the answer to
[#86](https://github.com/thezupzup/linthra/issues/86). No WebDAV code ships with
it, no dependency is added, and no existing provider changes behaviour. The goal
is that a contributor can pick up any one of the steps in
[Suggested PR split](#suggested-pr-split) and implement it without having to
re-decide anything architectural.

It follows the same shape [plex.md](plex.md) did before Plex was built: settle
the auth model, the identity model, and the secret rules on paper first, then
build in small reviewable pieces.

> **The one-line summary.** WebDAV is a *file* protocol, so a WebDAV provider is
> Linthra's local-music scanner with HTTP in place of the filesystem, wearing the
> same `MusicSource` / capability / offline-cache clothes every other provider
> wears. It is emphatically **not** a generic file browser bolted onto the app.

## Contents

- [Scope](#scope)
- [What WebDAV gives us, and what it does not](#what-webdav-gives-us-and-what-it-does-not)
- [Connection and auth model](#connection-and-auth-model)
- [TLS expectations and self-signed certificates](#tls-expectations-and-self-signed-certificates)
- [Secret storage](#secret-storage)
- [Server capability detection](#server-capability-detection)
- [Track identity](#track-identity)
- [Directory traversal (the library scan)](#directory-traversal-the-library-scan)
- [URL and path encoding](#url-and-path-encoding)
- [Metadata acquisition](#metadata-acquisition)
- [Library semantics: folders and tags](#library-semantics-folders-and-tags)
- [Playback: resolving, streaming, seeking](#playback-resolving-streaming-seeking)
- [Offline downloads and cache behaviour](#offline-downloads-and-cache-behaviour)
- [Reconnect and failure behaviour](#reconnect-and-failure-behaviour)
- [Duplicates and collisions](#duplicates-and-collisions)
- [Large libraries and slow NAS](#large-libraries-and-slow-nas)
- [Credential-safe logs, diagnostics and persistence](#credential-safe-logs-diagnostics-and-persistence)
- [Capability model](#capability-model)
- [Shared-code touch points](#shared-code-touch-points)
- [Proposed file layout](#proposed-file-layout)
- [Tests to add](#tests-to-add)
- [Suggested PR split](#suggested-pr-split)
- [Open questions and risks](#open-questions-and-risks)

## Scope

### v1 (the first shippable slice)

A **read-only** WebDAV source behind the existing `MusicSource` seam:

- connect to one WebDAV server (URL, username, app password), verify it, persist
  the session encrypted;
- scan a chosen music root into the normal SQLite catalog under the `webdav`
  source id, so WebDAV tracks appear in the Library exactly like everyone else's;
- stream a track by minting an authenticated request **only** at play time;
- keep the credential out of `Track.uri`, out of the database, out of cache file
  names, out of logs, and out of every UI error.

That slice is PRs 2 to 4 of the [split](#suggested-pr-split). Everything after it
(artwork, real tags, sidecar lyrics, offline downloads, folder browsing) is an
additive step, each one independently useful and independently reviewable.

Throughout this document, **v1** means that first shippable slice and **PR n**
refers to a step in the split, so a capability marked "PR 6" is one that turns on
when the offline-downloads step lands.

### Out of scope, deliberately

- **Writing to the server.** No `PUT`, `MKCOL`, `PROPPATCH`, `DELETE`, `MOVE`,
  `COPY`, or `LOCK`, ever. Linthra never modifies a user's files, and a
  read-only share must be a first-class, fully working configuration rather
  than a degraded one.
- **SMB/CIFS and NFS.** Named together with WebDAV on the roadmap, but they are
  different transports with their own auth and their own native dependencies.
  The identity, scan, metadata and capability model here is reusable for them;
  the transport is not.
- **DLNA/UPnP.** Discovery-based and content-directory-shaped, a separate design.
- **CalDAV/CardDAV**, WebDAV **search** (`DASL`/`SEARCH`), and RFC 3744 ACL
  introspection. Not needed to play music.
- **Server-side transcoding.** There is no server to ask. WebDAV is direct play
  of the original bytes or nothing, which is also the honest expectation to set.
- **A second library architecture.** No parallel "files" tab, no separate
  storage, no bypass of `MusicLibraryRepository`.

## What WebDAV gives us, and what it does not

WebDAV (RFC 4918) is HTTP plus a directory listing verb. Mapped onto what a
music provider needs:

| Linthra needs | Jellyfin/Subsonic/Plex give | WebDAV gives |
| --- | --- | --- |
| A stable item id | a server-side id (`ratingKey`, song id) | nothing: only a path |
| Artist/album/title/duration | a tagged, indexed database | a file name, a size, a content type, an mtime, an ETag |
| Album grouping | an album id | a folder, by convention |
| Cover art | an art endpoint | maybe a `cover.jpg` next to the files |
| Lyrics | an API | maybe an `.lrc` next to the files |
| Favourites / playlists | per-user server state | nothing |
| Byte-range seeking | yes, reliably | usually, not always |
| "What changed since last sync" | incremental APIs | ETag and mtime per resource, walked by hand |

So the useful mental model is **not** "another Jellyfin". It is
`LocalMusicSource` with a network filesystem underneath:

- the **scan** is a directory walk (`PROPFIND Depth: 1` instead of a SAF
  content-resolver walk), with the same "skip a bad subtree, never zero out the
  library" resilience the SAF walk already has;
- the **metadata ladder** is the one `LocalTrackMapper` already uses (real tags
  when we can read them, then `…/Artist/Album/NN Title.ext` path conventions,
  then the file name);
- the **sidecar conventions** are the ones local music already supports
  (`cover.jpg` beside the album, `Song.lrc` beside `Song.mp3`);
- the **identity problem** is the one `LocalTrackIdentity` already reasons about
  (a path is not an identity; tags are).

That reuse is the point. It keeps the WebDAV provider small, and it means the
same hardening work pays off twice.

### Server families we target

The design is validated against five shapes, because they fail differently:

| Target | Notes that drive design decisions |
| --- | --- |
| **Plain WebDAV** (Apache `mod_dav`, nginx `dav_ext`, `rclone serve webdav`, `hacdias/webdav`) | The baseline. `Depth: infinity` is often disabled; nginx's DAV module answers `PROPFIND` only with the ext module installed. Range support is normal static-file range support, so it is good. |
| **Nextcloud / ownCloud** | Endpoint is `/remote.php/dav/files/<user>/`. **App passwords** are the right credential (revocable per device, and they keep working with 2FA on). Returns useful extra properties (`oc:fileid`, `oc:checksums`, `oc:size`) we can use but must not require. Chunked/zero-byte placeholders and server-side encryption can both yield surprising sizes. |
| **NAS vendor WebDAV** (Synology WebDAV Server, QNAP, OpenMediaVault, TrueNAS) | Vendor quirks dominate: `@eaDir` and `#recycle` junk directories, self-signed certificates on a LAN address, a disk-spin-up first byte that can take many seconds, case-insensitive underlying filesystems, and occasionally a non-standard port (Synology defaults to 5005/5006). |
| **Read-only shares** | A share mounted read-only, or a reverse proxy that allows only `GET`/`HEAD`/`PROPFIND`/`OPTIONS`. Must be fully supported, not degraded. |
| **Weak/partial Range support** | Some gateways and some `rclone serve webdav` backends ignore `Range` and answer `200` with the whole body, or answer `206` but mis-report `Content-Range`. Seeking and the stream probe both have to cope. |

## Connection and auth model

### Address input and normalization

Reuse `ServerUrlNormalizer` (`lib/core/sources/server_url_normalizer.dart`), the
same core Jellyfin, Plex and Subsonic use, behind a thin
`webdav_server_url.dart` that adds three WebDAV-specific rules:

1. **Userinfo is rejected, never stored.** `https://user:pass@nas.example.com/dav`
   is a realistic paste (it is how many NAS UIs present a WebDAV address) and it
   is a credential in a URL, which this project does not do. `normalize()` must
   reject the input with a clear message telling the user to put the name and
   password in their own fields. `ServerUrlNormalizer` already rebuilds the base
   URL from scheme/host/port/path only, so nothing leaks through by accident,
   but WebDAV needs the **explicit** rejection so the user is not silently
   signed in with a credential we then cannot rotate.
2. **The path is kept verbatim** (minus trailing slashes). Unlike Subsonic's
   `/rest` stripping, a WebDAV path prefix is meaningful and often deep
   (`/remote.php/dav/files/alice/Music`). Never guess it away.
3. **A bare host defaults to `https`**, exactly as the shared normalizer does.
   An explicit `http://` is preserved for a LAN NAS, and is then subject to the
   cleartext rules below.

The user supplies two addresses, not one:

- the **server base URL**, which is the DAV endpoint root, and
- the **music root path**, a path relative to that endpoint (default `/`).

Keeping them separate is what lets a user point Linthra at
`…/files/alice/Music/FLAC` without rescanning their documents, and it is what
makes a stored track path stable when the base URL changes (see
[Track identity](#track-identity)).

### Credentials: Basic auth, and app passwords by preference

**v1 uses HTTP Basic.** It is the only scheme every target server supports,
and WebDAV has no token-exchange handshake of its own.

Basic has a consequence this project has to state plainly instead of papering
over: **Basic re-sends the secret on every request, so the secret has to be
stored in a replayable form.** Jellyfin stores a derived access token, Subsonic
stores a salt and `md5(password + salt)`, Plex stores a server-scoped token, and
in all three cases the plaintext password is discarded. WebDAV cannot do that
with Basic. The password (or something equivalent to it) has to be kept.

So the mitigation is *scope*, not cryptography:

- **The settings UI asks for an app password and explains why.** Nextcloud
  ("Settings ▸ Security ▸ Create new app password"), Synology and QNAP can all
  issue a per-device credential that is revocable on its own and does not unlock
  the user's whole account. The field is labelled **App password** with
  *(recommended)*, with "or your account password" as the secondary hint, and a
  short note that an app password can be revoked from the server without
  changing anything else. This is the same instinct as Plex's
  "prefer the server-scoped token over the account token" rule: take the
  narrowest credential that works.
- **A dedicated read-only WebDAV user is documented** as the stronger option for
  NAS servers that support per-share permissions.
- The stored credential never leaves `flutter_secure_storage`, never enters a
  URL, never enters the catalog, and never enters a log. See
  [Secret storage](#secret-storage).

### Digest auth (follow-up), and the HA1-only rule

Several NAS servers offer Digest (RFC 7616) and a few are configured for it
exclusively. It is a **follow-up**, not v1, and when it lands it comes with
one rule worth writing down now:

> Store **HA1** (`md5(username:realm:password)`), not the password.

Digest responses are computed from HA1 plus the server nonce, so HA1 alone is
sufficient to authenticate, and it is realm-bound: it is useless against the
same user's account on a different realm, and useless for any non-Digest
endpoint. That is a real reduction in blast radius, and it is the exact same
shape as the Subsonic token: derive once at sign-in, store the derivation,
discard the password. A server that offers both schemes should therefore be
connected with Digest **by preference** once Digest exists.

Until then, if a server answers a Basic attempt with a Digest-only challenge,
the sign-in must fail with a specific, friendly message ("your server asks for
Digest authentication, which Linthra does not support yet") rather than a
generic "wrong password", which would send the user chasing the wrong problem.

### Preemptive auth, challenges, and redirects

Three rules, all security-relevant, all cheap:

1. **Never send Basic preemptively over cleartext.** Over `https` to the
   configured host, preemptive `Authorization` is fine and saves a round trip
   per request (which matters on a slow NAS). Over `http`, send the request
   unauthenticated first and only attach credentials after a `401` from the
   host the user configured, and only when that server has an explicit
   cleartext opt-in (below).
2. **Never follow a redirect with the `Authorization` header attached.**
   `package:http` follows redirects by default and re-sends headers, which means
   one open redirect on the user's reverse proxy could hand their NAS password to
   another host. The WebDAV client therefore sets `followRedirects = false` on
   authenticated requests and handles `301`/`302`/`307`/`308` itself: it accepts
   a redirect only when the target is the **same scheme, host and port** as the
   configured base URL (and is not a downgrade from `https` to `http`), re-issues
   the request there, and caps the chain at three hops. A cross-origin redirect
   is a typed failure with a friendly message, not a silent follow.
3. **Cleartext is opt-in per server, and the opt-in is visible.** Linthra already
   ships an Android network-security config permitting cleartext so a LAN
   `http://` server works, and `SubsonicException.cleartextBlocked()` already
   models a platform block. WebDAV adds a per-server acknowledgement for
   `http://` at sign-in time: one dialog explaining that the name and password
   will travel unencrypted on that network, stored as a flag on the session so
   it is never re-derived silently. No global switch, and no quiet default.

## TLS expectations and self-signed certificates

**Expectation:** HTTPS with a certificate the platform already trusts, which is
what a Let's Encrypt reverse proxy or a Tailscale/WireGuard tunnel gives. That
path needs no new code: the default client validates, and a handshake failure is
classified the way `HttpSubsonicClient._classifyTransportError` already
classifies it (a `HandshakeException`, a certificate error or a TLS error become
`insecureConnection`, never an echoed error string).

The hard case is the LAN NAS with a self-signed certificate, which is extremely
common and is the single most likely reason a user would otherwise be told to
"just use http". The policy:

- **Nothing is weakened globally.** No process-wide HTTP override, no
  app-wide certificate callback, no "trust all" build flavour, and no
  `http` downgrade performed on the user's behalf. Everything below is scoped to
  one `HttpClient` instance owned by the WebDAV source for one configured
  server.
- **A handshake failure is a stop, not a prompt to ignore.** Sign-in fails with
  the existing "couldn't make a secure connection" wording.
- **Trust is granted per certificate, by fingerprint, by the user, once.** When
  the failure is specifically an untrusted/self-signed certificate, the sign-in
  screen offers a single explicit path: it shows the certificate's **SHA-256
  fingerprint**, subject, issuer and validity window, states plainly that
  Linthra cannot verify it and that the user should compare the fingerprint with
  the one their NAS admin panel shows, and requires an explicit confirmation.
  What gets stored is the **fingerprint**, on that server's session.
- **The pin is exact, scoped, and fails closed.** The WebDAV client's
  certificate callback accepts a rejected certificate only when its SHA-256
  fingerprint equals the pinned one **and** the host matches the configured
  host. Any other certificate, including a valid one from a different issuer, is
  refused. A fingerprint change (renewal, or an attack, and the client cannot
  tell them apart) is a hard failure with a distinct message and a re-confirm
  prompt, never a silent re-pin.
- **It is visible and revocable.** The WebDAV settings card shows "Trusting a
  self-signed certificate" with the short fingerprint and a **Stop trusting**
  action, and the diagnostics report includes a secret-free line
  (`webdav: pinned self-signed certificate`) so a bug report makes the
  configuration obvious. The fingerprint is a public value, so it is safe in
  diagnostics; it is stored with the session anyway, since it describes the
  connection.

This needs a `dart:io`-backed client (`IOClient` over a configured `HttpClient`)
for the WebDAV source instead of the default `http.Client`, which is an
implementation detail confined to `http_webdav_client.dart`. On a platform where
that is unavailable, pinning is simply not offered and the user gets the plain
"couldn't make a secure connection" outcome.

## Secret storage

`WebDavSession` mirrors `SubsonicSession` and `PlexSession` field for field in
spirit:

| Field | Secret? | Notes |
| --- | :---: | --- |
| `baseUrl` | no | clean DAV endpoint root, no trailing slash, **no userinfo** |
| `musicRootPath` | no | server-relative, percent-decoded, no trailing slash |
| `username` | no | shown in settings |
| `secret` | **yes** | the app password (v1) or HA1 (Digest follow-up) |
| `authScheme` | no | `basic` today, `digest` later |
| `allowCleartext` | no | the explicit per-server `http` acknowledgement |
| `pinnedCertSha256` | no | a public fingerprint, present only when pinned |
| `serverProduct` / `davClasses` / `supportsRanges` | no | [capability detection](#server-capability-detection), diagnostics and behaviour |

Non-negotiables, identical to the rules already enforced for the other three
providers and tested the same way:

- Persisted **only** through `WebDavSessionStore`, whose production binding is
  `SecureWebDavSessionStore` (`flutter_secure_storage`, one versioned key
  `webdav_session_v1`), with an `InMemoryWebDavSessionStore` for tests.
- `WebDavSession.toString()` redacts `secret`. `toJson()` includes it, because
  its only caller is the encrypted store, and that is asserted in a test.
- The secret is **never** woven into a URL. This is WebDAV's one genuine
  security advantage over Plex and Subsonic: the credential rides in a header,
  so the entire "a transport exception or a log line echoed the tokenized URL"
  leak class does not exist here. The corresponding new risk is the
  **`Authorization` header**, which means header maps are as dangerous as URLs
  were: never log a request's headers, never put a header map in an exception,
  and strip headers from anything that reaches diagnostics.
- Never in `Track.uri`, `Track.artworkUri`, the catalog, a cache file name,
  cache metadata, a playlist row, a backup file, or a UI error.
- The settings controller's state never holds the secret after the sign-in call
  returns, and the field is cleared on success, exactly as the Plex and Subsonic
  controllers do.

## Server capability detection

A WebDAV server advertises very little, and the parts that matter for music are
not in the advertisement at all. Detection therefore happens once at connect
time (and is refreshed on a manual reconnect), and the result is persisted on the
session so the scan and the playback path do not re-probe per track.

| Step | Request | What it establishes |
| --- | --- | --- |
| 1 | `OPTIONS <baseUrl>` | Is this WebDAV? The `DAV:` response header must list class `1`. The `Allow:` header tells us whether `PROPFIND` is permitted, and (usefully) whether the share is read-only. |
| 2 | `PROPFIND <musicRoot>` with `Depth: 0` | Does the credential work, and does the music root exist? `401`/`403` vs `404` are different messages. |
| 3 | `PROPFIND <musicRoot>` with `Depth: 1` | Can we actually list? Also the first real listing, so it doubles as the "looks like music here" check used to give a good empty state. |
| 4 | `GET <one audio file>` with `Range: bytes=0-1` | **Range support.** A `206` with a sane `Content-Range` means seeking will work. A `200` with the full body means this server ignores `Range`. |

Notes that matter:

- **`Depth: infinity` is never relied on.** Apache disables it by default
  (`DavDepthInfinity off`), many proxies refuse it, and on a large library the
  response is enormous. The walk is always `Depth: 1` per directory. If a server
  happens to allow it, we still do not use it: one huge response is worse for
  progressive scanning, cancellation and memory than many small ones.
- **Read-only detection is a feature, not a warning.** `Allow:` lacking `PUT` is
  the expected, supported configuration. It is recorded for diagnostics and never
  surfaced as a problem.
- **`supportsRanges` is a per-server runtime fact, so it does not belong in
  `MusicProviderCapabilities`.** That model is a `const` per-provider value read
  all over the UI; one user's nginx supporting ranges and another's gateway not
  supporting them cannot both be encoded there. It lives on the session (a
  `WebDavServerCapabilities` value, the shape
  `JellyfinServerCapabilities` already establishes for per-server facts) and
  drives the seek behaviour described in
  [Playback](#playback-resolving-streaming-seeking).
- Step 4 needs a file, so it runs after the first listing finds one, and it is
  skipped (treated as "unknown, assume supported") when the root is empty. The
  probe reuses the one-byte ranged GET pattern `JellyfinClient.probeStream`
  already uses, including its "did I get audio or an HTML login page" check,
  which catches a reverse proxy that intercepts the request.

## Track identity

This is the central decision, and it has a trap in it.

### The shape

```
Track.uri = 'webdav:' + <percent-encoded, server-relative resource path>
Track.id  = <pathDigest>        // short, stable, filename-safe
```

For `…/Music/Bon Iver/For Emma/01 Flume.flac` under a music root of
`/remote.php/dav/files/alice/Music`, the stored `uri` is
`webdav:/Bon%20Iver/For%20Emma/01%20Flume.flac`.

Why this split:

- **The path, not a server id, because there is no server id.** Nextcloud's
  `oc:fileid` is tempting and genuinely stable across renames, but it exists only
  on Nextcloud/ownCloud, and an identity model that changes shape per vendor
  would fragment everything downstream (cache keys, dedupe, diagnostics). The
  path is the one identity every WebDAV server has. `oc:fileid` can later be
  read as an *extra* signal for rename detection without becoming the identity.
- **Relative to the music root, not absolute, and never including the host.**
  That keeps the identity stable when the user's address changes (a new DNS name,
  a LAN IP becoming a tunnel hostname, `http` becoming `https`), which is the
  normal life of a self-hosted server. It also keeps the base URL, the one
  piece of the connection the session owns, out of thousands of catalog rows.
- **No credential, by construction.** Nothing in a path is a secret, the
  userinfo form is rejected at input, and the `Authorization` header is minted
  per request. `Track.uri` therefore satisfies the project's existing invariant
  without any special handling, and `RemoteCacheKey`'s defence-in-depth refusal
  of anything that "looks tokenized" (a query string, a secret marker) passes
  cleanly because a percent-encoded path contains no raw `?` or `&`.
- **A path *is* mildly privacy-sensitive** (file and folder names), which is
  why it is fine in the local database and never fine in a log line, a
  diagnostics report, or a bug report. The local provider already stores real
  filesystem paths in `Track.uri`, so this is established ground, and the
  diagnostics rule below is the same one local scanning follows: report counts
  and error *kinds*, never paths.

### The trap: cache file names

`CacheDownloadRepository` names a cache file from
`'<scheme>_<Track.id>'`, and `FileSystemOfflineFileStore` then replaces every
character outside `[A-Za-z0-9_-]` with `_`. Feed a path-shaped id into that and
two things break at once:

1. **Collisions.** `/a-b/x.mp3` and `/a_b/x.mp3` sanitize to the same name, so
   one track's bytes silently become another's. Cache metadata keys on
   `(sourceType, trackId)`, so the index would disagree with the disk.
2. **Length.** A deep path easily exceeds the 255-byte file-name limit on the
   filesystems Linthra targets, and the write fails at download time rather than
   at design time.

Hence `Track.id` is a **digest**, not the path:

```
pathDigest = first 32 hex chars of sha256(<normalized relative path>)
```

`crypto` is already a direct dependency (Subsonic's token), `sha256` is already
available, 128 bits of digest makes an accidental collision a non-concern, and
the result is short, opaque and filename-safe. The digest is over the
**normalized** path (see [encoding](#url-and-path-encoding)) so two spellings of
the same resource cannot produce two ids.

The path itself stays recoverable from `Track.uri`, so the resolver needs no
digest-to-path lookup table. That is the reason to carry the path in the URI at
all: with a table, the catalog and the table could drift, and a lost table would
strand an entire library. There is no table to lose.

### Stability, renames and re-scans

- **A re-scan of an unchanged library produces identical ids**, so nothing
  churns: favourites, play counts, "added on" dates, pins and cached files all
  survive.
- **A file moved or renamed on the server is a new identity.** That is the same
  trade-off local music makes, and the same safe direction to be wrong in:
  Linthra would rather show a new row than silently transplant one song's
  history onto another. `LocalTrackIdentity`'s tag-anchored matching is the
  existing, conservative answer to recovering history across a move, and it is
  reusable once WebDAV reads real tags (PR 5): it is a pure function over a
  `Track` (duration plus title/artist/album/album-artist/track number, refusing
  to match anything whose metadata came from the path), and
  `LocalCatalogReconciliation` works on `Track.uri` pairs. Both are named
  `Local*` today, so the honest statement is that the *logic* carries over and
  the types would be reused or renamed, not that it is already generic. Before
  tags are available, a move is simply a new track, documented honestly.
- **A deleted file** is pruned on the next scan, exactly as a deleted local file
  is. A *missing* file while the server is merely unreachable must never prune
  anything, which the existing `SourceAvailability` split already guarantees:
  availability hides, it never removes.

## Directory traversal (the library scan)

### The walk

Breadth-first, one `PROPFIND` with `Depth: 1` per directory, with a small
explicit `<D:prop>` request body asking only for what is used:

```
resourcetype, displayname, getcontentlength, getcontenttype,
getlastmodified, getetag
```

Asking for named properties rather than `<D:allprop>` keeps responses small
(Nextcloud's `allprop` is chatty) and keeps parsing honest about what it depends
on. Multi-status (`207`) responses are parsed per `<D:response>`, and a response
whose `<D:propstat>` carries a non-2xx status has its properties ignored rather
than the whole listing failed.

Bounded concurrency of **2 to 4** outstanding `PROPFIND`s: enough to hide
latency on a remote server, few enough that a single-disk NAS is not thrashed.
Configurable in code, not in the UI.

### What is skipped

- **Vendor and system junk**: `@eaDir` (Synology thumbnails, which contain
  files that look like media), `#recycle`, `.Trash*`, `$RECYCLE.BIN`,
  `System Volume Information`, `lost+found`, `.thumbnails`, and any directory
  whose name starts with `.`.
- **Non-audio files**, decided the same way the SAF walk decides: keep a file
  when **either** its extension is known (`audio_file_types.dart` already owns
  that list) **or** the server reported an `audio/*` content type. Servers that
  answer `application/octet-stream` for everything are therefore still usable,
  and a `.flac` mislabelled by a NAS is not dropped.
- **Obvious non-music audio** is *not* guessed at. No duration or size
  heuristics to exclude podcasts or audiobooks; that is the user's folder choice
  to make via the music root.
- **Cycles.** A set of already-visited normalized paths, plus a hard depth cap
  (default 12) and a per-scan ceiling on directories visited. A symlinked loop
  on the server side is otherwise an infinite walk, and WebDAV gives no way to
  detect one.

### Failure handling

Modelled directly on the SAF walk's resilience rule: **one bad entry must never
zero out a library.**

- A directory that answers `403`, `404`, `423 Locked` or a timeout is **skipped
  and counted**, and the scan continues. A user whose server hides one folder
  still gets the rest of their music.
- Only a **total** failure (the root itself unauthorized, or the credential
  rejected) aborts with a typed error, which is also the only case that should
  ever reach the user as a sign-in problem.
- A scan that ends with zero tracks but a non-zero skip count produces a
  different empty state than a genuinely empty folder, because the causes and
  the fixes are different.
- Every scan writes a secret-free `WebDavScanReport` into diagnostics:
  directories visited, audio candidates found, skipped-unsupported, skipped
  directories, read failures, and the last error **kind** (an enum name), never a
  path, URL, header or body. This mirrors `LocalScanReport` exactly.

## URL and path encoding

This is where WebDAV implementations differ most, and where a naive client breaks
on the first album with a `#` in its name. The rules, all of which belong in one
pure, heavily tested `webdav_path.dart`:

- **Encode per segment, never the whole path.** Each path segment is
  percent-encoded individually (so `/` stays a separator) using UTF-8, with the
  RFC 3986 unreserved set left alone. `Uri(pathSegments: …)` does this correctly
  and is preferred over string concatenation.
- **`+` is never a space.** That substitution belongs to form encoding, not to
  paths. A file literally named `a+b.mp3` must round-trip.
- **The characters that actually break things**: space, `#`, `?`, `&`, `%`,
  `;`, `+`, `=`, `'`, `"`, `[`, `]`, and every non-ASCII character (Japanese,
  Cyrillic and accented Latin filenames are completely normal in music
  libraries). `%` is the nastiest, because a file named `100%.mp3` is
  indistinguishable from a bad decode if the code is sloppy about when a string
  is encoded.
- **`href` values in a `207` response are decoded, then resolved.** An `href`
  may be an absolute URL (`https://host/dav/Music/a.mp3`), an absolute path
  (`/dav/Music/a.mp3`), and is sometimes returned already percent-encoded in a
  different form than the request used. The rule: resolve the `href` against the
  request URI, percent-decode it once, strip the base path prefix, and store the
  **decoded** relative path as the canonical form. Re-encode only when building
  a request.
- **A trailing slash marks a collection**, but do not depend on it: use
  `<D:resourcetype><D:collection/>` as the authority and treat the slash as a
  hint. Strip it before storing a directory path so `/a/b` and `/a/b/` are one
  key.
- **Double-encoded `href`s** (a real quirk on a couple of gateways) are detected
  by comparing the decoded `href` against the decoded request path for the
  self-entry that every `Depth: 1` response includes: if the server's own
  self-entry does not match what was requested after one decode, a second decode
  is attempted, and if that still does not match, the listing is skipped and
  counted rather than silently mis-parsed.
- **Normalization for identity** collapses `.`/`..` segments, collapses repeated
  slashes, and removes a trailing slash. It deliberately does **not**
  case-fold: a case-insensitive NAS filesystem means `Song.mp3` and `song.mp3`
  are one file, but a case-sensitive server means they are two, and merging them
  would lose a real track. Case-insensitive servers therefore yield one row per
  spelling the server reports, which is one row, because the server only reports
  one.

## Metadata acquisition

WebDAV hands over a name, a size, a content type, an mtime and an ETag. Turning
that into a library means a tier ladder, and the ladder Linthra already has for
local files is the right one.

### The ladder

1. **Real audio tags** (best) via bounded ranged reads. PR 5, described
   below. Gives title, artist, album, album artist, track number, duration and
   embedded art, which is what makes a library feel like a library.
2. **Path conventions** (v1's workhorse). `…/<Artist>/<Album>/<NN> <Title>.<ext>`
   is close to universal in self-hosted collections, and `LocalTrackMapper`
   already implements exactly this fallback for untagged local files: the
   enclosing folder becomes the album, its parent becomes the artist (both
   measured relative to the scan root, which for WebDAV is the music root), and
   a leading track number is parsed out of the file name and stripped from the
   title (`^(\d{1,3})[\s._\-)\]]+(.+)$`). Worth copying verbatim rather than
   reinventing, including what it deliberately does *not* do: a folder named
   `2011 - Album` yields that whole string as the album name. Stripping a leading
   year is an optional refinement, and a risky one, since album titles
   legitimately start with numbers.
3. **The file name alone**, when there is no usable folder structure: the stem
   becomes the title and the track carries no artist or album, which groups it
   under the usual "Unknown" buckets the library already renders.

The ladder's output is honest about itself: a v1 WebDAV library is
folder-derived, and the doc for users should say so rather than implying tags
were read. `Track.duration` stays `Duration.zero` until tags are read, which is
also the signal `LocalTrackIdentity` uses to refuse to match on path-derived
fields. That is not a coincidence to work around; it is the correct behaviour.

### Ranged tag reads (PR 5)

Downloading whole files to read tags is unacceptable (it is the library, over the
network, twice). The workable approach, in order:

- **Fetch a bounded prefix** of the file with `Range: bytes=0-<N>` where `N` is
  around 256 KB. That covers ID3v2 (front of file), FLAC `STREAMINFO` and Vorbis
  comments (front), and most MP4 files where `moov` precedes `mdat`.
- **Fetch a bounded suffix** only when needed: ID3v1 (last 128 bytes) and the
  common "`moov` at the end" MP4 layout, which is detectable from the box
  structure in the prefix. One extra request, only for files that need it.
- **Parse with the dependency already in the tree.**
  `audio_metadata_reader` (already a direct dependency, used by
  `FilesystemLocalMetadataReader`) parses ID3, Vorbis comments, MP4 atoms, APEv2
  and RIFF INFO from a file. It reads a `File`, so the prefix is written to a
  temporary file in the app's own scratch directory, parsed, and deleted
  immediately. That is deliberately boring: no new dependency, no second tag
  parser to keep correct, and the same tag semantics local music already has.
- **`supportsRanges == false` disables this tier entirely** and the provider
  stays on the path ladder. No full-file downloads as a fallback, ever.
- **Failure is a tier drop, never a failed scan.** An unparseable prefix, a
  truncated response or a weird container yields path-derived metadata, counted
  in the scan report.
- **Cost control**: tag reads run after the walk completes, at low concurrency,
  resumable, and they write progressively through `IncrementalCatalogWriter` so a
  3000-track library fills in visibly instead of after one monolithic pass. A
  track whose ETag and mtime are unchanged since the last scan is skipped
  outright.

### Artwork

Two sources, in order, both resolved at **render time** from a credential-free
reference stored in `Track.artworkUri`:

1. **A folder image** discovered during the walk: `cover.*`, `folder.*`,
   `front.*`, `album.*`, `AlbumArt*.*` (jpg/jpeg/png/webp), case-insensitively,
   in the track's own directory. Cheap, because the walk already lists that
   directory.
2. **Embedded art** from the tag read, written into the same private artwork disk
   cache local music uses. Note that the desktop local reader deliberately asks
   `audio_metadata_reader` for tags only and never for pictures today (see the
   `pubspec.yaml` comment and #408), while Android's embedded art comes from the
   native SAF walk. So a WebDAV implementation should follow whatever local does
   at the time rather than opening this question on its own, and folder images
   carry artwork perfectly well until then.

The stored reference is `webdav-art:<relative path of the image>` for case 1,
following `subsonic-cover:`'s precedent precisely: a dedicated scheme, no
credential, no base URL, and resolution through the live session at render time.
A reference left behind after sign-out simply fails to resolve and the row shows
its placeholder.

**Media-session artwork** (lock screen, Android Auto, Bluetooth) needs the same
treatment Subsonic needed, and for the same reason: the platform session loads
`MediaItem.artUri` in **another process**, where neither the render-time
resolver nor the `Authorization` header can go. So Linthra fetches the image
itself, caches it to a private file named from a hash of the credential-free
reference, and hands the session the existing credential-free `content://` URI
from `MediaArtworkFileProvider`. No new native surface, no new provider
authority, no credential in a URI or a filename.

## Library semantics: folders and tags

The question in #86 is "folders vs tags", and the answer is **both, through two
seams that already exist**, which is also the answer that avoids a second
library architecture.

- **The catalog is the library.** The scan upserts `Track` rows into
  `MusicLibraryRepository` under the `webdav` source id, and every existing
  surface (Library A to Z, albums, artists, search, playlists, queue, downloads,
  smart mixes, the unified-library dedupe) works with no changes whatsoever.
  Grouping uses `albumName` plus `albumArtistName`, because WebDAV has no stable
  album id: `Track.albumId` stays `null`, exactly as it does for local files,
  and `library_grouping.dart` already has that tier.
- **Folder browsing is the optional extra.** `FolderBrowsableMusicSource`
  already exists for precisely this (Jellyfin and Subsonic implement it), it is
  deliberately separate from `MusicSource`, it is non-recursive (one level per
  request), and its `MusicFolder.id` is documented as opaque and
  credential-free. A WebDAV folder id is the same relative path the track URIs
  use. This is PR 7 work, and it gives the "browse my carefully organised
  tree" experience a NAS user expects **without** becoming the primary model.
- **The primary model stays the tag/metadata library**, because that is what the
  rest of the app is built around and what makes a WebDAV library interoperate
  with a Jellyfin one in the unified view. Folder browsing is navigation, not
  storage.
- **Playlists**: `.m3u`/`.m3u8` files found during the walk are a natural
  follow-up (read-only import, resolving relative entries against the playlist's
  own directory, skipping entries that point outside the music root). v1
  declares playlists unsupported so nothing is offered and fails. Writing
  playlists back to the server is out of scope permanently, since it would mean
  writing to the user's files.

## Playback: resolving, streaming, seeking

### The resolver

`WebDavPlayableUriResolver` handles `webdav:` URIs and follows the established
two-step shape:

1. **Verify** the session is still usable through a narrow `WebDavStreamSource`
   seam (the same pattern as `SubsonicStreamSource`: `verifyReachable()`,
   `resolvePlayableUri(track)`, `resolveDownloadUri(track)`), so a dead server
   produces a precise, friendly message instead of an opaque engine failure.
   The check is a `PROPFIND Depth: 0` on the music root, and its result is
   recorded in `ProviderReachability` under the key `webdav` so an album's worth
   of tracks does not each pay a full timeout when the server is away.
2. **Build the absolute URL at play time** from the session's base URL plus the
   track's stored relative path, re-encoded per segment, and attach the
   `Authorization` header. The URL and the header are handed to the engine and
   never stored, logged or placed on the `Track`.

Failures map onto the existing `PlaybackResolutionErrorKind` values with no new
kinds: `notSignedIn`, `sessionExpired` (`401`/`403`), `serverUnreachable`
(timeout, DNS, refused, TLS), `serverReturnedWebPage` (a proxy login page
instead of audio, caught by the probe), `streamUnavailable` (`404`, which for
WebDAV means the file moved or was deleted, so the message should say "rescan"),
and `invalidStream`.

### Headers: the one change to shared playback code

`ResolvedPlayable` currently carries a `Uri` and a `PlaybackSource`, and
`JustAudioPlaybackController` calls `_player.setUrl(resolved.uri.toString())`.
Header-authenticated streaming needs one additive change:

> `ResolvedPlayable` gains an optional `Map<String, String>? headers`, and the
> two `setUrl` call sites pass it through to the optional `headers:` parameter
> `just_audio` exposes on `setUrl` (confirm the shape against the pinned
> version).

That is the minimum viable seam, it is `null` for every existing provider so
nothing else changes behaviour, and it keeps the credential out of the URL. Two
things must be checked during implementation rather than assumed, and both have
a defined fallback:

- **Android/ExoPlayer** supports request headers. Confirm in the pinned
  `just_audio` version whether headers are passed to the data source directly or
  routed through its internal loopback proxy; if a proxy is involved, confirm it
  binds to loopback only, and that the credential stays in memory.
- **Linux/media_kit** (`just_audio_media_kit`) may not forward headers through
  the platform interface. If it does not, Linux WebDAV **streaming** is declared
  unsupported for now (consistent with the Linux target already being documented
  as incomplete) while Linux WebDAV **downloads** still work, since the
  downloader does its own HTTP. The capability model cannot express "streams on
  Android only", so this is documented in [linux-desktop.md](linux-desktop.md)
  and surfaced as a typed, friendly playback error on Linux rather than a silent
  failure.

Putting the credential in the URL as userinfo to dodge all of this is **not** an
option: it would write a secret into a URL, which is the one thing every
provider in this app is built to avoid, and it would hand the secret to every
log sink the engine has.

### Range requests and seek

- **With ranges** (the normal case), seeking works exactly as it does for any
  HTTP stream: the engine issues a ranged request for the new offset. Nothing
  provider-specific is needed.
- **Seeking needs a known duration**, and v1 has none (no tags, so
  `Duration.zero`). The engine derives duration from the container once it has
  read enough, so a streamed track does become seekable in practice, but the
  library row will show no duration until tags are read. That is a visible v1
  limitation worth stating in the user-facing doc, and it is the strongest
  argument for doing the tag-read step sooner rather than later.
- **Without ranges** (`supportsRanges == false`): the engine cannot seek
  mid-stream, and a seek attempt may restart the track from the beginning. The
  response is honesty plus a workaround, not a silent failure:
  the WebDAV settings card shows a note ("your server does not support range
  requests, so seeking inside a streamed track may restart it; download a track
  for full seek support"), the diagnostics report records
  `webdav: server does not support range requests`, and a downloaded copy seeks
  perfectly because it is a local file. No new capability flag is invented for a
  per-server fact.
- **Mis-reported ranges** (a `206` with a nonsense `Content-Range`, or a `200`
  when a range was asked for) are treated as "no range support" for that server
  rather than trusted, because trusting them produces corrupt playback that looks
  like a decoder bug.

### What is reused unchanged

Stream preloading, the remote prebuffer cache, the one-retry mid-stream
recovery, the offline-first resolver, the playback-failure model and its
recovery actions are all provider-neutral and need nothing new. `RemoteCacheKey`
gains `webdav` in its `remoteSchemes` set; that is the whole integration.

## Offline downloads and cache behaviour

Nothing about the offline cache changes. `WebDavTrackDownloader` implements the
existing `RemoteTrackDownloader` seam and inherits the entire policy:
user-initiated only, Wi-Fi by default with the explicit mobile-data opt-in, the
size limit, the eviction order (pre-cached first, then least-recently-played
unpinned, never a pinned track, never the playing track), "Download all" for one
album or playlist, and no whole-library button.

WebDAV specifics:

- **The URL and header are minted at fetch time** inside the downloader, from the
  live session read through a getter so signing in or out is picked up without a
  rebuild. They never leave `fetch()`.
- **Transport errors are replaced, not rethrown.** Subsonic does this because a
  `ClientException` can carry the credentialed URL. For WebDAV the URL is not
  credentialed, but the same discipline applies: a generic
  `StateError('Download failed.')` so a server path never reaches a UI string or
  a log, and a `SocketException` cannot echo anything unexpected.
- **The file extension comes from the content type first, then the path.** Many
  WebDAV servers answer `application/octet-stream` for everything, so
  `AudioFileExtension.forContentType` returns `null` and the cache file would be
  extensionless. The downloader therefore falls back to the extension already
  present in the track's stored path. That is a per-downloader detail; the shared
  helper is not changed, and since the extension is only a convenience (the
  engine sniffs the container), a wrong guess is harmless.
- **Cache naming and keying** use `Track.id` (the digest) and the `webdav`
  scheme, so the
  `(sourceType, trackId)` cache key stays collision-free against every other
  provider, and the file name stays short and safe. See
  [the trap](#the-trap-cache-file-names).
- **Progress reporting** carries byte counts only, which is already the seam's
  contract.
- **Pre-cache (`SmartPrecacheService`)** works unchanged, and is actually more
  valuable here than elsewhere: a slow NAS benefits most from having the next few
  tracks already on disk.
- **A downloaded WebDAV track plays offline and seeks perfectly**, and the
  "Playing from offline copy" badge already says so.

## Reconnect and failure behaviour

All of this is existing machinery; WebDAV just has to participate correctly.

- **Configured is not reachable.** The source reports a `SourceAvailability`
  (`notConfigured` / `checking` / `available` / `unreachable` /
  `authenticationError`) from a cheap probe at startup, on resume, and on the
  periodic re-probe while the app is on screen. A LAN NAS is unreachable the
  moment the phone leaves the house, and that must hide tracks, never delete
  anything.
- **Nothing is ever destroyed by unreachability.** Catalog rows, playlists,
  favourites, downloads and the session all stay exactly as they were, and the
  library returns on its own when the server answers. This is the rule that makes
  a NAS provider pleasant rather than infuriating.
- **The probe is `PROPFIND` with `Depth: 0`** on the music root: one small
  request, authenticated, that distinguishes "cannot reach" from "credential
  rejected" (which is the difference between "get closer to your NAS" and "sign
  in again").
- **Timeouts are split by purpose.** A spinning-up NAS can take a long time to
  answer the first request, so: scan requests get a generous timeout (30 to 60
  seconds), the reachability probe gets a short one (around 10 seconds, because
  its job is to answer quickly and be wrong in the recoverable direction), and
  the download gets the existing long one. A slow first byte must not be
  classified as an outage.
- **`ProviderReachability`** under the key `webdav` absorbs a burst of failing
  tracks so an album does not pay one timeout per song.
- **Sign-out** removes the session and the WebDAV catalog rows, because without a
  session a `webdav:` track can never resolve again. Reconnecting to the same
  base URL and music root re-scans into the same ids, so favourites, pins and
  downloads line up again. (Plex already set this precedent, including keeping
  the selection for the same server and starting clean for a different one.)
- **A credential rejected mid-session** surfaces as `sessionExpired` with a
  "sign in again" action, which for WebDAV usually means a revoked app password.
  The message should hint at that, since it is the common cause.

## Duplicates and collisions

Four distinct cases, three of which are already solved:

1. **The same song twice in the WebDAV tree** (a FLAC and an MP3 copy, or a
   compilation duplicate). Two files are two tracks, and they stay two rows: the
   unifier never merges two rows from the *same* provider, by design, since one
   source is assumed already de-duplicated. v1 accepts this; it is what a
   file-based library genuinely contains.
2. **The same song on WebDAV and on another provider.** Exactly what the unified
   library is for: `unifyTracks` collapses them into one displayed row with both
   copies as ordered playback candidates, and the source-preference rules pick
   which plays. This needs tags to match on (`canMatchAcrossProviders` requires
   real metadata), so it works properly from PR 5 onward and degrades safely
   before then: an untagged WebDAV track is simply its own logical track, never a
   wrong merge.
3. **Two ids colliding.** Prevented by construction: a 128-bit digest over a
   normalized path, with normalization defined so one resource has one spelling.
4. **Two *different* providers sharing an id.** Already handled everywhere,
   because identity is the provider-namespaced URI and cache keys are
   `(sourceType, trackId)` pairs.

## Large libraries and slow NAS

A 20,000-file share on a sleepy two-bay NAS over Wi-Fi is the realistic worst
case, and it is the case that decides whether this provider is usable.

- **Progressive writes.** The scan writes in chunks through the existing
  `IncrementalCatalogWriter` capability and refreshes after the first chunk, so
  the library fills as it goes rather than appearing after ten minutes.
- **Off-isolate XML parsing.** A `207` body for a large directory is the heaviest
  synchronous step, so parsing above a size threshold runs on a background
  isolate via `compute`, exactly as `HttpPlexClient` does for large JSON. Small
  listings stay inline.
- **Skip unchanged.** Per-resource ETag and mtime, plus a credential-free content
  signature of the whole last successful scan, let an unchanged library skip the
  catalog rebuild entirely. Nextcloud's `oc:fileid` sharpens this where present.
- **Resumable and cancellable.** The walk holds a queue of pending directories;
  cancelling is immediate and partial results already written stay valid. A
  failed scan can resume rather than restart.
- **Bounded concurrency and no `Depth: infinity`**, as above.
- **The scan is never automatic and never silent.** It is a user action (or the
  post-sign-in first sync every provider does), it reports progress, and it never
  runs on mobile data without the same respect for the user's connection the
  download policy already encodes.

## Credential-safe logs, diagnostics and persistence

The invariant list, stated the way [providers.md](providers.md) states it for the
other providers, with the two WebDAV-specific entries called out:

Linthra must:

- never store a WebDAV password or HA1 outside `flutter_secure_storage`;
- never put a credential in a URL, including userinfo form, and reject a pasted
  URL that contains one;
- **never log a request's headers**, and never place a header map in an
  exception, a diagnostics line or an error surfaced to the UI (this is the
  WebDAV analogue of the other providers' "never log the tokenized URL", and it
  is the one genuinely new leak surface);
- never store an authenticated URL in `Track.uri`, `Track.artworkUri`, the
  database, the remote-cache index, a backup, or a cache file name;
- **never log a server path, an `href`, a `PROPFIND` request or response body, or
  a file name**, because those are the user's private library contents even
  though they are not credentials. Diagnostics carry counts, error kinds, and the
  host at most;
- never surface a credential, a credentialed URL, or a server path in a UI error
  message;
- resolve stream/download URLs only at play/download time, and artwork URLs only
  at render time, and discard them;
- redact the secret in `WebDavSession.toString()`;
- keep the sign-in controller's state free of the secret once the call returns.

The existing `pr-security-guard` workflow will flag a PR that touches auth or
network code, which is correct and expected for PRs 2 and 4.

## Capability model

### Proposed `MusicProviderCapabilities` for `webdav`

| Capability | v1 | Eventual | Why |
| --- | :---: | :---: | --- |
| `canStream` | ✅ | ✅ | A ranged `GET` with an `Authorization` header, minted at play time. |
| `canCache` | ❌ | ✅ (PR 6) | The shared offline cache needs only a `RemoteTrackDownloader`. Off until it exists so the action is hidden rather than failing. |
| `canFavoriteTracks` | ✅ | ✅ | **The interesting one.** WebDAV is the first *remote* provider with *local* favourites: there is no server-side like state, so hearts are stored on-device exactly as they are for local music. |
| `canReadFavoriteState` | ✅ | ✅ | Read from the on-device store. |
| `canSyncFavorites` | ❌ | ❌ | There is no server state to mirror, ever. |
| `canListPlaylists` | ❌ | 🔜 | `.m3u` import is a plausible follow-up. |
| `canCreatePlaylist` | ❌ | ❌ | Would mean writing to the user's files. Out of scope permanently. |
| `canEditPlaylist` | ❌ | ❌ | Same. |
| `canDeletePlaylist` | ❌ | ❌ | Same. |
| `canSyncPlaylists` | ❌ | ❌ | Same. |
| `canLyrics` | ❌ | ✅ (PR 5) | Sidecar `.lrc`/`.txt` beside the audio file, which local music already supports and which a WebDAV walk can see. |
| `canCast` | ❌ | ❌ | **Permanent, and principled.** A Cast receiver fetches the URL itself and cannot send an `Authorization` header, so casting would require a credential in the URL. Linthra will not mint one. |
| `canRemoveFromLibrary` | ✅ | ✅ | Safe and reversible, true for every provider. |
| `canRemoveOfflineCopy` | ❌ | ✅ (PR 6) | Follows `canCache`. |
| `canDeleteLocalFile` | ❌ | ❌ | Not an on-device file. |
| `canDeleteRemoteItem` | ❌ | ❌ | Read-only provider. Linthra never writes to a WebDAV server. |

Note how much of this is "already expressible". The capability model needs **no
new fields** for WebDAV, which is a good sign that the seam was the right shape.
The only thing it cannot express is a per-server runtime fact
(`supportsRanges`), and that correctly lives on the session instead.

### Capability comparison across providers

| Capability | Local | Jellyfin | Subsonic / Navidrome | Plex | **WebDAV (v1)** | **WebDAV (eventual)** |
| --- | :---: | :---: | :---: | :---: | :---: | :---: |
| `canStream` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `canCache` | n/a | ✅ | ✅ | ✅ | ❌ | ✅ |
| `canFavoriteTracks` | ✅ local | ✅ synced | ✅ synced | ❌ | ✅ local | ✅ local |
| `canReadFavoriteState` | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ |
| `canSyncFavorites` | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| `canListPlaylists` | ❌ | ✅ | ✅ | ❌ | ❌ | 🔜 `.m3u` |
| `canCreatePlaylist` | ✅ local | ✅ | ✅ | ❌ | ❌ | ❌ |
| `canSyncPlaylists` | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| `canLyrics` | ✅ sidecar | ✅ | ✅ | ✅ | ❌ | ✅ sidecar |
| `canCast` | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| `canDeleteRemoteItem` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |

And the properties that are not capability flags but do differ, which is where
WebDAV is genuinely unlike the other three:

| Property | Local | Jellyfin | Subsonic | Plex | WebDAV |
| --- | --- | --- | --- | --- | --- |
| Item identity | file path | server id | server id | `ratingKey` | **path digest** (no server id exists) |
| Credential location | none | header | **URL query** | **URL query** | **header** |
| Password persisted? | n/a | no (token) | no (salt+token) | no (token) | **yes (app password), or HA1 with Digest** |
| Metadata source | file tags | server DB | server DB | server DB | **path, then ranged tag reads** |
| Album grouping | name + artist | `albumId` | `albumId` | `albumId` | **name + album artist** |
| Stable across rename? | no (tag match) | yes | yes | yes | **no** (tag match, once tags land) |
| Range/seek reliability | n/a | reliable | reliable | reliable | **server-dependent, probed** |
| Incremental sync signal | mtime | API | API | API | **ETag + mtime per file** |

The two rows worth a reviewer's attention are **"password persisted"** (the one
place WebDAV is weaker than every existing provider, mitigated by app passwords,
Digest/HA1 later, and secure storage) and **"credential location"** (the one
place it is *stronger*, since no secret ever enters a URL).

## Shared-code touch points

The complete list, so a reviewer can see the blast radius is small and additive.
Nothing here changes behaviour for an existing provider.

| File | Change |
| --- | --- |
| `lib/core/sources/music_provider.dart` | Add `MusicProviders.webdav` with the capability set above; register `webdav:` in `forTrackUri` and in `bareRemoteIdForTrackUri`'s scheme list. |
| `lib/core/services/playable_uri_resolver.dart` | Add the optional `headers` field to `ResolvedPlayable`. No new error kinds. |
| `lib/core/services/just_audio_playback_controller.dart` | Pass `resolved.headers` to the two `setUrl` calls. |
| `lib/core/services/remote_cache/remote_cache_key.dart` | Add `sourceIdWebdav` and include it in `remoteSchemes`. |
| `lib/core/services/playback_source_label.dart` | Add the `webdav` case so the "Playing from" badge is honest. |
| `lib/core/catalog/source_capability.dart` | Add `SourceProviderType.webdav` with a fixed, non-identifying display name, and its `sourceId` mapping. |
| `lib/features/player/player_providers.dart` | Add the resolver to the remote source router and the downloader to the routing downloader (PR 6). |
| `lib/core/services/lyrics_resolver.dart` wiring | Register `WebDavLyricsProvider` for `webdav:` tracks (PR 5); until then the existing `NoLyricsProvider` placeholder pattern applies. |
| Artwork resolution wiring | Recognize `webdav-art:` at render time alongside `subsonic-cover:` and `plex-thumb:` (PR 5). |
| `lib/features/settings/` | A new `webdav/` settings section, registered in the settings hub. |
| `docs/providers.md`, `docs/README.md`, `README.md` | Provider matrix row, docs index entry, feature table row. |
| `pubspec.yaml` | Only if the XML decision below goes that way, in the PR that needs it. |

### The one dependency question

`PROPFIND` returns XML. Two options, decided by the PR that needs it rather
than by this doc:

1. **Declare `xml` directly.** It is already in the tree as a transitive
   dependency (`xml 6.5.0` in `pubspec.lock`), MIT licensed, pure Dart, and the
   repository already has the pattern of declaring a direct dependency on a
   package it already pulled in transitively (`dbus`, `audio_session`,
   `media_kit`) with a comment explaining the single call site. This is the
   recommendation: WebDAV XML is namespaced and real servers are inconsistent
   about prefixes, which is exactly the kind of thing a hand-rolled parser gets
   wrong in production and not in tests.
2. **A narrow hand-rolled `207` parser.** No new manifest entry, but a real
   correctness risk around namespace prefixes (`D:`, `d:`, `lp1:`, default
   namespaces), entity handling and malformed bodies.

Either way the parse lives behind one seam with its own tests, and
[dependency-license-audit.md](dependency-license-audit.md) is updated in the same
PR if a declaration is added. Nothing is added for experimentation, and nothing
is added by this design PR.

## Proposed file layout

Mirrors the Jellyfin/Subsonic/Plex shape, which is the shape
[codebase-tour.md](codebase-tour.md) explicitly tells a WebDAV contributor to
copy.

```
lib/core/sources/webdav/
  webdav_path.dart             # pure: per-segment encode/decode, normalize, href resolve
  webdav_api.dart              # DTOs: WebDavResource (path, isCollection, size,
                               #   contentType, mtime, etag)
  webdav_propfind_parser.dart  # 207 multistatus -> List<WebDavResource>
  webdav_endpoints.dart        # pure URL builders (base + relative path)
  webdav_auth.dart             # Basic header construction; HA1 later. No logging.
  webdav_client.dart           # interface: options/propfind/get/getRange
  http_webdav_client.dart      # package:http (+ IOClient for cert pinning)
  webdav_exception.dart        # typed, secret-free failures + kinds
  webdav_server_url.dart       # normalize via ServerUrlNormalizer, reject userinfo
  webdav_server_capabilities.dart  # DAV classes, Allow, supportsRanges
  webdav_authenticator.dart    # connect + verify + capability probe
  webdav_track_identity.dart   # path -> digest; the one place ids are made
  webdav_track_mapper.dart     # resource -> Track (path ladder), webdav: scheme
  webdav_library_scanner.dart  # the bounded, resumable Depth:1 walk
  webdav_scan_report.dart      # secret-free diagnostics counters
  webdav_music_source.dart     # implements MusicSource (+ WebDavStreamSource)
  webdav_stream_source.dart    # narrow verify/resolve seam
  webdav_playable_uri_resolver.dart
  webdav_track_downloader.dart # PR 6
  webdav_artwork.dart          # webdav-art: reference + render-time resolve
  webdav_folder_browser_source.dart  # PR 7
lib/core/models/webdav_session.dart
lib/core/repositories/webdav_session_store.dart
lib/data/repositories/secure_webdav_session_store.dart
lib/data/repositories/in_memory_webdav_session_store.dart
lib/features/settings/webdav/   # section + controller + state + providers
docs/webdav.md                  # this document
```

## Tests to add

Hand-written `Fake*` clients (no mocking library) and Riverpod overrides, the way
every existing provider's tests are written.

**Pure units (the bulk of the value, and no server needed):**

- `webdav_path_test.dart`: per-segment encoding, spaces, `#`, `?`, `%`, `+`
  (never a space), non-ASCII, `href` resolution from absolute URL and absolute
  path forms, double-encoded `href` detection, trailing-slash handling,
  `.`/`..` collapsing, and the explicit assertion that normalization does **not**
  case-fold.
- `webdav_propfind_parser_test.dart`: real captured bodies from Apache,
  nginx+dav_ext, Nextcloud and a Synology-shaped response; namespace prefix
  variants (`D:`, `d:`, default, `lp1:`); per-`propstat` failure statuses
  ignored rather than failing the listing; malformed XML yields a typed error;
  a collection with zero children.
- `webdav_track_identity_test.dart`: the same path yields the same digest; two
  paths differing only by a character that file-name sanitization would collapse
  (`a-b` vs `a_b`) yield **different** digests; the digest is filename-safe and
  length-bounded.
- `webdav_track_mapper_test.dart`: the path ladder
  (`Artist/Album/NN Title.ext`, `Artist/Year - Album/…`, bare file name), the
  `webdav:` scheme, `albumId` left null, `duration` left zero, and the
  `webdav-art:` reference.
- `webdav_server_url_test.dart`: userinfo **rejected**, deep path preserved,
  bare host defaults to https, explicit http preserved, IPv6 literal, port,
  trailing slashes.
- `webdav_server_capabilities_test.dart`: `DAV:` class parsing, `Allow:` based
  read-only detection, range probe outcomes (`206` good, `206` with bad
  `Content-Range`, `200` on a ranged request) all classified correctly.

**Client and source:**

- `http_webdav_client_test.dart`: `PROPFIND` body and `Depth` header shape,
  `401`/`403`/`404`/`423`/`5xx` mapping, TLS and cleartext classification, the
  **redirect rules** (same-origin followed, cross-origin refused, no
  `Authorization` on a refused hop, chain capped), and a sweep asserting no
  exception message contains the credential, the header, or a `Basic ` value.
- `webdav_authenticator_test.dart`: connect success, wrong credential, not a DAV
  server, music root missing, Digest-only challenge producing its specific
  message.
- `webdav_library_scanner_test.dart`: breadth-first walk, junk directories
  skipped, a `403` subtree skipped and counted while the rest still scans, cycle
  and depth caps, cancellation, progressive writes, and the scan report's
  counters.
- `webdav_music_source_test.dart` and `webdav_playable_uri_resolver_test.dart`:
  every failure kind mapped, the URL built at play time only, the header present
  in the resolved playable and **absent** from everything persisted.
- `webdav_track_downloader_test.dart` (PR 6): progress, extension from
  content type then from the path, transport error replaced with a generic
  message.
- `secure_webdav_session_store_test.dart` and the in-memory twin: round trip,
  partial/corrupt record treated as "not signed in", and `toString` redaction.

**Guards (the ones that stop a regression years later):**

- A capability-matrix test pinning the `webdav` row exactly as documented above.
- A routing guard that `MusicProviders.forTrackUri` still routes `jellyfin:`,
  `subsonic:`, `plex:` and local URIs unchanged.
- A `ResolvedPlayable.headers` test proving it is `null` for every existing
  provider, so nothing else changed.
- A credential sweep over every new user-visible string and diagnostics line.
- A cache-key test proving a `webdav` track and a same-digest track from another
  provider cannot share a cache slot.
- A **certificate-pinning test**: a pinned fingerprint accepts only that exact
  certificate; a different certificate on the same host is refused; pinning one
  server does not affect requests to any other host.

Integration/UI (PR 7): settings sign-in flow states, the self-signed
confirmation dialog, the library appearing after a scan, the no-range note, and
a sign-out that removes rows and session.

## Suggested PR split

Each step is independently reviewable, independently useful, and leaves the app
in a shippable state.

1. **Design doc** (this PR). Docs only. No code, no dependency, no wiring.
2. **Connection and auth.** `webdav_path.dart`, `webdav_server_url.dart`,
   `webdav_auth.dart`, `webdav_api.dart`, `webdav_propfind_parser.dart`,
   `webdav_client.dart` + `http_webdav_client.dart` (including the redirect
   rules), `webdav_exception.dart`, `webdav_server_capabilities.dart`,
   `webdav_authenticator.dart`, `WebDavSession` + secure and in-memory stores,
   and the settings section with connect/disconnect. Includes the self-signed
   pinning flow. No catalog, no playback. This is the security-heavy PR and
   deserves the most review attention.
3. **Directory and library scan.** `webdav_track_identity.dart`,
   `webdav_track_mapper.dart`, `webdav_library_scanner.dart`,
   `webdav_scan_report.dart`, `webdav_music_source.dart`, registration of
   `webdav:` in `MusicProviders` with `canStream` still **off** (so the rows are
   visible but not yet playable, and the streaming action stays hidden rather
   than offered and failing, exactly how Subsonic grew), the scan action in
   settings, progressive writes, and diagnostics.
4. **Playback resolver.** `webdav_stream_source.dart`,
   `webdav_playable_uri_resolver.dart`, the additive `ResolvedPlayable.headers`
   and its two call sites, `RemoteCacheKey` and `PlaybackSourceLabel` and
   `SourceProviderType` registration, reachability/availability wiring, the range
   probe feeding the no-range note, and flipping `canStream` on. Confirms the
   Android header path and settles the Linux question.
5. **Artwork and metadata.** Folder-image discovery, `webdav-art:` references and
   render-time resolution, the media-session artwork path, ranged tag reads with
   the temp-file parse, real durations, sidecar `.lrc`/`.txt` lyrics and
   `canLyrics`, ETag/mtime skip-unchanged, and the unified-library merge that
   real tags unlock.
6. **Offline downloads.** `webdav_track_downloader.dart`, routing-downloader
   registration, `canCache` and `canRemoveOfflineCopy` on, extension fallback,
   and the download/pre-cache tests.
7. **Folder browsing, UI polish and integration tests.**
   `webdav_folder_browser_source.dart` behind the existing
   `FolderBrowsableMusicSource` seam, the settings card's full state set
   (connected, unreachable, auth error, pinned certificate, no-range note),
   empty and error states for the scan, the manual-test checklist entries, and
   the end-to-end widget tests.

Natural follow-ups after that, each its own issue: Digest auth with the HA1-only
rule, `.m3u` playlist import, `oc:fileid` rename tracking on Nextcloud, and
multiple WebDAV servers at once (which the session model should not actively
prevent, but which is a wider change across every provider, since today each
provider holds one session).

## Open questions and risks

Honest list. None of these blocks starting; each has a defined fallback.

| Risk | Impact | Mitigation / fallback |
| --- | --- | --- |
| **`just_audio` header support on Android** is assumed, including whether it routes through an internal loopback proxy. | Streaming does not work, or the credential takes an unexpected path. | Verified in PR 4 before `canStream` flips on. If headers are proxied, confirm loopback-only binding and document it. There is no fallback that keeps the credential out of the URL, so this is a genuine gate. |
| **`just_audio_media_kit` (Linux) may not forward headers.** | No WebDAV streaming on Linux. | Declare it unsupported there for now (Linux is already documented as incomplete), keep downloads working, surface a typed friendly error. Fix upstream or in the adapter later. |
| **Storing a replayable password** is weaker than every other provider. | A compromised device yields a working credential. | App passwords by preference and by UI nudge, a documented read-only user, Digest/HA1 as a follow-up, secure storage, and no credential in any URL. Stated plainly in the user docs rather than hidden. |
| **Self-signed pinning is new security-sensitive code.** | A bug here could weaken TLS. | Scoped to one client instance for one host, exact fingerprint match only, fails closed on any change, covered by the pinning tests above, and reviewed as its own PR (PR 2). |
| **v1 has no durations and no real tags**, so the library looks thinner than a Jellyfin one. | Weak first impression; no cross-provider dedupe yet. | PR 5 is the fix and should follow quickly. Consider shipping PRs 2 to 4 behind a settings flag until PR 5 lands if the first impression matters more than early feedback. |
| **Large-library scan cost** over a slow link. | Long first sync. | Progressive writes, off-isolate parse, skip-unchanged, bounded concurrency, cancellable and resumable. Measure against a 20k-file fixture before PR 3 is called done. |
| **Server quirk variety** is the long tail (double-encoded `href`s, `Depth` refusals, mis-reported ranges, `octet-stream` for everything). | Works for the author, breaks for a user. | Capture real response bodies from each target family as test fixtures, which is cheap and is what makes the parser trustworthy. A compatibility page like [jellyfin-compatibility.md](jellyfin-compatibility.md) should grow from real reports. |
| **Cast stays off permanently.** | A user with a Chromecast cannot cast their NAS music. | Correct and intentional: casting would require a credential in a URL. Documented as a deliberate non-goal, with "download it, then cast from a provider that supports it" as the honest answer. |

## Notes

- Everything above reuses an existing seam. The only shared-code additions are
  one provider registration, one optional field on `ResolvedPlayable`, and three
  small registry entries. If an implementation finds itself wanting a second
  library, a parallel cache, a new storage layer, or a credential in a URL, that
  is the signal to stop and revisit this document.
- The closest existing reference while implementing is the pair
  `lib/core/sources/local/` (for the walk, the metadata ladder, the sidecars and
  the identity reasoning) and `lib/core/sources/subsonic/` (for the client,
  session, secret discipline and the render-time artwork reference).
