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

/// Maps *every source copy's* track id to its song's ordered source candidates,
/// so playback can fall back to another copy of the same song when the preferred
/// one fails — no matter which copy was the one actually queued.
///
/// Keying by every copy's id (not just the displayed/primary one) is what keeps
/// the queue honest when the user changes the default source: the displayed copy
/// flips to the new provider, but a copy already sitting in the queue (or saved in
/// a playlist) keeps its old id. Mapping that id to the *same* freshly-ordered
/// candidate list means the next play of that queued copy uses the new preferred
/// source — and still has its fallbacks — instead of being orphaned to the old
/// source until the queue is rebuilt (an app restart).
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

  final Map<String, List<Track>> byTrackId = <String, List<Track>>{};
  for (final LogicalTrack logical in logicals) {
    if (!logical.hasMultipleSources) continue;
    final List<Track> candidates = <Track>[
      for (final TrackSourceCandidate c in logical.candidates)
        c.track.copyWith(artworkUri: logical.displayArtworkUri),
    ];
    // Reorder by the chosen strategy. preferDefault is the identity, so the
    // PR1/PR2 default-source order (and runtime fallback over it) is unchanged.
    final List<Track> ordered =
        orderBySourceStrategy(candidates, strategy, profileOf);
    // Index the same list under every copy's id, so whichever copy is queued
    // resolves to it. Ids are unique to one logical song, so the keys never
    // collide across rows.
    for (final Track candidate in candidates) {
      byTrackId[candidate.id] = ordered;
    }
  }
  return byTrackId;
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
