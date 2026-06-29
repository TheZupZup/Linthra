# Jellyfin sync: playlists & favourites

Linthra mirrors your Jellyfin account so your library *and* the things you've
organised — your **playlists** and your **liked/favourite** tracks — show up in
the app by default. This document describes exactly what syncs, what stays
local, the deliberate limitations, how to troubleshoot, and the security
guarantees. For connectivity (URLs, Cloudflare, version floor) see
[jellyfin-compatibility.md](jellyfin-compatibility.md); for the editing/delete
model and the capability matrix see
[playlists-and-delete.md](playlists-and-delete.md).

## When it syncs

- **Automatically, once, right after you connect.** The first time you sign in
  to a given server/account, Linthra starts a sync on its own so the library
  fills in without you hunting for a button. It runs the **same** path as the
  manual sync below. To avoid surprising background work, this only happens for a
  **new** server/account — reconnecting an already-synced account, reopening
  Settings, or relaunching the app does **not** trigger another full sync.
  Signing in to a **different** server or as a **different** user starts a fresh
  first sync.
- **Manually, any time.** The **Sync library** button stays available for an
  on-demand refresh, and is also the **Retry** if the first sync couldn't finish.

## What syncs by default

When you connect to Jellyfin (the automatic first sync), tap **Sync library**, or
on each app launch, Linthra pulls:

- **Tracks**, **albums**, and **artists** into the local catalog (the Library).
- **Playlists** — your Jellyfin playlists are imported and listed on the
  Playlists tab.
- **Favourites / liked tracks** — the per-user "favourite" flag from Jellyfin is
  adopted, so the heart is filled for the right tracks.

The sync status line reports what landed, e.g. *"Synced 42 tracks, 3 playlists
and 9 favorites from your Jellyfin library."* If only part of the account could
be read, it stays honest — *"Synced 42 tracks from your Jellyfin library.
Playlists could not be loaded."* — and the **tracks still sync** even when
playlists or favourites fail.

Nothing here needs a separate toggle: a sign-in + sync is enough.

## Playlists

- **Import / list.** Existing Jellyfin playlists appear on the Playlists tab with
  a subtle "· Jellyfin" source label. Tapping one opens its tracks; Play /
  Shuffle queue the available tracks.
- **Track mapping.** A playlist stores stable Jellyfin item ids; they resolve
  against your synced catalog. A track that isn't in your library yet is counted
  and shown as unavailable on the detail screen — never a crash, and the rest of
  the playlist still plays.
- **Idempotent refresh.** Re-syncing never duplicates a playlist or its entries;
  it updates the existing synced record in place.
- **Rename pickup.** If you rename a playlist on the Jellyfin server, Linthra
  adopts the new name on the next sync.
- **Deletion pickup.** If a playlist is deleted on the server, Linthra drops its
  local mirror on the next sync (the server is the source of truth for synced
  playlists). Your **local-only** playlists are never touched by a refresh.
- **Write-back (when signed in).** Creating a "Sync with Jellyfin" playlist,
  adding Jellyfin tracks to it, removing tracks, and deleting it are pushed to
  the server best-effort. A failed write never throws out of the edit — the local
  change stands and the playlist's sync state flips to `syncFailed` with a
  friendly, secret-free reason.

## Favourites / likes

- **Read on sync.** Jellyfin's per-user favourite set is fetched and adopted as
  the source of truth for remote (Jellyfin) tracks; the favourited tracks show as
  liked across the app (heart button, Favorites tab).
- **Offline-visible.** The favourite set is stored on-device, so the right hearts
  show even before the next sync / while offline.
- **Toggle from Linthra.** Liking/unliking a Jellyfin track updates the UI
  immediately (optimistic) and pushes the change to Jellyfin's user-data
  favourite API. If the push fails (offline, expired session), the optimistic
  local state stands and is reconciled on the next sync rather than throwing — so
  the heart never gets stuck mid-tap. You can toggle from Now Playing and the
  Favorites/Library track rows where a heart is shown.
- **External changes.** If you change favourites on Jellyfin (another client, the
  web UI), the next sync updates Linthra.

## What stays local-only

- **Local-file favourites.** Hearts on on-device tracks are stored on-device and
  are **never** sent to Jellyfin. Mixed local + Jellyfin favourite lists work
  cleanly — each side is tracked separately and merged for display.
- **Local-only playlists.** A playlist you create without "Sync with Jellyfin"
  lives only on the device and is never pushed or pruned by a server refresh. It
  can still hold tracks from any source.

