# Queue / Up Next

Linthra has a proper **Up Next manager** so you can control what plays without
building a playlist every time. This page covers the queue model, the actions,
how it behaves with shuffle/repeat/Cast/Android Auto, and the known limits.

The queue is owned by a single `PlaybackController` (see
[docs/architecture.md](./architecture.md) and
[docs/background-playback.md](./background-playback.md)). Every surface —
mini-player, Now Playing, the Queue sheet, Cast, and the Android Auto media
session — reads from and edits the **same** queue. There is never a second copy.

## Opening the Queue

From **Now Playing**, tap the **Queue** button (the up-next icon in the bottom
action row). The queue opens as a bottom sheet that floats over Now Playing, so
**opening or browsing the queue never touches playback** — the current track
keeps playing while you reorder, remove, or look around.

The sheet shows, top to bottom:

- **Previously played** — the tracks already played (history), when any. Tap one
  to jump back to it.
- **Now playing** — the current track, highlighted in the warm "live" accent. It
  has no remove/drag controls on purpose (see *Removing* below).
- **Up next** — the upcoming tracks. Each row can be played now (tap), removed
  (the ✕), or dragged to a new position (the drag handle).

Header actions: **Save queue as playlist** and **Clear**.

## Play next vs. Add to queue

Both are available from a track's overflow (⋮) menu in the **Songs** list,
**Album**, **Artist**, **Playlist**, and **Search** results:

| Action | Behaviour |
| --- | --- |
| **Play next** | Inserts the track **immediately after** the current one, so it plays next without interrupting what's playing. |
| **Add to queue** | **Appends** the track to the **end** of the queue. |

**When nothing is playing**, both actions simply **start** the track (there's
nothing to play "after", so this is the cleanest behaviour — the action is never
a silent no-op).

## Reordering

Drag an **upcoming** track by its handle to a new position. The current track is
untouched and keeps playing — reordering only changes the order of what follows.
History and the current track are not draggable.

- **Shuffle stays coherent.** While shuffle is on, you reorder the *shuffled*
  (effective) order. Turning shuffle **off** restores the original
  pre-shuffle order, which drops a manual reorder — that's the defined meaning of
  un-shuffling, not a bug.
- **Repeat stays coherent.** Repeat-all still wraps to the start of the
  (reordered) queue; repeat-one still replays the current track.

## Removing

The ✕ on an upcoming row removes **only that queue entry**. It does **not**:

- delete the track from your library, or
- remove its offline (downloaded) copy.

The **currently playing** track cannot be removed from the Queue sheet — the
manager never yanks the playing track out from under playback. To stop the
current track, use the transport controls (pause/stop) or skip.

If the queue becomes empty (everything up next removed, or **Clear**), the
**current track keeps playing**.

## Clear queue

**Clear** drops the up-next list **and** the history, keeping only the track
playing now. Playback is not interrupted.

## Save queue as playlist

**Save queue as playlist** creates a **local** playlist from the whole queue
(history + current + up next, in order) and prompts for a name.

- It is **local-only** and **never auto-syncs to Jellyfin**. This is deliberate:
  a queue can mix local and remote tracks, and the Jellyfin playlist rules only
  accept Jellyfin tracks — so auto-syncing could silently drop the local ones or
  push to a server unexpectedly. Saving locally avoids both. You can still sync
  it later from the playlist screen if it holds only Jellyfin tracks.
- Duplicate track ids collapse to one entry (a playlist holds each track once).

## Cast & Android Auto

The queue is **output-agnostic** because it lives in one controller and the
output (local engine vs. a Cast receiver) is routed underneath it:

- **Editing the queue while casting is safe.** Add / remove / reorder only
  reshape the up-next list; the receiver keeps playing the current track. They
  **never start a second, duplicate stream** on the phone (the local engine is
  suspended while casting). "Play this now" changes the current track, which the
  Cast service mirrors onto the receiver via the normal track-change path — again
  with no local audio.
- **Android Auto** drives the same controller. Its media session reflects the
  current track and whether a next/previous exists; editing the queue in the app
  is reflected there without starting duplicate playback.

See [docs/cast.md](./cast.md) and [docs/android-auto.md](./android-auto.md) for
the routing details.

## Security

The queue state and UI carry **only catalog metadata** — track id, title,
artist, album, artwork reference. They never hold a resolved/authenticated
stream URL or a token. Authenticated URLs are minted at play time by the resolver
and live only transiently in the audio engine / Cast load message; they are
never stored in the queue, never shown in the Queue sheet, and never persisted
when you save the queue as a playlist (only stable track ids are saved).

## Known limitations / follow-ups

- **Save queue as playlist is local-only.** Syncing a saved queue to Jellyfin in
  one step is a possible follow-up (today: save locally, then sync from the
  playlist screen if all tracks are Jellyfin).
- **Un-shuffling drops a manual reorder** of the up-next list (it restores the
  true pre-shuffle order). This is intentional and documented above.
- **Duplicate tracks** in a queue share a track id; reorder/remove act on the
  first matching entry. Queues rarely contain exact duplicates.

## Manual Android checklist

- [ ] Play an album, open **Queue** from Now Playing — current + up next render.
- [ ] **Play next** / **Add to queue** from a song's ⋮ menu (Songs, Album,
      Artist, Playlist, Search) land in the right spot; current track keeps
      playing (no restart).
- [ ] With nothing playing, **Play next** / **Add to queue** start the track.
- [ ] Drag an up-next track to reorder; current track keeps playing.
- [ ] Remove an up-next track (✕) — it leaves the library and offline copy intact.
- [ ] **Clear** keeps the current track playing.
- [ ] Tap an up-next track to play it now; tap a history track to step back.
- [ ] **Save queue as playlist** creates a local playlist with the queue's songs.
- [ ] While **casting**: add/remove/reorder and "play now" never start audio on
      the phone; the receiver follows the current track.
- [ ] **Android Auto**: queue edits in the app don't start duplicate playback.
