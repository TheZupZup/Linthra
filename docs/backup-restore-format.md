# Linthra Backup / Restore — file format (V1)

This is the documented format for **Linthra Backup** and **Linthra Restore**
(Phase 2 of the [product roadmap](./roadmap.md)). It lets a user move their
Linthra **setup** — which servers they use and how they like the app — to a new
phone, with **no Docker, no account, and no cloud**.

The format is deliberately small, human-readable, and versioned, because it is the
shared contract between three things:

- **Android** exports and imports it (Phase 2, V1).
- **Linthra Desktop** (Phase 4) reads and writes the *same* document.
- **Linthra Connect** (Phase 3) is just an *optional* transport for it — the
  pairing/QR flow moves this exact file between devices; nothing about the format
  depends on Connect existing.

> **Status:** this is a **design spec**, written before the feature so it can be
> built in small, reviewable PRs. No exporter/importer ships yet.

## Principles

- **Settings, not secrets.** V1 backs up your *setup* (servers, preferences). It
  **never** contains passwords or tokens — see [Security](#security).
- **Settings, not your library.** Favorites, playlists, play history, and the
  offline cache are **data**, not setup. They are out of scope for V1 (see
  [Out of scope](#out-of-scope-for-v1)).
- **One file, no infrastructure.** A backup is a single UTF-8 JSON file you can
  move any way you like — Android share sheet, Downloads folder, USB, or (later)
  Linthra Connect. No server, no account, no internet required.
- **Forward-compatible.** A newer Linthra can add fields and server types without
  breaking an older reader; an older reader skips what it doesn't understand. See
  [Versioning](#versioning--forward-compatibility).
- **Same rules as the rest of the app.** Credentials stay encrypted on-device and
  are never written to a plaintext sink — exactly as documented for each provider
  in [docs/providers.md](./providers.md).

## Security

V1 takes the simplest safe position: **the backup contains no credentials at
all.**

- **Never exported:** the Jellyfin `accessToken`, the Subsonic `salt` + `token`
  pair, and the Plex `X-Plex-Token`. These live in `flutter_secure_storage`
  (Android Keystore-backed) and the exporter must never read them into the file.
- **After restore, re-authenticate.** Each restored server appears in Settings in
  a *needs-sign-in* state; the user re-enters the password (Jellyfin/Subsonic) or
  pastes a token (Plex) once. This mirrors how Linthra already treats a password:
  used once to derive a token, then discarded.
- **Not secret, but not public either.** The file *does* list your **server URLs
  and usernames**. That reveals where your private server lives — so treat a
  backup like a list of bookmarks to a private service: fine to keep and move
  around, not something to post publicly. Because there are no passwords/tokens in
  it, V1 needs no encryption.
- **Encrypted credential backup is a separate, later, opt-in design.** If we ever
  let users include credentials (so a restore needs no re-typing), that is its own
  feature with its own threat model and explicit user consent — never the default,
  and never in V1.

## File shape

- **Encoding:** UTF-8 JSON, pretty-printed (human-inspectable on purpose).
- **Suggested name:** `linthra-backup-YYYY-MM-DD.json`.
- **Extension / MIME:** `.json`, `application/json`, for maximum
  interoperability (Desktop, text editors, inspection). A backup is identified by
  its **content** — the `linthraBackup` envelope and `formatVersion` — not by its
  filename, so a renamed file still restores.

### Envelope

```json
{
  "linthraBackup": {
    "formatVersion": 1,
    "kind": "settings",
    "generatedBy": { "app": "Linthra Android", "appVersion": "0.1.7" },
    "createdAt": "2026-06-24T12:00:00Z",
    "servers": [],
    "preferences": {}
  }
}
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `linthraBackup` | object | yes | Top-level marker; its presence identifies the file. |
| `formatVersion` | integer | yes | Format version. V1 = `1`. See [Versioning](#versioning--forward-compatibility). |
| `kind` | string | yes | `"settings"` in V1. Reserved so a future `"settings+credentials"` or `"library"` kind can be distinguished. |
| `generatedBy` | object | no | Diagnostics only: `app` (e.g. `"Linthra Android"` / `"Linthra Desktop"`) and `appVersion`. Readers must not depend on it. |
| `createdAt` | string | no | ISO-8601 UTC timestamp the backup was written. Display only. |
| `servers` | array | yes | The configured sources — see [Servers](#servers). May be empty. |
| `preferences` | object | yes | App/playback/cache/source preferences — see [Preferences](#preferences). May be empty. |

### Servers

Each entry is tagged by `type`. Common fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `type` | string | `"jellyfin"`, `"subsonic"`, `"plex"`, or `"local"`. |
| `displayName` | string | The human label Linthra shows for this source. Today it's derived from the server's reported name (falling back to the URL host); a future user-editable label uses the same field. |

Per-type fields (**all non-secret** — credentials are excluded by design):

**`jellyfin`**

| Field | Type | Meaning |
| --- | --- | --- |
| `baseUrl` | string | Server base URL, no trailing slash (e.g. `https://music.example.com`). |
| `username` | string | Sign-in name, to pre-fill the login form on restore. |

**`subsonic`** (Navidrome and other Subsonic-compatible servers)

| Field | Type | Meaning |
| --- | --- | --- |
| `baseUrl` | string | Server base URL, no trailing slash. |
| `username` | string | Sign-in name, to pre-fill the login form. |
| `serverType` | string? | OpenSubsonic server product (e.g. `navidrome`), if known. Informational. |

**`plex`**

| Field | Type | Meaning |
| --- | --- | --- |
| `baseUrl` | string | Server base URL incl. port (e.g. `https://plex.example.com:32400`). |
| `selectedSectionKeys` | string[] | The music-library section keys the user chose to include — a genuine user choice worth restoring. |

**`local`** (on-device folder)

| Field | Type | Meaning |
| --- | --- | --- |
| `folderHint` | string? | The Android SAF tree URI of the previously chosen folder, **informational only**. The SAF permission grant does **not** transfer to another device (or survive a reinstall), so on restore Linthra shows this as a hint and asks the user to re-pick the folder to re-grant access. Desktop ignores it. |

> **Excluded on purpose** (non-secret but device- or session-specific, re-derived
> at re-auth): Jellyfin `deviceId` / `userId` / `serverId`, Plex
> `machineIdentifier` / `clientIdentifier`, and every server's version strings are
> **not** part of a backup. They are re-established when the user signs back in, so
> carrying them would only risk one device impersonating another.

### Preferences

All values below are non-secret user choices read from `shared_preferences`.

```json
"preferences": {
  "defaultProvider": "jellyfin",
  "preferredSourceOrder": ["local", "jellyfin", "subsonic"],
  "playbackSourceStrategy": "preferLocalCache",
  "cache": {
    "maxBytes": 5368709120,
    "allowMobileData": false,
    "smartPrecacheEnabled": true,
    "precacheCount": 3
  },
  "playback": { "normalizeVolume": false },
  "appearance": { "appIconVariant": "classic" }
}
```

| Field | Type | Meaning | Default |
| --- | --- | --- | --- |
| `defaultProvider` | string? | Explicit default source id (`jellyfin` / `subsonic` / `plex` / `local`), or omitted for Automatic. | Automatic |
| `preferredSourceOrder` | string[] | Source ids, most-preferred first — picks which copy of a song shared across providers plays. | empty |
| `playbackSourceStrategy` | string? | Strategy enum name for ordering playback candidates (e.g. `preferLocalCache`), or omitted for the default. | default |
| `cache.maxBytes` | integer | Offline-cache size ceiling, in bytes (LRU eviction above it). | ~5 GiB |
| `cache.allowMobileData` | boolean | Whether downloads / pre-cache may use metered data. | `false` |
| `cache.smartPrecacheEnabled` | boolean | Whether upcoming queued tracks are warmed into the cache. | `true` |
| `cache.precacheCount` | integer | How many upcoming tracks smart pre-cache warms ahead (1–200). | `3` |
| `playback.normalizeVolume` | boolean | Apply ReplayGain (attenuation-only) for even loudness. | `false` |
| `appearance.appIconVariant` | string? | Chosen Linthra logo/branding variant id; cosmetic. | Classic |

A reader applies only the keys present and clamps/validates each to its own
accepted range (e.g. `precacheCount`, `maxBytes`) exactly as the live setting
does — a hand-edited or newer file can never push a setting out of bounds.

## Restore semantics

1. **Validate the envelope.** Reject a file with no `linthraBackup` object, or a
   `formatVersion` newer than the reader supports, with a clear message
   ("This backup was made by a newer version of Linthra"). See
   [Versioning](#versioning--forward-compatibility).
2. **Merge, don't wipe.** Importing **adds** servers and **applies** preferences;
   it does not delete anything already set up. A server already configured —
   matched by (`type`, normalized `baseUrl`) — is left as-is rather than
   duplicated.
3. **Re-authenticate per server.** Restored servers land in a *needs-sign-in*
   state. The user signs in once each; nothing plays until they do.
4. **Skip unknown server types.** A `type` the reader doesn't recognise (e.g. a
   future provider, or `local` on Desktop) is skipped with a notice, not an error.
5. **Apply known preferences, ignore the rest.** Unknown preference keys are
   ignored; known ones are validated/clamped before applying.

## Versioning & forward-compatibility

- `formatVersion` is a single integer. V1 = `1`.
- **Readers must ignore unknown object fields** and unknown `preferences` keys.
- **Readers must reject a higher `formatVersion`** than they support, with a clear
  message — never silently half-import.
- **Within a major `formatVersion`, changes are additive only** (new optional
  fields, new server `type`s). A breaking change bumps `formatVersion`.
- **New server types are forward-compatible:** an older reader (say, an older
  Desktop reading a newer Android backup) skips a `type` it doesn't know and
  imports the rest. That's why each server entry is self-describing.

## Worked example

```json
{
  "linthraBackup": {
    "formatVersion": 1,
    "kind": "settings",
    "generatedBy": { "app": "Linthra Android", "appVersion": "0.1.7" },
    "createdAt": "2026-06-24T12:00:00Z",
    "servers": [
      {
        "type": "jellyfin",
        "displayName": "Home Jellyfin",
        "baseUrl": "https://music.example.com",
        "username": "alice"
      },
      {
        "type": "subsonic",
        "displayName": "Navidrome",
        "baseUrl": "https://nd.example.com",
        "username": "alice",
        "serverType": "navidrome"
      },
      {
        "type": "plex",
        "displayName": "Living-room Plex",
        "baseUrl": "https://plex.example.com:32400",
        "selectedSectionKeys": ["3", "7"]
      },
      {
        "type": "local",
        "displayName": "Phone music folder",
        "folderHint": "content://com.android.externalstorage.documents/tree/primary%3AMusic"
      }
    ],
    "preferences": {
      "defaultProvider": "jellyfin",
      "preferredSourceOrder": ["local", "jellyfin", "subsonic"],
      "playbackSourceStrategy": "preferLocalCache",
      "cache": {
        "maxBytes": 5368709120,
        "allowMobileData": false,
        "smartPrecacheEnabled": true,
        "precacheCount": 3
      },
      "playback": { "normalizeVolume": false },
      "appearance": { "appIconVariant": "classic" }
    }
  }
}
```

## Implementation notes (Android)

Captured so the eventual exporter/importer is built safely; these are the
non-obvious bits.

- **Server config and its secret share one secure-storage blob.** Each provider's
  whole session — non-secret `baseUrl` / `serverName` **and** the secret token —
  is serialized together into `flutter_secure_storage` under a single key
  (`jellyfin_session_v1`, `subsonic_session_v1`, `plex_session_v1`). So the
  exporter **cannot** simply read `shared_preferences`; it must read each session
  via its store and **project out the non-secret subset.**
- **Add a dedicated non-secret projection, don't reuse `toJson()`.** The existing
  `JellyfinSession.toJson()` / `SubsonicSession.toJson()` / `PlexSession.toJson()`
  include the credential on purpose (their only caller is the encrypted store).
  The exporter should use a separate `toBackupJson()` (or a mapper) that omits
  `accessToken` / `salt` / `token` / `deviceId` / `clientIdentifier` /
  `machineIdentifier`, so a future refactor can't accidentally leak a token into a
  plaintext backup. A unit test should assert no backup ever contains those keys.
- **Preferences come from `shared_preferences`.** `default_provider_source_id_v1`,
  `preferred_source_order_v1`, `playback_source_strategy_v1`,
  `selected_app_icon_variant_v1`, `playback_normalize_volume`, and the
  `downloads_*` keys (see the [appendix](#appendix-current-internal-storage-keys)).
- **Export/import via the Storage Access Framework** — the same scoped, no-broad-
  permission approach the local-folder picker already uses. No new storage
  permission.
- **The local folder is the one thing that can't fully restore.** Carry
  `folderHint` for the user's reference, but a SAF permission grant is per-device
  and can't be transferred — restore must prompt a re-pick.

## Desktop interoperability (Phase 4)

Linthra Desktop reads and writes the **same** envelope. Differences are handled by
the forward-compatibility rules, not by a separate format:

- Desktop **skips** `type: "local"` (and ignores `folderHint`) — an Android SAF
  URI is meaningless on Windows; Desktop offers its own folder picker.
- Desktop may **add** server types Android doesn't have yet; an older Android
  reader skips them.
- A backup made on Desktop restores on Android and vice-versa, minus the
  platform-specific entries each side can't use.

This is what lets **Linthra Connect** (Phase 3) stay a thin, optional transport:
it moves this document between devices over a temporary, user-approved local
pairing — it does not define its own data model.

## Out of scope for V1

Deliberately deferred, each its own later design:

- **Credentials.** No passwords/tokens in V1; an *encrypted, opt-in* credential
  backup is a separate feature with its own threat model.
- **Library data.** Favorites, playlists, play history, and the offline cache are
  data, not setup. A future `kind: "library"` (or a second section) can carry them
  without changing this settings format.
- **The QR / pairing transport.** That's Linthra Connect (Phase 3); it will carry
  *this* file, so it needs no format changes here.
- **Multi-device live sync / conflict resolution.** A Phase 5 concern, explicitly
  not a backup-file concern.

## Appendix: current internal storage keys

Implementation detail, for the importer/exporter — **not** part of the file
format, and free to change. The JSON field names above are the stable contract.

| Backup field | Current storage | Key | Type |
| --- | --- | --- | --- |
| `servers[type=jellyfin]` | secure storage | `jellyfin_session_v1` | JSON blob (non-secret subset exported) |
| `servers[type=subsonic]` | secure storage | `subsonic_session_v1` | JSON blob (non-secret subset exported) |
| `servers[type=plex]` | secure storage | `plex_session_v1` | JSON blob (non-secret subset exported) |
| `servers[type=local].folderHint` | shared_preferences | `selected_music_folder` | String |
| `preferences.defaultProvider` | shared_preferences | `default_provider_source_id_v1` | String |
| `preferences.preferredSourceOrder` | shared_preferences | `preferred_source_order_v1` | JSON array (String) |
| `preferences.playbackSourceStrategy` | shared_preferences | `playback_source_strategy_v1` | String |
| `preferences.cache.maxBytes` | shared_preferences | `downloads_max_cache_bytes` | int |
| `preferences.cache.allowMobileData` | shared_preferences | `downloads_allow_mobile_data` | bool |
| `preferences.cache.smartPrecacheEnabled` | shared_preferences | `downloads_preload_enabled` | bool |
| `preferences.cache.precacheCount` | shared_preferences | `downloads_precache_count` | int |
| `preferences.playback.normalizeVolume` | shared_preferences | `playback_normalize_volume` | bool |
| `preferences.appearance.appIconVariant` | shared_preferences | `selected_app_icon_variant_v1` | String |
