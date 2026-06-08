import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/catalog/logical_track.dart';
import '../../core/catalog/source_capability.dart';
import '../../core/catalog/source_strategy.dart';
import '../../core/models/track.dart';
import '../../core/services/playback_candidate_source.dart';
import '../downloads/download_providers.dart';
import '../player/player_providers.dart';
import 'playback_source_strategy_controller.dart';
import 'unified_library_providers.dart';

/// Maps each *displayed* (logical) track id to its ordered source candidates, so
/// playback can fall back to another copy of the same song when the preferred one
/// fails.
///
/// Only de-duplicated rows that actually span more than one provider are listed —
/// a single-source song needs no fallback and is left out (the controller treats
/// an absent id as "no fallback"). Each candidate carries the row's best-available
/// cover ([LogicalTrack.displayArtworkUri]) so a fallback copy keeps the artwork
/// the displayed row showed.
///
/// Candidates start in the deterministic, most-preferred-first order
/// [unifyTracks] produced (honouring the default-source setting), then the chosen
/// [PlaybackSourceStrategy] reorders them ([orderBySourceStrategy]) — e.g. a
/// downloaded/local copy first under "prefer local/cache". `preferDefault` is the
/// identity, so the PR1/PR2 order (and runtime fallback over it) is unchanged.
/// The map recomputes whenever the library, the source preference, the strategy,
/// or the offline-available set changes.
final playbackCandidatesProvider = Provider<Map<String, List<Track>>>((ref) {
  final List<LogicalTrack> logicals = ref.watch(libraryLogicalTracksProvider);
  final PlaybackSourceStrategy strategy =
      ref.watch(playbackSourceStrategyProvider);
  final Set<String> cachedIds = ref.watch(offlineAvailableTrackIdsProvider);

  // A candidate's capability, made cache-aware from the in-memory offline set so
  // "prefer cache/local" can favour a downloaded copy without a disk scan.
  PlaybackSourceCapability profileOf(Track track) =>
      PlaybackSourceCapability.fromTrack(
        track,
        cachedOffline: cachedIds.contains(track.id),
      );

  final Map<String, List<Track>> byDisplayId = <String, List<Track>>{};
  for (final LogicalTrack logical in logicals) {
    if (!logical.hasMultipleSources) continue;
    final List<Track> candidates = <Track>[
      for (final TrackSourceCandidate c in logical.candidates)
        c.track.copyWith(artworkUri: logical.displayArtworkUri),
    ];
    // Reorder by the chosen strategy. preferDefault is the identity, so the
    // PR1/PR2 default-source order (and runtime fallback over it) is unchanged.
    byDisplayId[logical.id] =
        orderBySourceStrategy(candidates, strategy, profileOf);
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
