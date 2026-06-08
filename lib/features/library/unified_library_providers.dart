import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/catalog/logical_track.dart';
import '../../core/catalog/track_unifier.dart';
import '../../core/models/track.dart';
import 'library_controller.dart';
import 'source_preference_controller.dart';

/// The library as unified [LogicalTrack]s: one item per song, with every
/// provider copy retained as an ordered playback candidate.
///
/// This is the single place display-level de-duplication happens. It recomputes
/// whenever the catalog reloads (scan, sync, removal) or the source preference
/// changes, so every browse surface that reads it stays consistent. The
/// repository still stores all per-provider rows untouched — nothing is deleted.
final libraryLogicalTracksProvider = Provider<List<LogicalTrack>>((ref) {
  final List<Track> tracks = ref.watch(libraryControllerProvider).tracks;
  final priority = ref.watch(librarySourcePriorityProvider);
  return unifyTracks(tracks, priority);
});

/// The de-duplicated catalog the Library UI renders and plays: the preferred
/// copy ([LogicalTrack.primaryTrack]) of each logical track, in catalog order.
///
/// Tapping one of these plays the active/default provider's copy (or the best
/// available fallback) because the primary *is* that copy. The Songs/Albums/
/// Artists tabs, search, and the album/artist detail screens all read from here
/// so none of them shows the same song twice.
final libraryUnifiedTracksProvider = Provider<List<Track>>((ref) {
  return <Track>[
    for (final LogicalTrack logical in ref.watch(libraryLogicalTracksProvider))
      logical.primaryTrack,
  ];
});

/// Maps a preferred-copy track id to every source copy's track id, so removing a
/// displayed (logical) row from the library forgets all of its provider copies —
/// otherwise a hidden duplicate would resurrect the row on the next reload.
///
/// Ids that aren't a logical primary (e.g. a specific track chosen inside a
/// playlist) map to just themselves, so non-library callers are unaffected.
final logicalSourceIdsProvider = Provider<Map<String, List<String>>>((ref) {
  final Map<String, List<String>> byPrimary = <String, List<String>>{};
  for (final LogicalTrack logical in ref.watch(libraryLogicalTracksProvider)) {
    byPrimary[logical.id] = logical.allTrackIds;
  }
  return byPrimary;
});
