# Playlists & safe song removal

This document describes how playlists work in Linthra, how (and how far) they
sync with Jellyfin, and the deliberately-separated model for removing or
deleting songs. The guiding principle throughout is safety: **"remove from
Linthra" and "delete from your source/server/device" are different actions, and
Linthra never silently destroys your real music files or server items.**

## Playlists

A playlist is a user-authored, ordered collection of tracks. Each playlist
stores stable Linthra track ids (for Jellyfin tracks these are the Jellyfin item
ids), not copies of the tracks, so membership and order survive a library
re-scan.

What you can do:

- **Create** a playlist (Playlists tab → "New playlist"). A name is required; a
  description is optional.
- **Rename** / re-describe a playlist (overflow menu on the row, or the playlist
  detail screen).
- **Delete** a playlist (always behind a confirmation).
- **Add tracks** from a track's overflow menu ("Add to playlist"), from the Now
  Playing actions, or via multi-select.
- **Remove tracks** from a playlist (per-row, with an Undo snackbar, or via
  multi-select).
- **Reorder tracks** by dragging the handle on a row.
- **Play** the playlist, or **Shuffle** it, from the detail screen. Tapping any
  track plays from there and queues the rest of the playlist behind it.

Playlists persist locally via `shared_preferences` (the same lightweight,
plugin-only storage used for favourites and the offline-download set) — no
secrets are ever written to playlist metadata.

### Sync state

Every playlist carries a sync state so the UI can be honest about what reached
the server: `localOnly`, `synced`, `pendingCreate`, `pendingUpdate`,
`pendingDelete`, or `syncFailed` (with a friendly, secret-free `lastSyncError`).
Linthra never pretends a sync worked when the server rejected it.

## Jellyfin playlist sync

When you're signed in to Jellyfin you can create a playlist that mirrors to your
server (toggle "Sync with Jellyfin" in the create dialog). Linthra also **imports
your existing Jellyfin playlists by default** — on app launch and on every
**Sync library** — so they appear on the Playlists tab without any extra step. A
synced playlist row shows a subtle "· Jellyfin" source label.

### Reconcile on refresh (server is the source of truth)

Each refresh (startup or Sync library):

- **imports** new server playlists (name + membership), mapping items to your
  synced tracks; items not in your library are counted as unavailable and shown
  honestly on the detail screen, never crashed;
- **updates** an already-synced playlist's name and membership — so a server-side
  rename shows up on the next sync — and is idempotent: repeated syncs never
  duplicate a playlist or its entries;
- **drops** a synced playlist whose server copy is gone (it was deleted on the
  server). Local-only playlists are never touched by a refresh.

On **sign-out**, this account's imported Jellyfin playlists (and its server
favourites) are cleared so they can't linger — or be confused with a different
account — after disconnecting; your local-only playlists stay on-device.

Supported today (best-effort, server is the source of truth for synced
playlists):

- **List / import** remote playlists and their tracks.
- **Create** a Jellyfin playlist from Linthra.
- **Add** Jellyfin tracks to a Jellyfin playlist.
- **Remove** tracks from a Jellyfin playlist (resolved by playlist *entry* id).
- **Delete** a Jellyfin playlist from the server.

Friendly, secret-free errors are surfaced for: not signed in, an expired
session, an unreachable server, and unexpected/unsupported responses. A failed
server write never throws out of an edit — the local change stands and the
playlist's sync state flips to `syncFailed` so you can see it didn't reach the
server.

Only Jellyfin tracks can be added to a Jellyfin playlist; adding a non-Jellyfin
track is declined with a friendly message so a synced playlist stays consistent
with the server. Local Linthra playlists can hold tracks from any source.

### Write-sync limitations (documented on purpose)

- **Rename** and **reorder** of a *synced* playlist are local-only for now; they
  are not pushed to the server, and a refresh re-adopts the server's name/order.
- Server membership is treated as the source of truth on refresh, so a change
  that failed to push (marked `syncFailed`) may be reconciled to the server
  state on the next refresh.
- Subsonic/Navidrome playlist sync is not implemented yet (its tracks can still
  be added to local Linthra playlists).

## Safe song removal / deletion

Linthra separates four distinct actions. Only the first two are enabled in this
release; the destructive file/server deletes are intentionally gated off behind
the provider capability model until they can be done robustly and safely.

