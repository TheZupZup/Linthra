import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/cache_size.dart';
import '../../core/models/download_progress.dart';
import '../../core/models/track.dart';
import '../../core/repositories/download_preferences.dart';
import '../../core/repositories/download_repository.dart';
import '../../core/repositories/download_store.dart';
import '../../core/services/offline_cache_manager.dart';
import '../../core/services/remote_track_downloader.dart';
import '../../core/services/routing_remote_track_downloader.dart';
import '../../core/sources/jellyfin/jellyfin_track_downloader.dart';
import '../../core/sources/plex/plex_track_downloader.dart';
import '../../core/sources/subsonic/subsonic_track_downloader.dart';
import '../../data/repositories/download_repository_provider.dart';
import '../../data/repositories/music_library_repository_provider.dart';
import '../settings/jellyfin/jellyfin_settings_controller.dart';
import '../settings/plex/plex_settings_controller.dart';
import '../settings/subsonic/subsonic_settings_controller.dart';

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

/// The live byte progress of a single in-flight download, for the row's
/// determinate ring. Null when the track isn't downloading (or its server
/// didn't report a size, leaving progress indeterminate). Auto-disposed so
/// off-screen rows drop their subscription.
final trackDownloadProgressProvider = StreamProvider.autoDispose
    .family<DownloadProgress?, String>((ref, trackId) {
  final repository = ref.watch(downloadRepositoryProvider);
  return repository.progressStream
      .map((progress) => progress[trackId])
      .distinct();
});

/// The catalog tracks that are fully available offline, recomputed whenever the
/// download status map changes. Powers the Downloads screen's finished list.
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

/// A track that is in flight or needs attention — queued, downloading, or
/// failed — paired with its live status.
typedef ActiveDownload = ({Track track, DownloadStatus status});

/// The catalog tracks that are queued, downloading, or failed — i.e. not yet
/// finished — recomputed whenever the status map changes. Ordered downloading →
/// queued → failed (then by id) so active work sits on top and the order is
/// stable across rebuilds. Powers the Downloads screen's "In progress" section,
/// which makes the bounded-parallel caching visible (and cancel/retry reachable)
/// in one place; finished downloads come from [downloadedTracksProvider].
final activeDownloadsProvider =
    StreamProvider<List<ActiveDownload>>((ref) async* {
  final repository = ref.watch(downloadRepositoryProvider);
  final library = ref.watch(musicLibraryRepositoryProvider);
  await for (final statuses in repository.statusStream) {
    // notDownloaded is never present in the map, so "not downloaded *yet*" is
    // exactly queued/downloading/failed.
    final active = <String, DownloadStatus>{
      for (final entry in statuses.entries)
        if (entry.value != DownloadStatus.downloaded) entry.key: entry.value,
    };
    if (active.isEmpty) {
      yield const <ActiveDownload>[];
      continue;
    }
    final tracks = await library.getAllTracks();
    final byId = <String, Track>{for (final t in tracks) t.id: t};
    yield <ActiveDownload>[
      for (final entry in active.entries)
        if (byId[entry.key] != null)
          (track: byId[entry.key]!, status: entry.value),
    ]..sort(_compareActiveDownloads);
  }
});

int _activeStatusRank(DownloadStatus status) {
  switch (status) {
    case DownloadStatus.downloading:
      return 0;
    case DownloadStatus.queued:
      return 1;
    case DownloadStatus.failed:
      return 2;
    case DownloadStatus.downloaded:
    case DownloadStatus.notDownloaded:
      return 3;
  }
}

int _compareActiveDownloads(ActiveDownload a, ActiveDownload b) {
  final int byStatus =
      _activeStatusRank(a.status).compareTo(_activeStatusRank(b.status));
  return byStatus != 0 ? byStatus : a.track.id.compareTo(b.track.id);
}

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

/// The ids of tracks that have an offline copy on disk (a downloaded or
/// pre-cached copy with managed bytes) — the safe, in-memory signal the playback
/// source strategy uses to favour cache/local copies, without a disk scan or any
/// path/URL.
///
/// Defaults to empty so the library/playback layers don't pull the whole cache
/// stack in tests; `main` applies [offlineAvailableTrackIdsOverride] to derive
/// it live from the cache snapshot. Tests override it directly with a set.
final offlineAvailableTrackIdsProvider =
    Provider<Set<String>>((ref) => const <String>{});

