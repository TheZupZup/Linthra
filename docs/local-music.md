# Local music (on-device folders)

Linthra can play music that already lives on the phone — internal storage, a
removable SD card, or any folder you point it at — alongside (or instead of) a
Jellyfin or Navidrome / Subsonic server.

## How to set it up

There are two equivalent entry points; both end up at the same place:

- **Settings ▸ Local music** — the primary home, grouped with the other music
  sources (Jellyfin, Navidrome / Subsonic). Choose a folder, **Rescan** it after
  you add files, **Add a folder** (desktop) or **Change** it (Android), remove a
  single folder with the ✕ beside it, or **Forget** the whole local source.
- **Library ▸ (empty state) ▸ Select / Change folder** — the same pick-and-scan
  flow, offered where you first notice an empty library.

When you pick a folder, the system's own folder chooser opens — Android's on a
phone, the desktop's on Linux. Linthra keeps **only** the access you grant for
that one folder; it never asks for a broad "all files" or media permission, and
on Linux it needs no host filesystem permission at all (see
[On Linux](#on-linux-including-the-flatpak)).

## Several folders (desktop)

On Linux a library is often spread around — an internal music folder, an
external drive, a NAS mount — so **Settings ▸ Local music** takes as many folders
as you like and scans them as one library. Android keeps a single selection: its
local access is one Storage Access Framework grant (or the device-wide MediaStore
mode) at a time.

What that means in practice:

- **Overlapping folders import a file once.** Selecting `~/Music` and then
  `~/Music/Live sets` is not an error and does not duplicate anything: the inner
  folder is already covered, so only `~/Music` is walked. Adding a folder that
  contains ones you already selected replaces them, again keeping one walk.
- **An offline folder doesn't take the rest down.** If a drive is unplugged
  when you rescan, the folders Linthra *can* read are refreshed and the offline
  one keeps the tracks it already contributed. The card says how many folders
  couldn't be read, and the library is not silently shortened. If **no** folder
  can be read, nothing is written at all — the catalog stays exactly as it was.
- **Removing a folder removes only its music.** The ✕ beside a folder drops it
  and rescans the rest, so the other folders' tracks stay indexed. Removing the
  last folder is the same as Forget: the local index is emptied, and nothing on
  disk is touched.
- **The selection survives restarts**, and an existing single-folder library is
  carried over untouched — it simply becomes the first folder in the list.

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
- **Embedded cover art is shown.** During the scan, a file's embedded album art
  (ID3 `APIC`, FLAC picture, MP4 cover, …) is read through the same content
  resolver and the same SAF grant as the tags — no extra permission — and cached
  once inside Linthra's own private storage. The track then carries a `file://`
  `artworkUri` into that cache, so the cover appears in library rows, the
  album/artist views, and the queue / now-playing / mini-player. A file with no
  embedded art keeps the calm placeholder. The cache is keyed by a hash of the
  file's content URI (never its name or path), so a cover is extracted **once**
  and reused on later launches and re-scans rather than re-read every time; if
  the OS reclaims the cache, the next rescan simply re-extracts. (A server copy's
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
4. That walk runs **off the platform (main) thread**, on `PlatformChannelWorker`'s
   single background thread, and the method-channel reply is encoded and sent
   there too. A real library means thousands of
   content-resolver queries plus a `MediaMetadataRetriever` open per file, so
   scanning inline would freeze the UI and eventually trip an ANR. Two scans
   never run at once. Picking a second folder mid-scan **supersedes** the first
   rather than queueing behind it: the abandoned walk stops at its next file and
   answers `saf_superseded`, so the folder you just chose starts right away
   instead of waiting out a scan you already moved on from. Forgetting the
   folder or switching to the device-wide library cancels it the same way, even
   though neither starts a replacement scan. That flag is process-scoped, so it
   keeps working if Android recreates the activity mid-scan. `scripts/check_android_channel_threading.py` guards both the thread
   boundary and the cancellation, because a walk that drifts back onto the
   platform thread, or a supersede that quietly stops superseding, still
   compiles and still passes every test.

This is why a raw path like `/storage/emulated/0/Music/...` is the wrong thing to
store — it looks fine but can't be read under scoped storage. If you selected a
folder in a much older build and see "no music found", just **choose the folder
again**: the new selection grants and persists proper access.

### On Linux (including the Flatpak)

Linux stores a real filesystem path rather than a `content://` URI, and the scan
is an ordinary `dart:io` walk. What differs is where the path comes from:

1. The folder chooser is GTK's own (`GtkFileChooserNative`, opened by Linthra's
   Linux runner). On a native build that is the familiar in-process dialog.
2. Inside the **Flatpak**, GTK routes exactly the same chooser to
   **xdg-desktop-portal**, which runs it on the host. Only the folder you picked
   is handed back to the sandbox, exported through the document portal, and it
   stays readable after a restart. Nothing else on the host becomes visible, and
   Linthra ships no `--filesystem=host` or `--filesystem=home` permission — see
   [`flatpak/README.md`](../flatpak/README.md#local-music-folders).
3. If a folder later stops resolving — an unplugged drive, a folder you moved
   or deleted, or a portal grant you revoked — Linthra says so, on that folder's
   own row, and asks you to select it again. It does **not** treat that as "this
   folder is empty now", so its music stays indexed until you choose, and the
   other folders keep scanning normally.
4. **Tags are read from the files themselves**, not guessed from their names:
   title, artist, album artist, album, track number and duration, from ID3
   (MP3), Vorbis comments (FLAC, OGG, Opus), MP4 atoms (M4A), APEv2 and RIFF
   INFO (WAV). Only the tag structures are parsed, so a 60 MB FLAC is not read
   into memory to find its title. A file with no tags, or one that cannot be
   parsed, still appears in the library with its filename-derived name — a
   track is never dropped for having bad tags.

   Two honest gaps on Linux today: **embedded cover art is not extracted yet**
   ([#408](https://github.com/thezupzup/linthra/issues/408)), so local tracks
   keep the placeholder; and **album artist** depends on the container. ID3
   (TPE2), APEv2 and FLAC report a real one, so a compilation groups under the
   album artist. OGG and Opus do not: the tag reader Linthra uses folds their
   `ARTIST` and `ALBUMARTIST` comments into one list and loses which was which,
   and guessing would be worse than reporting none, so those group by album and
   artist instead. FLAC avoids that because Linthra reads its comment block
   itself and keeps the field names.

## Local music vs Offline downloads vs Cache

These three are easy to confuse but are distinct:

| Concept | What it is | Where |
| --- | --- | --- |
| **Local music** | Music files that already live on the device, SD card or computer, played in place from a folder you chose in the system chooser (SAF on Android, the desktop/portal chooser on Linux). Linthra never moves or copies them. | Settings ▸ Local music |
| **Offline downloads** | Copies Linthra makes of **server** tracks (Jellyfin / Subsonic) so they play without a network. You choose what to download. | The download action / Settings ▸ Offline |
| **Cache** | Linthra-managed **temporary** storage (e.g. streamed/pre-cached audio), bounded by a size limit and reclaimable at any time. | Settings ▸ Cache — see [offline-cache.md](./offline-cache.md) |

"Forget folder" only removes Linthra's index of the local source — it **deletes
nothing on disk**. Your files stay exactly where they are, and re-selecting the
folder brings them back.

## Troubleshooting "no music found"

Settings ▸ Diagnostics (and the "Report a bug" flow) include **secret-free** scan
counters — counts only, never a path, file name, or URI:

- **Local folder**: selected / not selected (how many folders is reported by the
  scan line below, never which ones)
- **Local folder access**: persisted / not persisted (on Android the SAF grant —
  the removable-SD-card-after-reboot signal; on Linux whether the chosen folder
  can still be listed at all)
- **Local scan**: files visited, folders visited, audio candidates, imported,
  skipped (unsupported), read failures, and — for a multi-folder library — how
  many selected folders were scanned and how many were unreachable
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
  re-select the folder. On Linux the same line means the folder no longer
  resolves (drive not connected, folder moved, portal access revoked); the
  library you already indexed is kept, so re-selecting restores it.

Please don't paste full private paths into public bug reports; the diagnostics
above are designed so you don't have to.
