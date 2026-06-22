import '../models/track.dart';
import 'logical_track.dart';
import 'source_priority.dart';
import 'track_identity.dart';

/// Collapses a flat list of source [Track]s (the per-provider catalog rows the
/// repository stores) into [LogicalTrack]s — one displayed item per song, with
/// every provider copy retained as an ordered playback candidate.
///
/// The rules are deliberately conservative (see [trackMatchScore]):
///
///  * A track with too little metadata to match (`canMatchAcrossProviders` is
///    false) is always its own logical track. Untagged local files never merge.
///  * Tracks merge only when they are a confident match ([isLikelySameTrack])
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
///  1. **Block.** Eligible tracks are bucketed by [matchBlockKey] (folded
///     primary-artist + first-title token), which co-locates plausible matches
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
  // First pass: bucket eligible tracks by block key, then resolve each block
  // into same-song groups. groupByUri maps a track's provider-namespaced uri to
  // the members of its group (a group of one for a track that matched nothing).
  // Keying by uri — not the bare id — keeps two providers' same-id tracks from
  // overwriting each other's group, which would mis-merge or duplicate a row.
  final Map<String, List<Track>> blocks = <String, List<Track>>{};
  for (final Track track in tracks) {
    final String? key = matchBlockKey(track);
    if (key == null) continue;
    blocks.putIfAbsent(key, () => <Track>[]).add(track);
  }
  final Map<String, List<Track>> groupByUri = <String, List<Track>>{};
  for (final List<Track> block in blocks.values) {
    for (final List<Track> group in _groupBlock(block, priority)) {
      for (final Track member in group) {
        groupByUri[member.uri] = group;
      }
    }
  }

  // Second pass: emit logical tracks in first-appearance order. A group that
  // spans two or more sources merges (once, at the first occurrence of any of
  // its members); everything else — ineligible tracks and single-source groups —
  // stays one row per track.
  final Set<String> emittedAnchors = <String>{};
  final List<LogicalTrack> result = <LogicalTrack>[];
  for (final Track track in tracks) {
    final List<Track>? group = groupByUri[track.uri];
    if (group == null || _distinctSourceCount(group) < 2) {
      result.add(LogicalTrack.single(_candidate(track)));
      continue;
    }
    // group.first is the block's stable anchor, so its uri is a deterministic key
    // for "have I already emitted this merged group?".
    if (!emittedAnchors.add(group.first.uri)) continue;
    result.add(LogicalTrack(_orderedCandidates(group, priority)));
  }
  return result;
}

/// Resolves one block (tracks sharing a [matchBlockKey]) into same-song groups.
///
/// Tracks are visited in a stable `(priority rank, id)` order so the grouping is
/// independent of the catalog's order. Each track joins the first existing group
/// whose anchor it confidently matches and whose provider it does not already
/// duplicate; otherwise it opens a new group. Refusing to join a provider already
/// in the group preserves the invariant that a single provider's own rows are
/// never merged together.
List<List<Track>> _groupBlock(List<Track> block, SourcePriority priority) {
  final List<Track> ordered = <Track>[...block]
    ..sort(_byPriorityThenId(priority));
  final List<List<Track>> groups = <List<Track>>[];
  for (final Track track in ordered) {
    final String sourceId = trackSourceId(track);
    List<Track>? target;
    for (final List<Track> group in groups) {
      if (group.any((Track m) => trackSourceId(m) == sourceId)) continue;
      if (isLikelySameTrack(group.first, track)) {
        target = group;
        break;
      }
    }
    if (target != null) {
      target.add(track);
    } else {
      groups.add(<Track>[track]);
    }
  }
  return groups;
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
/// on the provider-namespaced uri so the result is total and deterministic even
/// when two copies share a bare id across providers.
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
    return a.track.uri.compareTo(b.track.uri);
  });
  return candidates;
}

/// A total comparator ordering tracks by source preference, then by uri, so a
/// block's anchor (its first element) is the most-preferred copy and the grouping
/// never depends on the input order. Ties break on the uri (not the bare id) so
/// two providers' same-id tracks still order deterministically.
int Function(Track, Track) _byPriorityThenId(SourcePriority priority) {
  return (Track a, Track b) {
    final int byRank = priority
        .rankOf(trackSourceId(a))
        .compareTo(priority.rankOf(trackSourceId(b)));
    if (byRank != 0) return byRank;
    return a.uri.compareTo(b.uri);
  };
}