| Action | What it touches | Reversible? | Enabled now |
| --- | --- | --- | --- |
| **Remove from Linthra library** | Linthra's local catalog/index only | Yes — a re-scan/re-sync brings it back | ✅ |
| **Remove offline copy** | Only Linthra's app-managed cached file | Yes — re-download / stream again | ✅ (cached tracks) |
| **Delete local file from device** | The real file on disk | No | ❌ (not wired up safely yet) |
| **Delete from server** | The item in Jellyfin, for all devices | No | ❌ (not enabled in this release) |

- **Remove from Linthra library** forgets the rows in Linthra's index. It does
  **not** delete the original local file and does **not** delete anything on
  Jellyfin/Navidrome. It's the safe default.
- **Remove offline copy** deletes only the app-managed download under Linthra's
  private cache directory. The source remains streamable. The currently-playing
  track is never deleted out from under playback — it's skipped and reported.
- **Delete local file** and **Delete from server** are modelled in the
  capability matrix but **not enabled** in this release, because doing them
  safely (SAF permissions for device files; admin permissions and irreversible
  server removal for Jellyfin) needs more than can be verified here. They never
  appear as actions while disabled.

### Bulk actions

Long-press a track (in the Library or a playlist) to enter multi-select. The
contextual bar shows the selected count and only the actions that are **safe for
the whole selection**:

- Add to playlist
- Remove from Linthra library
- Remove offline copies (when at least one selected track has a managed copy)
- Remove from playlist (inside a playlist)

A destructive *delete* would only ever be offered when **every** selected track
supports it (and, for a server delete, they're all the same provider) — so a
mixed-source selection automatically hides any unsafe delete. Bulk removals
always confirm with the count (e.g. "Remove 12 songs from Linthra?") and report
a success/failure summary.

## Confirmation dialogs

Every destructive action confirms first, with an explicit **Cancel** and a
clearly-labelled action button ("Remove", "Delete") — never a vague "OK".
Examples:

- Delete playlist: "Delete playlist '<name>'? This removes the playlist from
  Linthra. Synced playlists may also be removed from the server if sync is
  enabled."
- Remove from Linthra: "Remove '<title>' from Linthra? This will not delete the
  original file or server item."
- Remove offline copy: "Remove offline copy of '<title>'? You can still stream
  it if your server is available."

## Provider capability model

Per-provider capabilities (in `MusicProviderCapabilities`) drive which actions
are shown:

| Capability | Local | Jellyfin | Subsonic |
| --- | --- | --- | --- |
| `canRemoveFromLibrary` | ✅ | ✅ | ✅ |
| `canRemoveOfflineCopy` | — (already local) | ✅ | ✅ |
| `canDeleteLocalFile` | ❌ (not wired up) | ❌ | ❌ |
| `canDeleteRemoteItem` | ❌ | ❌ (not enabled) | ❌ |
| `canFavoriteTracks` | ✅ | ✅ | ❌ |
| `canReadFavoriteState` | ✅ | ✅ | ❌ |
| `canSyncFavorites` | ❌ (local-only) | ✅ | ❌ |
| `canListPlaylists` | ❌ | ✅ | ❌ |
| `canCreatePlaylist` | ✅ | ✅ | ❌ |
| `canEditPlaylist` | ✅ | ✅ | ❌ |
| `canDeletePlaylist` | ✅ | ✅ | ❌ |
| `canSyncPlaylists` | ❌ | ✅ | ❌ |

## Safety guarantees

1. Linthra never deletes a user's file or a server item without explicit
   confirmation — and the file/server delete actions stay disabled until they're
   robust.
2. Offline-cache cleanup (and "remove offline copy") only ever touches
   app-managed files inside Linthra's private cache directory, never the user's
   selected music-source folder.
3. No Jellyfin token or authenticated URL is ever stored in playlist or
   delete metadata, logged, or surfaced in an error message. Errors are friendly
   and secret-free.
4. The currently-playing cached file is never removed out from under playback.

## Future work

- Push rename/reorder of synced Jellyfin playlists to the server.
- Safe, SAF-gated device-file deletion for local tracks.
- Optional, clearly-confirmed Jellyfin server-item deletion for users with
  permission.
- Subsonic/Navidrome playlist sync.
