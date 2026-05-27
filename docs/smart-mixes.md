# Smart mixes (automatic playlists)

Linthra builds a handful of **smart mixes** — automatic, "Made by Linthra"
collections that need no manual curation. They live under **Playlists → Smart
mixes** and each one opens to a track list with **Play** and **Shuffle**, just
like a regular playlist or album.

## The mixes

| Mix | What it contains | Signal it's built from |
| --- | --- | --- |
| **Recently added** | Newest tracks in your library, newest first | First-seen timestamp recorded on each scan/sync |
| **Recently played** | Tracks you've finished, most recent first | On-device play history (`lastPlayedAt`) |
| **Most played** | The songs you reach for most | On-device play history (`playCount`) |
| **Favorites** | Everything you've liked | The existing favourites repository |
| **Downloaded** | Tracks available offline | The offline download/cache state |
| **Random mix** | A bounded shuffle of your library | The catalog (a fresh shuffle each visit) |
| **Never played** | Tracks you haven't heard yet | Tracks absent from play history |

Every mix works across **local**, **Jellyfin**, and **Navidrome/Subsonic**
tracks wherever the underlying data exists — the mixes are derived from the
unified catalog plus on-device signals, never from a single source.

Mixes are always shown (even when empty) so the section is stable and
discoverable; an empty mix opens to a friendly explanation of how to fill it.
The open-ended mixes (recently added/played, most played, random, never played)
are capped (100 tracks) so a mix stays a digestible set — and so the random mix
is always bounded. Favourites and Downloaded are user-curated, so they show
everything.

## Play history

Two new on-device signals back the play-history mixes:

- **`playCount`** — incremented when a track reaches its natural end.
- **`lastPlayedAt`** — set to "now" on that same completion.
- **Recently played** is the play history ordered by `lastPlayedAt`.

A play is counted on **completion**, not on start or skip: skipping a track
forward does **not** count as a play, while each full loop under repeat-one
does. Completion is observed at the one place that can tell a genuine end from a
skip — the playback engine's completion handler — and recorded through
`PlayHistoryRepository`.

## Privacy

Play history and library-added timestamps are **on-device only**:

- They store **only non-secret track ids**, play counts, and timestamps —
  never a track `uri`, a token, or an authenticated stream URL.
- Nothing is uploaded: **no telemetry, no server sync.** (A provider that
  explicitly supports play counts could sync them in the future; until then it
  stays local.)
- Catalog track `uri`s themselves are opaque ids (`jellyfin:<id>`,
  `subsonic:<id>`, or a local `file://`/content path) — the authenticated
  stream URL is minted only at play time and never stored — so a resolved mix
  carries no secret either.

## Where it lives

- **Model** — `lib/core/models/smart_playlist.dart` (the mix kinds + copy) and
  `lib/core/models/play_history.dart` (counts + last-played).
- **Resolver** — `lib/core/services/smart_playlist_resolver.dart` turns the
  signals into an ordered track list per mix (pure and unit-tested).
- **Persistence** — `PlayHistoryStore` / `LibraryAddedStore` (in-memory for
  tests, `shared_preferences` in the app), mirroring the favourites store.
- **Recording** — `RecordingMusicLibraryRepository` stamps newly-seen tracks on
  sync; `JustAudioPlaybackController` records completions into
  `PlayHistoryRepository`.
- **UI** — `lib/features/smart_mixes/` (the list and detail screens, reached
  from the Playlists tab).