## Sign-out

Sign-out clears this account's **server-synced favourites** and **imported
Jellyfin playlists**, plus the stale sync status, so one account's data can't
linger or cross over to a different account on the next sign-in. Your **local**
favourites and **local-only** playlists are kept.

## Known limitations (on purpose)

- **Rename / reorder of a synced playlist are local-only.** They are not pushed
  to Jellyfin; a refresh re-adopts the server's name and order.
- **No two-way conflict resolution.** On refresh the server wins for synced
  playlists and the favourite set. A local change that failed to push
  (`syncFailed`) may be reconciled to the server state on the next refresh.
- **Missing playlist tracks** (items not in your synced library) are shown as
  unavailable rather than fetched on the fly.
- **Subsonic/Navidrome** playlist and favourite sync are not implemented yet;
  their tracks can still be added to local Linthra playlists.

## Troubleshooting

- **The first sync is taking a while.** A large library takes a moment to pull;
  the app stays responsive and the Library shows a "syncing" note until the
  tracks land. There's nothing to do but wait — it finishes in the background.
  The library is pulled in **bounded pages** with brief yields between them, so a
  big/slow server can't time out one giant request, playback keeps working
  throughout, and a brief network/server blip is **retried a few times** before
  it gives up.
- **"Some items could not be synced."** A few tracks had metadata too malformed
  to read (a missing title, a wrong-typed field). They are **skipped** so the
  rest of your library still syncs — this is a calm note, not a failure, and the
  usable music is fully available. The skipped count is in the debug log /
  bug-report event trail (kind + counts only, never titles).
- **"Connected, but the library sync didn't finish."** The connection is fine,
  but the sync hit a snag (a slow/large listing that timed out, a transient
  server error, a partial response). When a sync fails, Linthra **probes the
  live session** (a tiny `/Users/Me` check) to tell apart three cases, so it
  never shows a misleading message:
  - **the probe succeeds** → the server and your session are fine and only the
    *library sync* failed. You'll see "Connected — the library sync didn't
    finish, but your existing music is still available", your library is kept
    intact, and **Retry** is the only thing to do. (This is the common case for
    a large library on a slow server, and it never asks you to sign in.)
  - **the probe is rejected (401)** → your session really has expired; only then
    are you asked to sign out and back in.
  - **the probe also can't reach the server** → a genuine "couldn't reach your
    Jellyfin server".
- **Server unreachable.** If the sync can't reach the server, you'll see a
  friendly "couldn't reach your Jellyfin server" message — check the server is
  online and reachable from the device, then Retry.
- **Session expired.** A sync (or stream) may report your session has expired;
  sign out and sign in again to refresh it, and the next connect re-syncs.
- **Playlists not showing.** Make sure you're signed in (Settings → Jellyfin)
  and run **Sync library**. The Playlists tab's empty state tells you whether
  you're signed in. If the status line says "playlists could not be loaded", the
  server was briefly unreachable or the session expired — try again, or sign in
  again.
- **Favourites not syncing.** Same first steps. A liked track that doesn't change
  on the server usually means the favourite push failed silently and was kept
  locally; the next successful sync reconciles it.
- **Session expired.** The sync/stream errors prompt you to sign out and sign in
  again to refresh the token.
- **A playlist disappeared after a sync.** It was deleted on the Jellyfin server;
  Linthra drops synced playlists that no longer exist on the server.

## Security notes

- **No tokens in metadata.** A playlist stores only a non-secret `remoteId`
  (the server playlist id) and track ids; favourites store only item ids. No
  Jellyfin token, password, or authenticated URL is ever written to playlist or
  favourite metadata, a cache filename, a log, or a UI error.
- **No authenticated URLs persisted.** Stream/download URLs are minted on demand
  at play/download time from the live session and discarded; the persisted track
  URI stays the token-free `jellyfin:<id>`.
- **The auto-sync marker is a one-way fingerprint.** To remember which account
  has already had its first sync, Linthra stores a SHA-256 hash of the server
  URL + user id — never the token, the URL, or the user id themselves — so the
  marker reveals nothing and lives in plain storage safely.
- **Metadata only.** This sync never starts a download or cache fetch; offline
  copies stay explicit and user-initiated, exactly as before.
- **Friendly, redacted errors.** Sync/favourite/playlist failures surface as
  friendly messages branched on a typed error kind (not signed in, expired
  session, server unreachable, permission/API error) — never a raw error or a
  tokenised URL. Tests assert no token reaches these sinks.
