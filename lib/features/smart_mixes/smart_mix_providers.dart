import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/play_history.dart';
import '../../core/models/smart_playlist.dart';
import '../../core/models/track.dart';
import '../../core/repositories/download_repository.dart';
import '../../core/services/smart_playlist_resolver.dart';
import '../../data/repositories/download_repository_provider.dart';
import '../../data/repositories/library_added_store_provider.dart';
import '../../data/repositories/music_library_repository_provider.dart';
import '../../data/repositories/play_history_repository_provider.dart';
import '../player/favorites_providers.dart';

/// The shared resolver. Stateless and const, so every mix is computed the same
/// way; the random seed is supplied per call by the providers below.
const SmartPlaylistResolver _resolver = SmartPlaylistResolver();

/// Streams the on-device play history for the UI; emits on every recorded play
/// so "Recently played" / "Most played" / "Never played" stay live.
final playHistoryProvider = StreamProvider<PlayHistory>((ref) {
  return ref.watch(playHistoryRepositoryProvider).historyStream;
});

/// The set of fully-downloaded (offline) cache keys, recomputed whenever the
/// download status map changes, so the "Downloaded" mix tracks the cache. The
/// status map's keys are the provider-aware cache keys, so a download of one
/// provider's copy never pulls a same-id copy from another provider into the mix.
final _downloadedTrackKeysProvider = StreamProvider<Set<String>>((ref) {
  final DownloadRepository repository = ref.watch(downloadRepositoryProvider);
  return repository.statusStream.map((Map<String, DownloadStatus> statuses) {
    return <String>{
      for (final MapEntry<String, DownloadStatus> entry in statuses.entries)
        if (entry.value == DownloadStatus.downloaded) entry.key,
    };
  });
});

/// The signals every (non-random) mix is derived from, gathered once. Re-runs
/// when favourites, play history, or the downloaded set change so the mixes and
/// their counts stay live; the catalog and added-timestamps are read on demand.
typedef SmartPlaylistInputs = ({
  List<Track> allTracks,
  PlayHistory history,
  Map<String, DateTime> addedAt,
  Set<String> favoriteIds,
  Set<String> downloadedKeys,
});

final smartPlaylistInputsProvider =
    FutureProvider<SmartPlaylistInputs>((ref) async {
  // Establish every dependency synchronously, before any await, so the provider
  // reacts to all of them (Riverpod tracks watches made during the sync phase).
  final library = ref.watch(musicLibraryRepositoryProvider);
  final addedStore = ref.watch(libraryAddedStoreProvider);
  final PlayHistory history =
      ref.watch(playHistoryProvider).valueOrNull ?? PlayHistory.empty;
  final Set<String> favoriteIds =
      ref.watch(favoriteIdsProvider).valueOrNull ?? const <String>{};
  final Set<String> downloadedKeys =
      ref.watch(_downloadedTrackKeysProvider).valueOrNull ?? const <String>{};

  final List<Track> allTracks = await library.getAllTracks();
  final Map<String, DateTime> addedAt = await addedStore.load();

  return (
    allTracks: allTracks,
    history: history,
    addedAt: addedAt,
    favoriteIds: favoriteIds,
    downloadedKeys: downloadedKeys,
  );
});

/// A mix paired with how many tracks it currently holds, for the list screen.
typedef SmartMixSummary = ({SmartPlaylist mix, int trackCount});

/// Every smart mix with its live track count, in display order. Shows all mixes
/// (even empty ones) so the section is stable and discoverable; an empty mix
/// presents a friendly empty state when opened.
final smartMixesProvider = FutureProvider<List<SmartMixSummary>>((ref) async {
  final SmartPlaylistInputs inputs =
      await ref.watch(smartPlaylistInputsProvider.future);
  return <SmartMixSummary>[
    for (final SmartPlaylist mix in SmartPlaylist.all)
      (mix: mix, trackCount: _resolve(mix.kind, inputs).length),
  ];
});

/// The resolved tracks for one mix. Auto-disposed so each visit recomputes —
/// which gives the random mix a fresh shuffle every time it's opened while
/// keeping it stable for the duration of that visit.
final smartPlaylistTracksProvider = FutureProvider.autoDispose
    .family<List<Track>, SmartPlaylistKind>(
        (ref, SmartPlaylistKind kind) async {
  // The random mix needs only the catalog; not watching the other signals
  // keeps it from reshuffling when an unrelated favourite or play is recorded.
  if (kind == SmartPlaylistKind.random) {
    final library = ref.watch(musicLibraryRepositoryProvider);
    final List<Track> allTracks = await library.getAllTracks();
    return _resolver.resolve(
      kind,
      allTracks: allTracks,
      history: PlayHistory.empty,
      addedAt: const <String, DateTime>{},
      favoriteIds: const <String>{},
      downloadedKeys: const <String>{},
      random: Random(),
    );
  }
  final SmartPlaylistInputs inputs =
      await ref.watch(smartPlaylistInputsProvider.future);
  return _resolve(kind, inputs);
});

List<Track> _resolve(SmartPlaylistKind kind, SmartPlaylistInputs inputs) {
  return _resolver.resolve(
    kind,
    allTracks: inputs.allTracks,
    history: inputs.history,
    addedAt: inputs.addedAt,
    favoriteIds: inputs.favoriteIds,
    downloadedKeys: inputs.downloadedKeys,
    random: Random(),
  );
}