/// Production binding: the live set of offline-available track ids, recomputed
/// from [cacheEntriesByIdProvider] whenever the cache changes. Only entries with
/// managed bytes count (an on-device marker with no file is not a cached copy).
final offlineAvailableTrackIdsOverride =
    offlineAvailableTrackIdsProvider.overrideWith((ref) {
  final Map<String, CachedTrack> entries = ref.watch(cacheEntriesByIdProvider);
  return <String>{
    for (final CachedTrack entry in entries.values)
      if (entry.isManaged) entry.trackId,
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

/// Owns the "Allow mobile data" switch: loads the persisted value and writes
/// changes back through [DownloadPreferences]. When off (the safe default),
/// downloads and smart pre-cache run only on Wi-Fi.
class AllowMobileDataController extends AsyncNotifier<bool> {
  @override
  Future<bool> build() {
    return ref.read(downloadPreferencesProvider).allowMobileData();
  }

  Future<void> setAllowMobileData(bool value) async {
    await ref.read(downloadPreferencesProvider).setAllowMobileData(value);
    state = AsyncData<bool>(value);
  }
}

final allowMobileDataControllerProvider =
    AsyncNotifierProvider<AllowMobileDataController, bool>(
  AllowMobileDataController.new,
);

/// Owns the "Smart pre-cache" on/off switch: loads the persisted value and
/// writes changes back through [DownloadPreferences]. When on, the player warms
/// the next few queued tracks into the cache ahead of play.
class SmartPrecacheEnabledController extends AsyncNotifier<bool> {
  @override
  Future<bool> build() {
    return ref.read(downloadPreferencesProvider).preloadEnabled();
  }

  Future<void> setEnabled(bool value) async {
    await ref.read(downloadPreferencesProvider).setPreloadEnabled(value);
    state = AsyncData<bool>(value);
  }
}

final smartPrecacheEnabledProvider =
    AsyncNotifierProvider<SmartPrecacheEnabledController, bool>(
  SmartPrecacheEnabledController.new,
);

/// Owns the "Upcoming tracks to pre-cache" count: loads the persisted value and
/// writes changes back through [DownloadPreferences], sanitized to one of
/// [kPrecacheCountOptions] so it can never widen pre-caching beyond the offered
/// choices.
class PrecacheCountController extends AsyncNotifier<int> {
  @override
  Future<int> build() {
    return ref.read(downloadPreferencesProvider).precacheCount();
  }

  Future<void> setCount(int value) async {
    final int sanitized = sanitizePrecacheCount(value);
    await ref.read(downloadPreferencesProvider).setPrecacheCount(sanitized);
    state = AsyncData<int>(sanitized);
  }
}

final precacheCountProvider =
    AsyncNotifierProvider<PrecacheCountController, int>(
  PrecacheCountController.new,
);

/// Production binding: makes remote (Jellyfin, Subsonic/Navidrome, and Plex)
/// tracks downloadable for offline use by routing the remote downloader across
/// all signed-in sources, each wired to its live source (read lazily, so
/// sign-in/out is picked up without a rebuild). Credential-bearing download URLs
/// are minted only at fetch time inside each downloader; nothing here stores
/// them. Applied in `main`; tests override [remoteTrackDownloaderProvider] with
/// their own fake.
final remoteTrackDownloaderOverride =
    remoteTrackDownloaderProvider.overrideWith((ref) {
  // Read (not watch) the live sources lazily at fetch time, mirroring the
  // playback resolver — so the downloader is built once and signing in/out
  // doesn't rebuild it (which would reset in-flight download state).
  return RoutingRemoteTrackDownloader(<RemoteTrackDownloader>[
    JellyfinTrackDownloader(() => ref.read(jellyfinMusicSourceProvider)),
    SubsonicTrackDownloader(() => ref.read(subsonicMusicSourceProvider)),
    PlexTrackDownloader(() => ref.read(plexMusicSourceProvider)),
  ]);
});
