import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/catalog/logical_track.dart';
import '../../core/models/track.dart';
import '../../core/services/playback_candidate_source.dart';
import '../player/player_providers.dart';
import 'unified_library_providers.dart';

/// Maps each *displayed* (logical) track id to its ordered source candidates, so
/// playback can fall back to another copy of the same song when the preferred one
/// fails.
///
/// Only de-duplicated rows that actually span more than one provider are listed —
/// a single-source song needs no fallback and is left out (the controller treats
/// an absent id as "no fallback"). Candidates are in the same deterministic,
/// most-preferred-first order [unifyTracks] produced (honouring the default-source
/// setting), and each carries the row's best-available cover
/// ([LogicalTrack.displayArtworkUri]) so a fallback copy keeps the artwork the
/// displayed row showed. The map recomputes whenever the library or the source
/// preference changes.
final playbackCandidatesProvider = Provider<Map<String, List<Track>>>((ref) {
  final List<LogicalTrack> logicals = ref.watch(libraryLogicalTracksProvider);
  final Map<String, List<Track>> byDisplayId = <String, List<Track>>{};
  for (final LogicalTrack logical in logicals) {
    if (!logical.hasMultipleSources) continue;
    byDisplayId[logical.id] = <Track>[
      for (final TrackSourceCandidate c in logical.candidates)
        c.track.copyWith(artworkUri: logical.displayArtworkUri),
    ];
  }
  return byDisplayId;
});

/// Wires the real, library-backed [PlaybackCandidateSource] into the playback
/// controller, replacing the no-fallback default. Applied in `main`.
///
/// The candidate source reads [playbackCandidatesProvider] lazily on every
/// lookup, so the session-pinned controller always sees the latest catalog and
/// default-source choice without being rebuilt.
final playbackCandidateSourceOverride =
    playbackCandidateSourceProvider.overrideWith(
  (ref) =>
      MapPlaybackCandidateSource(() => ref.read(playbackCandidatesProvider)),
);
