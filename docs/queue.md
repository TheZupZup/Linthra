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

On a wide **desktop** window the same manager opens as a pane beside Now
Playing, and its history section is a different thing — see
[Recently played (desktop)](#recently-played-desktop).

## Recently played (desktop)

There are two kinds of "what already played", and the desktop pane shows the
second one ([issue #419](https://github.com/thezupzup/linthra/issues/419)).

| | **Previously played** (sheet) | **Recently played** (desktop pane) |
| --- | --- | --- |
| What it is | the already-played prefix of the **current queue** | what actually played this **session**, across queues |
| Survives a new queue | no — it is part of the queue | yes |
| Bound | the queue's own length | **50 tracks**, hard cap |
| Order | queue order, above Now playing | newest first, below Up next |
| Tapping a row | steps back inside the queue | replays the track (see below) |

Android keeps the sheet and its queue-derived history at **every** window
width. The pane's history is chosen on the host, not on the width, so a wide
Android tablet behaves exactly like the phone. The recorder that fills the
recent-playback history does not run off desktop at all.

### What gets recorded

A track lands in Recently played when it leaves the player, marked with how it
left:

- **Played to the end** — it reached (within two seconds of) its duration, or
  the queue ran out on it.
- **Skipped** — the listener moved on first: a skip, a jump elsewhere in the
  queue, or a whole new queue.

A track that never actually started (a load that failed) is not recorded:
"recently played" has to mean played.

Playing the same song again **moves** its entry to the front rather than adding
a second one, so a repeat-heavy session cannot push everything else off the end.

### The retention bound

The list holds at most **50 tracks** (`PlaybackHistory.defaultLimit`) and the
oldest entry rolls off on every write. There is no setting: the point of the
bound is that a long session cannot grow it, and the pane says so in a line
under the list.

It is also **memory only**. Nothing about the recent-playback history is
written to disk, so it is empty again after a restart. That is deliberate — see
*Security* below.

### Replaying a row

Tapping a Recently played row plays that song again, by one of two routes:

- the track is **still in the current queue's** history → it steps back to it,
  exactly like tapping a Previously played row: up-next is preserved and the
  queue is not rebuilt;
- otherwise (it came from an earlier queue) → it plays through the ordinary
  play path.

Either way the playable source is resolved **fresh** through the normal
resolver and its fallbacks. There is nothing else it could do: the history
holds a catalog track and nothing more (see below).

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

On desktop the handle behaves the way a desktop control should: the pointer
turns into a grab cursor over it, hovering shows what it does, and the row lifts
onto a shadow while it is being dragged so you can see what you picked up.
Dragging past the top or bottom of the list drops the track at that end rather
than somewhere unexpected, so an overshot drag is never destructive.

**Without a pointer.** Tab to a row's handle and press **Ctrl + ↑ / ↓** (Cmd on
macOS) to move that row one position. Focus follows the track, so holding the
chord walks it up or down the queue (the sheet scrolls along to keep the track
you are moving in view). The same two moves are exposed to screen readers as the
row's **Move up** / **Move down** actions. Unlike a drag, a keyboard move at an
endpoint does nothing at all: a row at either end only offers the move that goes
somewhere. Keyboard, screen reader and drag all run through the same queue edit,
so nothing behaves differently depending on how you reached it.

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
playing now. Playback is not interrupted. On the desktop pane it also empties
the Recently played list, so Clear keeps meaning the same thing in both shapes.

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
stream URL or a token.

The desktop **Recently played** history holds the same catalog metadata and
enforces it: `PlaybackHistory.record` refuses any track whose uri is not a
*logical* identity (`isLogicalTrackUri` — the same guard the crash-safe session
store uses), so an `http(s)://` stream URL or a token-bearing uri is never
recorded in the first place. And because it is memory-only, the "nothing
authenticated is persisted" rule holds by there being no store at all rather
than by sanitising one. Authenticated URLs are minted at play time by the resolver
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
- **Recently played does not survive a restart.** It is memory-only by design.
  Persisting it would mean a second on-disk record of listening history next to
  the play counts that already exist, and the safest version of that feature is
  the one that does not write anything.
- **Recently played is desktop-only.** The queue pane is where there is room for
  it; the phone sheet keeps the queue-derived history it has always had.

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
- [ ] The sheet still shows **Previously played** (not Recently played) at any
      window width.
- [ ] **Save queue as playlist** creates a local playlist with the queue's songs.
- [ ] While **casting**: add/remove/reorder and "play now" never start audio on
      the phone; the receiver follows the current track.
- [ ] **Android Auto**: queue edits in the app don't start duplicate playback.

## Manual Linux checklist

- [ ] Widen Now Playing until the queue opens as a pane; play a few songs
      through and skip one — both appear under **Recently played**, newest
      first, with the skipped one marked as skipped.
- [ ] Start a completely new queue — the Recently played list keeps the songs
      from the old one.
- [ ] Tap a Recently played row that is still in the queue — it steps back and
      up-next is unchanged.
- [ ] Tap a Recently played row from an earlier queue — it plays (a remote
      track re-resolves; no stale URL is reused).
- [ ] Press **Clear** — up next and Recently played both empty, the current
      track keeps playing.
- [ ] Restart the app — Recently played is empty again (memory only).
