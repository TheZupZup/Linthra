import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/track.dart';
import '../../core/repositories/download_preferences.dart';
import '../../core/repositories/download_repository.dart';
import '../../core/repositories/download_store.dart';
import '../../core/repositories/offline_file_store.dart';
import '../../core/services/cached_track_locator.dart';
import '../../core/services/connectivity_service.dart';
import '../../core/services/offline_cache_manager.dart';
import '../../core/services/optimistic_connectivity_service.dart';
import '../../core/services/remote_track_downloader.dart';
import '../../core/services/track_prefetcher.dart';
import 'cache_download_repository.dart';
import 'file_system_offline_file_store.dart';
import 'in_memory_download_preferences.dart';
import 'in_memory_download_store.dart';
import 'in_memory_offline_file_store.dart';
import 'music_library_repository_provider.dart';
import 'shared_preferences_download_preferences.dart';
import 'shared_preferences_download_store.dart';
import 'store_cached_track_locator.dart';

/// Durable store of which tracks are cached offline (track id + cache file).
/// Defaults to in-memory so tests and dev runs need no plugins; the app
/// overrides it with the `shared_preferences` binding below.
final downloadStoreProvider = Provider<DownloadStore>((ref) {
  return InMemoryDownloadStore();
});

/// Where downloaded bytes live on disk. Defaults to an in-memory store so tests
/// stay plugin-free; the app overrides it with the `path_provider`-backed
/// filesystem store.
final offlineFileStoreProvider = Provider<OfflineFileStore>((ref) {
  return InMemoryOfflineFileStore();
});

/// Fetches bytes for remote (e.g. Jellyfin) tracks. The data layer's default
/// handles no source — keeping it free of any source-specific or feature
/// dependency — so the Jellyfin-backed downloader is wired in as an override at
/// the composition root (see `jellyfinRemoteTrackDownloaderOverride`). Tests
/// override it with a fake that returns canned bytes.
final remoteTrackDownloaderProvider = Provider<RemoteTrackDownloader>((ref) {
  return const _UnsupportedRemoteTrackDownloader();
});

/// The user's download/offline preferences (including "Allow mobile data").
/// In-memory by default; the app persists them via `shared_preferences`.
final downloadPreferencesProvider = Provider<DownloadPreferences>((ref) {
  return InMemoryDownloadPreferences();
});

/// Network reachability used to honor the mobile-data download preference. The
/// default optimistically reports Wi-Fi until real detection lands; tests inject
/// a fake to drive the policy's mobile/offline/unknown paths.
final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  return const OptimisticConnectivityService();
});

/// Supplies the currently playing track so the cache policy never evicts it. A
/// whole [Track] (not just an id) so the policy protects exactly that provider's
/// copy by its provider-aware key — a same-id track from another provider stays
/// evictable. The data layer defaults to "nothing playing" (keeping it free of
/// any playback dependency); the app overrides this to read the live
/// [PlaybackController] (see `currentlyPlayingTrackOverride`). The closure is
/// read lazily at eviction time, so wiring it never rebuilds the repository.
final currentlyPlayingTrackProvider =
    Provider<Track? Function()?>((ref) => null);

/// The single [CacheDownloadRepository] the app drives offline downloads
/// through. It composes the seams above and centralizes the user-initiated,
/// source-aware, Wi-Fi-respecting, limit-bounded cache policy. Held as the
/// concrete type so the cache-manager provider can expose the same instance.
final _cacheDownloadRepositoryProvider =
    Provider<CacheDownloadRepository>((ref) {
  final repository = CacheDownloadRepository(
    store: ref.watch(downloadStoreProvider),
    files: ref.watch(offlineFileStoreProvider),
    downloader: ref.watch(remoteTrackDownloaderProvider),
    connectivity: ref.watch(connectivityServiceProvider),
    preferences: ref.watch(downloadPreferencesProvider),
    currentlyPlayingTrack: ref.watch(currentlyPlayingTrackProvider),
    // One-time migration of legacy (pre-v0.1.6, sourceType-less) cache records to
    // provider-aware keys, inferring each one's provider from the catalog. Read
    // lazily (not watched) so wiring it never rebuilds the repository.
    catalogForMigration: () =>
        ref.read(musicLibraryRepositoryProvider).getAllTracks(),
  );
  ref.onDispose(repository.dispose);
  return repository;
});

/// The download lifecycle surface (request/remove/status) the UI uses.
final downloadRepositoryProvider = Provider<DownloadRepository>((ref) {
  return ref.watch(_cacheDownloadRepositoryProvider);
});

/// The cache-maintenance surface (usage stream, pin, clear, note-played),
/// backed by the *same* instance as [downloadRepositoryProvider] so a cleared
/// or pinned track stays consistent with download status.
final offlineCacheManagerProvider = Provider<OfflineCacheManager>((ref) {
  return ref.watch(_cacheDownloadRepositoryProvider);
});

/// The pre-cache surface (warm an upcoming track ahead of play), backed by the
/// *same* instance as [downloadRepositoryProvider] so pre-cached tracks share
/// the one cache limit and eviction policy with user downloads. Driven by the
/// `SmartPrecacheService`, never by the UI directly.
final trackPrefetcherProvider = Provider<TrackPrefetcher>((ref) {
  return ref.watch(_cacheDownloadRepositoryProvider);
});

/// Resolves a track to its cached-on-disk file when one exists. Read by the
/// playback resolver to prefer the local copy over streaming. Composed from the
/// same durable store + file store the repository writes through.
final cachedTrackLocatorProvider = Provider<CachedTrackLocator>((ref) {
  return StoreCachedTrackLocator(
    ref.watch(downloadStoreProvider),
    ref.watch(offlineFileStoreProvider),
    // A legacy untagged cache record is served by bare id only when the catalog
    // shows that id maps to one provider — never another provider's same-id copy.
    // Read lazily so wiring it never rebuilds the locator.
    catalogForLegacyMatch: () =>
        ref.read(musicLibraryRepositoryProvider).getAllTracks(),
  );
});

/// Production bindings: persist the cached-track set and the download/offline
/// preferences (including "Allow mobile data")
/// via `shared_preferences`, and store downloaded bytes on the device
/// filesystem, so all three survive a restart. Applied in `main`; tests keep
/// the in-memory defaults.
final sharedPreferencesDownloadStoreOverride =
    downloadStoreProvider.overrideWithValue(
  SharedPreferencesDownloadStore(),
);

final sharedPreferencesDownloadPreferencesOverride =
    downloadPreferencesProvider.overrideWithValue(
  const SharedPreferencesDownloadPreferences(),
);

final fileSystemOfflineFileStoreOverride =
    offlineFileStoreProvider.overrideWithValue(
  FileSystemOfflineFileStore(),
);

/// The fallback [RemoteTrackDownloader] when no source can fetch a track: it
/// treats every track as on-device (so nothing is mistaken for a remote
/// download) and refuses to fetch. Replaced at the composition root by the
/// Jellyfin downloader once that source can be wired in.
class _UnsupportedRemoteTrackDownloader implements RemoteTrackDownloader {
  const _UnsupportedRemoteTrackDownloader();

  @override
  bool isRemote(Track track) => false;

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) {
    throw UnsupportedError('No remote downloader is configured.');
  }
}
