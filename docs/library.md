# Library browsing & search

Linthra's Library is the home screen. It reads entirely from the local,
offline-first catalog (the SQLite track table that scans and server syncs write
into) — never from the network on the render path — so browsing stays instant
and works fully offline.

## Tabs

The Library is organised into three tabs:

- **Songs** — every track in your catalog. Sorted by title (A–Z), with the A–Z
  fast-scroll rail pinned to the right edge for large libraries. Long-press a
  row to multi-select (add to playlist, remove from Linthra, remove offline
  copies). Tapping a song plays it and queues the rest of the visible list.
- **Albums** — tracks grouped into albums. Each row shows the album artwork (or
  a placeholder), the album title, the album artist, and the track count.
  Tapping an album opens its detail view.
- **Artists** — tracks grouped by artist. Each row shows an avatar placeholder,
  the artist name, and the album/track counts. Tapping an artist opens its
  detail view.

The mini-player and bottom navigation stay put while you browse — switching
tabs or searching never interrupts playback.

### Album detail

Shows the album's tracks in album order (by track number where available, then
title). Includes **Play** and **Shuffle** buttons that queue the whole album,
and tapping any track plays it and queues the rest of *that album*.

### Artist detail

Shows the artist's albums (each opening its own album detail) and all their
tracks. Includes **Play all** and **Shuffle all**, which queue only that
artist's tracks. The Albums section is shown when the artist has more than one
album; a single-album artist just lists its songs.

## Search

A single search box sits above the tabs and filters whatever tab is active:

- **Songs** — matches title, artist, or album.
- **Albums** — matches album title or album artist.
- **Artists** — matches artist name.

Search is **case-insensitive** and, where practical, **accent-insensitive** —
typing `beyonce` finds *Beyoncé*, and `motley` finds *Mötley*. (Folding uses a
small built-in Latin diacritics table, so it adds no dependency and never
touches the network.)

- An empty query shows the full tab.
- A query with no matches shows a friendly **"No results found."** state.
- A **clear** (×) button resets the search.
- **Switching tabs clears the query** — a search meant for one tab never
  silently hides another tab's contents.
- Searching only filters what's shown; it **never changes playback**. Whatever
  is playing keeps playing, and the mini-player keeps working.

### Quick search (Ctrl+K)

Above the Library's own box there is a second, app-wide way in: **Ctrl+K** (or
**Ctrl+F**) opens a quick-search overlay from anywhere in the app frame, on any
tab. It is a dialog over whatever is on screen, so the page underneath keeps its
scroll position, its selection, and any query already typed into the Library box
— close the overlay and you are exactly where you were.

- It searches **songs, albums, artists and playlists at once**, grouped under
  headings, and shows the best five of each.
- Results are **ranked**, not just filtered: an exact name beats a prefix, which
  beats a match at the start of a later word, which beats a match inside one, and
  a hit on an item's own title beats a hit on its artist or album. Typing three
  letters of a song you know puts it on the first row.
- **↑ / ↓** move the selection (wrapping at both ends), **Enter** opens it,
  **Esc** closes. The box keeps focus the whole time, so you never have to reach
  for the mouse. Clicking or hovering a row works too. A key press applies a
  pending debounce first, so typing three letters and hitting Enter straight
  away opens the best match for what you typed, never for the previous query.
- Opening a result uses the routes the rest of the app uses: an album, an artist
  or a playlist opens its existing detail screen. A song plays and opens Now
  Playing, with the song matches becoming the queue positioned at the row you
  chose: Next walks the matches below it and Previous the ones above, exactly as
  tapping a row in the Library's own list behaves.
- Ranking is **debounced** (200 ms), so a large library is ranked when you pause
  rather than on every keystroke. The states are distinct and honest: a prompt
  before you type, "Searching…" while the debounce is pending, "Loading your
  library…" while the catalog or your playlists are still loading, and "Some of
  your library could not be loaded" when one of them failed. "No results for …"
  is only ever shown when everything loaded and nothing matched — an outage
  never gets reported as an empty library. Whatever *did* load is still
  searchable meanwhile, so an unreachable server does not hide your local songs.

It reads the same providers the tabs browse — the unified (de-duplicated)
catalog, the albums and artists derived from it, and your playlists — so there is
no second catalog to keep in sync, and quick search can never disagree with what
the Library shows. Nothing is gated on the platform: the shortcut only fires when
a real keyboard sends it, so a phone is unaffected and a tablet with a keyboard
gets it for free.

The binding sits **above the router**, wrapping everything the app shows, rather
than inside the navigation shell. Key events travel up from whatever holds focus,
so a binding under the shell would be invisible to routes pushed over it — Now
Playing above all, which is exactly where opening a song from quick search leaves
you.

Code: `lib/features/library/quick_search.dart` (the pure ranking),
`quick_search_providers.dart` (what it reads and whether it is all there),
`widgets/quick_search_overlay.dart` (the overlay), and
`lib/app/quick_search_shortcuts.dart` (the key bindings).
Tests: `test/features/library/quick_search_test.dart`,
`quick_search_overlay_test.dart`, `quick_search_availability_test.dart`, and
`test/app/quick_search_shortcuts_test.dart`.

### Fast-scroll rail

The A–Z fast-scroller is kept on the **Songs** tab, where an alphabetical track
list benefits from it. It hides automatically when there are too few sections
(for example, while a search narrows the list to a handful of results), so it
never gets in the way. The Albums and Artists tabs are short, grouped lists and
don't use the rail.

## How grouping works

