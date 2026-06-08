# Unified library & source model

Linthra can play the same music from more than one place at once — a local
folder, a Jellyfin server, a Navidrome/Subsonic server. When two servers expose
the **same** library (a very common self-hosting setup), the same song arrives
through two providers. This note explains how Linthra shows that song **once**
while keeping every playable copy, and how it decides which copy to play.

> TL;DR — Linthra **stores** provider-specific *source tracks* but **displays**
> *logical tracks*. De-duplication is a pure, display-time transform; nothing is
> deleted from the catalog, and a single-provider or local-only library behaves
> exactly as it did before.

## The three layers

| Concept | What it is | Where |
| ------- | ---------- | ----- |
| **Source track** | One physical/provider-specific copy of a song (a `Track` with its opaque `jellyfin:` / `subsonic:` / local-path URI). The repository stores these, one row per provider copy. | `core/models/track.dart` |
| **`TrackSourceCandidate`** | A source track paired with the `sourceId` that owns it — a playable candidate for a logical track. | `core/catalog/logical_track.dart` |
| **`LogicalTrack`** | One displayed library item, wrapping one or more candidates ordered best-first. `primary` is the copy the row shows and plays; the rest are deterministic fallbacks. | `core/catalog/logical_track.dart` |

The repository (`MusicLibraryRepository`) is unchanged: it still stores every
per-provider row under its `sourceId`, and `getAllTracks()` still returns them
all. **No schema change and no migration** were needed — de-duplication happens
above storage, at display time.

## How de-duplication works

`unifyTracks(tracks, priority)` (`core/catalog/track_unifier.dart`) collapses the
flat catalog into `LogicalTrack`s. The browse UI reads the result through
`libraryUnifiedTracksProvider`; the Songs/Albums/Artists tabs, search, and the
album/artist detail screens all render the de-duplicated primaries, so none of
them shows a song twice.

The matching is deliberately **conservative** — it would rather leave two rows
separate than merge songs that might be different:

- A **match key** (`logicalMatchKey`) is built from the *folded* title, artist,
  and album plus a coarse (2-second) duration bucket. Case and accents are
  folded (`Beyoncé` ≡ `beyonce`); distinguishing words are **kept**, so
  `Hello`, `Hello (Live)`, and `Hello (Radio Edit)` never collapse together.
- A track with too little metadata to match — **missing** title, artist, album,
  **or** a zero/unknown duration — gets **no key** and is **always** its own
  row. Untagged local files therefore never merge.
- Two tracks merge **only** when they share a key **and** come from **two or
  more distinct providers**. A group that is entirely one provider's rows is
  never merged. This is the safety invariant that guarantees an existing
  single-provider (or local-only) library is returned one-row-per-track,
  unchanged.

Removing a logical row from the library forgets **every** provider copy (via
`logicalSourceIdsProvider`), so a hidden duplicate can't resurrect the row on the
next reload. (Re-syncing a server brings its copy back, exactly as before.)

## Source preference & fallback

When a logical track has several candidates, the order is decided by
`SourcePriority` (`core/catalog/source_priority.dart`):

1. **Active/default first.** The server you **most recently signed into** is
   promoted to the front of your preference (`SourcePreferenceController.markPreferred`,
   called on a successful Jellyfin/Subsonic sign-in) and persisted across
   restarts (`PreferredSourceStore`). So if you connect Navidrome after already
   using Jellyfin, a song on both now prefers **Navidrome**.
2. **Deterministic fallback tail.** Anything not in your preference falls back to
   a fixed order (`jellyfin`, `subsonic`, `local`), with local last so a server
   copy — which can also cast and sync — is preferred over a device copy of the
   same song. Ties break on the track id, so the choice is always total and
   predictable.

`primary = candidates.first` is the chosen copy. Selecting a logical row plays
**that** copy, so playback prefers the active/default provider and **falls back**
to another source when the preferred one does not have the song:

- Song on Navidrome **and** Jellyfin, Navidrome active → plays from Navidrome.
- Song only on Jellyfin → plays from Jellyfin (even if Navidrome is active).
- Song only on Navidrome → plays from Navidrome.
- Song only local → plays from the device.

> Fallback here is **selection-time** (pick the best source that *has* the song).
> Runtime fail-over (preferred server unreachable mid-resolve → automatically try
> another copy) is **not** in this change; the offline cache already provides
> resilience (see below). It is a noted follow-up.

## Offline cache mapping

The offline cache is keyed by a **source track id**. A logical track maps to
whichever candidate is its `primary`, and the offline-first resolver
(`OfflineFirstPlayableUriResolver`) prefers that candidate's cached copy when one
exists. So downloading the played copy works unchanged; the cache is per-source,
and the logical layer simply chooses *which* source is in play.

## Playback source indicator

Because a logical track can resolve to different sources, the now-playing UI
shows the copy **actually** playing — not the active/default provider.
`PlaybackSourceLabel` (`core/services/playback_source_label.dart`) derives a safe
name from the resolved track's URI and the `PlaybackSource` the resolver
reported:

- on-device file → **Local files**
- cached copy → **Cache** (whichever server it came from)
- live Jellyfin stream → **Jellyfin**
- live Navidrome/Subsonic stream → **Navidrome**

The Now Playing screen shows a "Playing from …" chip and the mini-player a faint
tag beside the metadata. Only fixed display names are ever shown — never a server
URL, IP, username, token, or path.

## Scope / follow-ups

- The **in-app** Library (the reported duplicate problem) is de-duplicated. The
  **Android Auto** browse tree (`core/services/media_browser_tree.dart`) still
  lists per-provider rows; unifying it cleanly (its `_allTracks()` also backs
  favourites/downloads/playlist id-resolution) is a tracked follow-up that can
  reuse `unifyTracks`.
- An explicit user-facing "preferred provider" setting could replace the
  implicit most-recently-signed-in rule later; the model already supports it.
- Source-specific views ("show all copies of this song") can be built on the
  retained `LogicalTrack.candidates` without further storage changes.
