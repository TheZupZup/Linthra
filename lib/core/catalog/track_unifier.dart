import '../models/track.dart';
import 'logical_track.dart';
import 'source_priority.dart';
import 'track_identity.dart';

/// Collapses a flat list of source [Track]s (the per-provider catalog rows the
/// repository stores) into [LogicalTrack]s — one displayed item per song, with
/// every provider copy retained as an ordered playback candidate.
///
/// The rules are deliberately conservative (see [logicalMatchKey]):
///
///  * A track with too little metadata to match (`logicalMatchKey == null`) is
///    always its own logical track. Untagged local files never merge.
///  * Tracks merge only when they share a match key **and** come from two or
///    more *distinct* providers. A group that is entirely one provider's rows is
///    never merged — so a single-provider (or local-only) library is returned
///    one-logical-track-per-row, byte-for-byte as before. This is the safety
///    invariant that guarantees we never make an existing library worse.
///  * Within a merged group the candidates are ordered by [priority], so
///    [LogicalTrack.primary] is the active/default provider's copy when it has
///    one, and a deterministic fallback otherwise.
///
/// Output order follows the first appearance of each logical track in [tracks],
/// so a caller that relied on the catalog's order (before re-sorting for the A–Z
/// list, say) sees the same ordering it always did.
List<LogicalTrack> unifyTracks(List<Track> tracks, SourcePriority priority) {
  // First pass: bucket eligible tracks by match key, preserving encounter order.
  final Map<String, List<Track>> byKey = <String, List<Track>>{};
  for (final Track track in tracks) {
    final String? key = logicalMatchKey(track);
    if (key == null) continue;
    byKey.putIfAbsent(key, () => <Track>[]).add(track);
  }

  // Second pass: emit logical tracks in first-appearance order. A key that spans
  // two or more sources merges (once, at its first occurrence); everything else
  // — ineligible tracks and single-source groups — stays one row per track.
  final Set<String> emittedMergedKeys = <String>{};
  final List<LogicalTrack> result = <LogicalTrack>[];
  for (final Track track in tracks) {
    final String? key = logicalMatchKey(track);
    if (key == null) {
      result.add(LogicalTrack.single(_candidate(track)));
      continue;
    }
    final List<Track> members = byKey[key]!;
    if (_distinctSourceCount(members) < 2) {
      // Single-provider group: never merge — each row stands alone.
      result.add(LogicalTrack.single(_candidate(track)));
      continue;
    }
    if (!emittedMergedKeys.add(key)) continue; // already emitted at first sight
    result.add(LogicalTrack(_orderedCandidates(members, priority)));
  }
  return result;
}

TrackSourceCandidate _candidate(Track track) =>
    TrackSourceCandidate(track: track, sourceId: trackSourceId(track));

int _distinctSourceCount(List<Track> members) {
  final Set<String> sources = <String>{};
  for (final Track t in members) {
    sources.add(trackSourceId(t));
  }
  return sources.length;
}

/// Orders a merged group's copies best-first by source preference, breaking ties
/// on the track id so the result is total and deterministic.
List<TrackSourceCandidate> _orderedCandidates(
  List<Track> members,
  SourcePriority priority,
) {
  final List<TrackSourceCandidate> candidates = <TrackSourceCandidate>[
    for (final Track t in members) _candidate(t)
  ];
  candidates.sort((TrackSourceCandidate a, TrackSourceCandidate b) {
    final int byRank =
        priority.rankOf(a.sourceId).compareTo(priority.rankOf(b.sourceId));
    if (byRank != 0) return byRank;
    return a.track.id.compareTo(b.track.id);
  });
  return candidates;
}
