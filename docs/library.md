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

### Fast-scroll rail

The A–Z fast-scroller is kept on the **Songs** tab, where an alphabetical track
list benefits from it. It hides automatically when there are too few sections
(for example, while a search narrows the list to a handful of results), so it
never gets in the way. The Albums and Artists tabs are short, grouped lists and
don't use the rail.

## How grouping works

Albums and artists are **derived from the track catalog** rather than stored as
separate rows. Grouping keys are built from the tracks' own album/artist names
(folded for case and accents), so:

- the same album title by two different artists stays distinct (two "Greatest
  Hits" don't merge), and
- case/accent differences in tags don't split one album into two.

This is source-uniform: it works the same for Jellyfin/Subsonic tracks and
local files.

## Jellyfin / Subsonic metadata

Tracks synced from a Jellyfin or Subsonic/Navidrome server carry real album and
artist names and a token-free cover-art URL, so they group into proper albums
and artists with artwork. No authenticated URL or token is ever stored on a
track or surfaced in the Library — a Jellyfin track's stored reference is an
opaque `jellyfin:<id>`, and stream URLs (which carry the access token) are minted
only at play time.

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
- **No stable source album/artist IDs yet.** Grouping uses folded names because
  source album/artist IDs (e.g. Jellyfin's `AlbumId`) aren't persisted on a
  track today. Persisting them — for sharper disambiguation and richer
  album/artist art — is a follow-up.

## Future

- Playlists / favorites integration from album & artist views.
- Genre browsing.
- Advanced filters and sort options (by year, recently added, duration).
