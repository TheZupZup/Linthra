import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/cache_size.dart';
import '../../core/models/track.dart';
import '../../core/repositories/download_repository.dart';
import '../../core/repositories/download_store.dart';
import '../../core/services/offline_cache_manager.dart';
import '../../core/sources/jellyfin/jellyfin_track_downloader.dart';
import '../../data/repositories/download_repository_provider.dart';
import '../../data/repositories/music_library_repository_provider.dart';
import '../settings/jellyfin/jellyfin_settings_controller.dart';

/// The live download status of a single track, for the Library row indicator.
/// Defaults to [DownloadStatus.notDownloaded] until the repository reports
/// otherwise. Auto-disposed so off-screen rows drop their subscription.
final trackDownloadStatusProvider =
    StreamProvider.autoDispose.family<DownloadStatus, String>((ref, trackId) {
  final repository = ref.watch(downloadRepositoryProvider);
  return repository.statusStream
      .map((statuses) => statuses[trackId] ?? DownloadStatus.notDownloaded)
      .distinct();
});

/// The catalog tracks that are fully available offline, recomputed whenever the
/// download status map changes. Powers the Downloads screen list.
final downloadedTracksProvider = StreamProvider<List<Track>>((ref) async* {
  final repository = ref.watch(downloadRepositoryProvider);
  final library = ref.watch(musicLibraryRepositoryProvider);
  await for (final statuses in repository.statusStream) {
    final downloadedIds = statuses.entries
        .where((e) => e.value == DownloadStatus.downloaded)
        .map((e) => e.key)
        .toSet();
    final tracks = await library.getAllTracks();
    yield tracks.where((t) => downloadedIds.contains(t.id)).toList();
  }
});

/// Live offline-cache usage + per-track metadata (size, pinned, timestamps),
/// re-emitted whenever the cache changes. Powers the Settings cache card and
/// the per-row size/pin affordances on the Downloads screen.
final cacheSnapshotProvider = StreamProvider<CacheSnapshot>((ref) {
  return ref.watch(offlineCacheManagerProvider).cacheStream;
});

/// The cached-track metadata keyed by track id, for quick per-row lookups.
final cacheEntriesByIdProvider = Provider<Map<String, CachedTrack>>((ref) {
  final snapshot = ref.watch(cacheSnapshotProvider).valueOrNull;
  if (snapshot == null) return const <String, CachedTrack>{};
  return <String, CachedTrack>{
    for (final entry in snapshot.entries) entry.trackId: entry,
  };
});

/// Owns the "Maximum cache size" limit: loads the persisted value and writes
/// changes back through [DownloadPreferences]. Clamped to the supported range.
class MaxCacheBytesController extends AsyncNotifier<int> {
  @override
  Future<int> build() {
    return ref.read(downloadPreferencesProvider).maxCacheBytes();
  }

  Future<void> setLimit(int bytes) async {
    final int clamped = CacheSize.clamp(bytes);
    await ref.read(downloadPreferencesProvider).setMaxCacheBytes(clamped);
    state = AsyncData<int>(clamped);
  }
}

final maxCacheBytesControllerProvider =
    AsyncNotifierProvider<MaxCacheBytesController, int>(
  MaxCacheBytesController.new,
);

/// Owns the "Wi-Fi only downloads" switch: loads the persisted value and writes
/// changes back through [DownloadPreferences].
class WifiOnlyController extends AsyncNotifier<bool> {
  @override
  Future<bool> build() {
    return ref.read(downloadPreferencesProvider).wifiOnly();
  }

  Future<void> setWifiOnly(bool value) async {
    await ref.read(downloadPreferencesProvider).setWifiOnly(value);
    state = AsyncData<bool>(value);
  }
}

final wifiOnlyControllerProvider =
    AsyncNotifierProvider<WifiOnlyController, bool>(WifiOnlyController.new);

/// Production binding: makes Jellyfin tracks downloadable for offline use by
/// wiring the remote downloader to the live signed-in source (read through
/// [jellyfinMusicSourceProvider], so sign-in/out is picked up without a
/// rebuild). The token-bearing download URL is minted only at fetch time inside
/// the downloader; nothing here stores it. Applied in `main`; tests override
/// [remoteTrackDownloaderProvider] with their own fake.
final jellyfinRemoteTrackDownloaderOverride =
    remoteTrackDownloaderProvider.overrideWith((ref) {
  // Read (not watch) the live source lazily at fetch time, mirroring the
  // playback resolver — so the downloader is built once and signing in/out
  // doesn't rebuild it (which would reset in-flight download state).
  return JellyfinTrackDownloader(() => ref.read(jellyfinMusicSourceProvider));
});
