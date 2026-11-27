import '../models/track.dart';
import '../native/native_track_unifier.dart';
import 'logical_track.dart';
import 'source_priority.dart';
import 'track_identity.dart';

/// Collapses a flat list of source [Track]s (the per-provider catalog rows the
/// repository stores) into [LogicalTrack]s — one displayed item per song, with
/// every provider copy retained as an ordered playback candidate.
///
/// Runs in the Rust core (native/linthra_core/src/track_unifier.rs). The
/// rules are deliberately conservative:
///
///  * A track with too little metadata to match (no title or artist words) is
///    always its own logical track. Untagged local files never merge.
///  * Tracks merge only when they are a confident match (same folded title,
///    artist overlap, and agreeing album, length and track number)
///    **and** come from two or more *distinct* providers. Two rows from the same
///    provider are never merged (a single source is assumed already
///    de-duplicated), so a single-provider (or local-only) library is returned
///    one-logical-track-per-row, byte-for-byte as before. This is the safety
///    invariant that guarantees we never make an existing library worse.
///  * Within a merged group the candidates are ordered by [priority], so
///    [LogicalTrack.primary] is the active/default provider's copy when it has
///    one, and a deterministic fallback otherwise.
///
/// ## How matching stays deterministic without an exact key
///
/// Scored matching is not a single equivalence key, so grouping is done in two
/// order-independent steps:
///
///  1. **Block.** Eligible tracks are bucketed by folded primary artist and
///     first title token, which co-locates plausible matches
///     and keeps each bucket small.
///  2. **Anchor-group within a block.** The block's tracks are sorted by a stable
///     `(priority rank, id)` order, then each is attached to the first existing
///     group whose *anchor* it confidently matches and whose provider it does not
///     already duplicate — otherwise it starts a new group. Comparing against a
///     single anchor (rather than chaining transitively) keeps grouping
///     conservative and independent of the input order.
///
/// Output order follows the first appearance of each logical track in [tracks],
/// so a caller that relied on the catalog's order (before re-sorting for the A–Z
/// list, say) sees the same ordering it always did.
List<LogicalTrack> unifyTracks(List<Track> tracks, SourcePriority priority) {
  final List<String> sourceIds = <String>[
    for (final Track t in tracks) trackSourceId(t),
  ];
  final Map<String, int> sourceCodes = <String, int>{};
  final List<List<int>> rows = NativeTrackUnifier.unify(<NativeUnifyTrack>[
    for (int i = 0; i < tracks.length; i++)
      (
        uri: tracks[i].uri,
        title: tracks[i].title,
        artist: tracks[i].artistName ?? '',
        album: tracks[i].albumName ?? '',
        source: sourceCodes.putIfAbsent(sourceIds[i], () => sourceCodes.length),
        rank: priority.rankOf(sourceIds[i]),
        durationSeconds: tracks[i].duration.inSeconds,
        trackNumber: tracks[i].trackNumber,
      ),
  ]);
  return <LogicalTrack>[
    for (final List<int> row in rows)
      LogicalTrack(<TrackSourceCandidate>[
        for (final int i in row)
          TrackSourceCandidate(track: tracks[i], sourceId: sourceIds[i]),
      ]),
  ];
}