Albums and artists are **derived from the track catalog** rather than stored as
separate rows. Artists group by their folded name. Albums use the most specific
signal each track carries, in order:

1. **the source's own album ID**, when it reports one — stored
   provider-namespaced (`jellyfin:al-1`, `plex:201`, `subsonic:al-27`) so two
   servers' identically-named album IDs can never collide;
2. **album title + album artist**, when there is no ID but the source
   distinguishes the album artist from the track artist;
3. **album title + track artist** — the original fallback.

Keys are folded for case and accents at every tier, so:

- an album whose tracks credit different collaborating artists
  ("Main Artist feat. Guest") stays **one** album rather than splitting into a
  row per credit;
- the same album title by two different artists stays distinct (two "Greatest
  Hits" don't merge), and
- case/accent differences in tags don't split one album into two.

This is source-uniform: it works the same for Jellyfin/Subsonic/Plex tracks and
local files, each simply falling to the most specific tier it has data for.

## Jellyfin / Subsonic metadata

Tracks synced from a Jellyfin or Subsonic/Navidrome server carry real album and
artist names and a token-free cover-art URL, so they group into proper albums
and artists with artwork. No authenticated URL or token is ever stored on a
track or surfaced in the Library — a Jellyfin track's stored reference is an
opaque `jellyfin:<id>`, and stream URLs (which carry the access token) are minted
only at play time.

## Track status in the library

Every track row carries one small, non-interactive glyph beside its overflow
menu. It never grows into a control, and it is **silent by default**: on-device
music has no server to be away from, and a server-backed row whose server is
answering and which has no saved copy of its own has nothing worth saying. An
indicator lit on every ordinary row is one nobody reads, so the interesting
states earn their place by being the exception.

The glyph answers two questions, in this order:

1. **Is something being transferred?** Queued, downloading (a determinate ring
   when the server reported a size), or failed. Transient and actionable, so it
   wins whenever it has something to say.
2. **Will this still play when the server is away?** Once nothing is in flight,
   the row reports its settled availability.

| What the row is | Glyph | Meaning |
| --- | --- | --- |
| On-device file | *(nothing)* | There is no server to be away from. |
| Server-backed, server answering, no copy | *(nothing)* | The ordinary case. |
| Explicitly downloaded | Download done | A copy the user asked for, and the server is answering. |
| Pre-cached only | Outlined pin | A copy the app prefetched ahead of play ([offline-cache.md](./offline-cache.md)). Cached, but **evictable** — deliberately not shown as "Downloaded", which would promise more than it can keep. |
| Saved copy, server away | Filled pin | The copy is no longer a convenience: it is the only reason the row still plays. |
| Server unreachable, no copy | Cloud-off | This row will not play right now. |
| Session rejected, no copy | Lock | The server *answered* — sign in again, rather than checking the network. |
| Probe in flight | Cloud-sync | We do not know yet. Never shown as a failure. |

A saved copy outranks the server's state on purpose: once a row plays anyway,
whether the server is up has stopped being the interesting fact.

**It is derived, never probed.** Every input already exists — the per-source
availability the probe controller publishes
(`core/sources/source_availability.dart`) and the live offline-cache set the
download repository maintains. No row performs a network check of its own, and
the state is read through Riverpod, so a server that comes back **updates every
visible row with no restart, no reconnect and no rescan**. The glyph is scoped to
its own row's source, so a probe of one server never rebuilds another's rows.

**Nothing secret is reachable from it.** The only text the glyph announces is a
fixed, human-readable server name — "Jellyfin", "Navidrome", "Plex" — taken from
`PlaybackSourceLabel`, the same safe vocabulary the now-playing "Playing from …"
indicator uses. A server URL, host, username, token, or file path is never
formatted into it.

Two things it deliberately does **not** do yet:

- **Album and artist rows have no indicator.** An album mixes tracks, so
  "available" would first have to mean something specific — every track, or the
  primary copy — which is a design question rather than a wiring one.
- **Only Jellyfin reports a real probe.** Every other source is treated as
  reachable by construction, so its rows stay silent until it adopts the same
  probe. Nothing here is Jellyfin-specific: a source that starts publishing
  availability gets its indicators for free.

## Known limitations

- **Metadata quality depends on the source.** Grouping is only as good as the
  album/artist tags the source provides.
- **Local files group from their tags or folders.** Linthra reads on-device
  audio tags (title/artist/album/track number/duration) during the scan and, when
  a tag is missing, falls back to the file name and the `…/Artist/Album/Track`
  folder layout — so a tagged or well-organized local library groups normally. A
  file with neither tags nor folder context still folds into a single
  **Unknown Album** / **Unknown Artist**. A local file's **embedded** cover art
  is read during the scan and shown like any other cover (see
  [local-music.md](./local-music.md)).
- **Artwork may be missing** for some tracks (a local file with no embedded
  cover, or a Subsonic/Navidrome track); a calm placeholder is shown instead,
  and the layout never jumps.
- **Album IDs need a re-sync, and artists still group by name.** A track picks
  up its source album ID on the next library sync, so albums grouped before
  upgrading keep using the name-based tiers until then. Artist grouping still
  keys on the folded name only — persisting source *artist* IDs (for sharper
  disambiguation and richer artist art) is a follow-up.
- **Subsonic reports no album artist.** The classic Subsonic API carries no
  per-song album-artist field, so Subsonic tracks rely on the album ID tier;
  a server that omits `albumId` falls back to track-artist grouping.

## Future

- Playlists / favorites integration from album & artist views.
- Genre browsing.
- Advanced filters and sort options (by year, recently added, duration).
