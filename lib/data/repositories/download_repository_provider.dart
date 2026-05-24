import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/track.dart';
import '../../core/repositories/download_preferences.dart';
import '../../core/repositories/download_repository.dart';
import '../../core/repositories/download_store.dart';
import '../../core/repositories/offline_file_store.dart';
import '../../core/services/cached_track_locator.dart';
import '../../core/services/connectivity_service.dart';
import '../../core/services/optimistic_connectivity_service.dart';
import '../../core/services/remote_track_downloader.dart';
import 'cache_download_repository.dart';
import 'file_system_offline_file_store.dart';
import 'in_memory_download_preferences.dart';
import 'in_memory_download_store.dart';
import 'in_memory_offline_file_store.dart';
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

/// The user's "Wi-Fi only" download preference. In-memory by default; the app
/// persists it via `shared_preferences`.
final downloadPreferencesProvider = Provider<DownloadPreferences>((ref) {
  return InMemoryDownloadPreferences();
});

/// Network reachability used to honor the "Wi-Fi only" preference. The default
/// optimistically reports Wi-Fi until real detection lands; tests inject a fake
/// to drive the policy's mobile/offline paths.
final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  return const OptimisticConnectivityService();
});

/// The single [DownloadRepository] the app drives offline downloads through.
/// It composes the seams above and centralizes the user-initiated,
/// source-aware, Wi-Fi-respecting cache policy.
final downloadRepositoryProvider = Provider<DownloadRepository>((ref) {
  final repository = CacheDownloadRepository(
    store: ref.watch(downloadStoreProvider),
    files: ref.watch(offlineFileStoreProvider),
    downloader: ref.watch(remoteTrackDownloaderProvider),
    connectivity: ref.watch(connectivityServiceProvider),
    preferences: ref.watch(downloadPreferencesProvider),
  );
  ref.onDispose(repository.dispose);
  return repository;
});

/// Resolves a track to its cached-on-disk file when one exists. Read by the
/// playback resolver to prefer the local copy over streaming. Composed from the
/// same durable store + file store the repository writes through.
final cachedTrackLocatorProvider = Provider<CachedTrackLocator>((ref) {
  return StoreCachedTrackLocator(
    ref.watch(downloadStoreProvider),
    ref.watch(offlineFileStoreProvider),
  );
});

/// Production bindings: persist the cached-track set and the Wi-Fi-only switch
/// via `shared_preferences`, and store downloaded bytes on the device
/// filesystem, so all three survive a restart. Applied in `main`; tests keep
/// the in-memory defaults.
final sharedPreferencesDownloadStoreOverride =
    downloadStoreProvider.overrideWithValue(
  const SharedPreferencesDownloadStore(),
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
  Future<RemoteTrackData> fetch(Track track) {
    throw UnsupportedError('No remote downloader is configured.');
  }
}
