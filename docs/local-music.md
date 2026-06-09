# Local music (on-device folders)

Linthra can play music that already lives on the phone — internal storage, a
removable SD card, or any folder you point it at — alongside (or instead of) a
Jellyfin or Navidrome / Subsonic server.

## How to set it up

There are two equivalent entry points; both end up at the same place:

- **Settings ▸ Local music** — the primary home, grouped with the other music
  sources (Jellyfin, Navidrome / Subsonic). Choose a folder, **Rescan** it after
  you add files, **Change** it, or **Forget** it.
- **Library ▸ (empty state) ▸ Select / Change folder** — the same pick-and-scan
  flow, offered where you first notice an empty library.

When you pick a folder, Android shows its system folder chooser. Linthra keeps
**only** the access you grant for that one folder — no broad "all files" or media
permission is requested.

## What's supported

- Internal phone storage and **removable / external SD cards**.
- Any folder chosen through Android's file picker (Storage Access Framework).
- Files **directly inside** the chosen folder *and* **nested** artist/album
  subfolders — the scan is recursive.
- Audio formats: **mp3, m4a, aac, flac, ogg, opus, wav**. A file is treated as
  audio if it has one of those extensions **or** the system reports an `audio/*`
  content type, so an oddly-named file the platform still recognises as audio is
  not dropped.

### Track metadata (tags)

Local tracks index like a real source, not a flat file list:

- **Audio tags are read** during the scan — title, artist, album, album artist,
  track number, and duration — so a tagged file shows and groups exactly like a
  Jellyfin / Navidrome track. On Android the picked folder is read through the
  content resolver, and each file's tags are read there too (no extra
  permission — the same folder grant covers it).
- **Clean fallback when tags are missing.** A file with no (or partial) tags
  never shows an ugly path: the title and any leading track number come from the
  file name (`01 - Holocene.flac` → track 1, "Holocene"), and the artist/album
  come from the conventional `…/Artist/Album/Track` folders. Each field falls
  back on its own, so a half-tagged file still gets the best of both. A file with
  nothing to go on still folds into **Unknown Album / Artist** (see
  [library.md](./library.md)).
- **Embedded cover art** for local files is a separate follow-up; until then a
  local track with no `artworkUri` shows the calm placeholder. (A server copy's
  cover is still used when the same song is also on a server — see
  [unified-library.md](./unified-library.md).)

## How it works (and why it's reliable)

On Android 11+ ("scoped storage"), an app **cannot** read arbitrary
`/storage/...` paths with normal file APIs. The reliable, permission-free way to
read a user-chosen folder is the **Storage Access Framework (SAF)**:

1. The folder chooser returns a `content://…/tree/…` **tree URI**, not a raw
   filesystem path.
2. Linthra **persists the read grant** for that URI, so the same folder can be
   re-scanned after a reboot (important for removable SD cards) without
   re-prompting.
3. The scan walks the tree through the **content resolver**
   (`DocumentsContract`), visiting the root's direct files first and then
   descending into subfolders. One unreadable subfolder is skipped and counted,
   not fatal; a totally unreadable selected folder surfaces a clear error rather
   than a silent empty result.

This is why a raw path like `/storage/emulated/0/Music/...` is the wrong thing to
store — it looks fine but can't be read under scoped storage. If you selected a
folder in a much older build and see "no music found", just **choose the folder
again**: the new selection grants and persists proper access.

## Local music vs Offline downloads vs Cache

These three are easy to confuse but are distinct:

| Concept | What it is | Where |
| --- | --- | --- |
| **Local music** | Music files that already live on the device or SD card, played in place from a folder you chose via SAF. Linthra never moves or copies them. | Settings ▸ Local music |
| **Offline downloads** | Copies Linthra makes of **server** tracks (Jellyfin / Subsonic) so they play without a network. You choose what to download. | The download action / Settings ▸ Offline |
| **Cache** | Linthra-managed **temporary** storage (e.g. streamed/pre-cached audio), bounded by a size limit and reclaimable at any time. | Settings ▸ Cache — see [offline-cache.md](./offline-cache.md) |

"Forget folder" only removes Linthra's index of the local source — it **deletes
nothing on disk**. Your files stay exactly where they are, and re-selecting the
folder brings them back.

## Troubleshooting "no music found"

Settings ▸ Diagnostics (and the "Report a bug" flow) include **secret-free** scan
counters — counts only, never a path, file name, or URI:

- **Local folder**: selected / not selected
- **Local folder access**: persisted / not persisted (the SAF grant — the
  removable-SD-card-after-reboot signal)
- **Local scan**: files visited, folders visited, audio candidates, imported,
  skipped (unsupported), read failures
- **Local scan recursive**: yes / no
- **Local supported types**: the extensions Linthra accepts
- **Local scan status**: ok, or the failure kind

Reading them:

- `folders 0` with a selected folder usually means the root couldn't be read —
  pick the folder again to refresh access.
- `read failures > 0` points at a permission / removable-storage problem rather
  than an empty folder.
- `audio 0, skipped N` means files were found but none matched a supported audio
  type.
- `access: not persisted` after a reboot means the SD-card grant was lost —
  re-select the folder.

Please don't paste full private paths into public bug reports; the diagnostics
above are designed so you don't have to.
