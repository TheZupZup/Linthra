import 'dart:async';

import '../../core/models/download_progress.dart';
import '../../core/models/track.dart';
import '../../core/repositories/download_preferences.dart';
import '../../core/repositories/download_repository.dart';
import '../../core/repositories/download_store.dart';
import '../../core/repositories/offline_file_store.dart';
import '../../core/services/cache_eviction_policy.dart';
import '../../core/services/connectivity_service.dart';
import '../../core/services/download_scheduler.dart';
import '../../core/services/offline_cache_manager.dart';
import '../../core/services/remote_track_downloader.dart';
import '../../core/services/track_prefetcher.dart';

/// The app's [DownloadRepository] *and* [OfflineCacheManager]: it owns the
/// offline-cache *policy* in one place and delegates the moving parts to focused
/// seams — durable metadata to a [DownloadStore], cached bytes to an
/// [OfflineFileStore], the remote byte-fetch to a [RemoteTrackDownloader], and
/// the (pure) eviction decision to a [CacheEvictionPolicy].
///
/// Promises enforced here so a caller can't skip them:
///  - **Downloads are user-initiated.** A track's download *status* changes only
///    in response to [requestDownload] / [removeDownload] (or an explicit clear /
///    pin). Auto-*preloaded* tracks ([prefetch]) are cached ahead of play too,
///    but they never take on a user-download status: they stay invisible to the
///    downloads UI, count toward the limit, and are the first to be evicted.
///  - **Bounded parallelism.** Several downloads fetch their bytes at once (via
///    a [DownloadScheduler]) so caching feels fast, but never more than the
///    scheduler's small limit — the app never opens an unbounded number of
///    requests. The byte fetch runs in parallel; the cache *commit* (eviction +
///    write + metadata) is serialized, so the limit is honored even when several
///    downloads finish at once. A repeated request for a track already
///    downloading (or queued) is ignored, so a track is never fetched twice.
///  - **Source-aware.** A remote (Jellyfin) track has its bytes fetched and
///    written to the offline directory; an on-device track is already local, so
///    it's recorded as available offline with no fetch and no managed file.
///  - **Wi-Fi only is respected.** A *remote* request is queued (not run) when
///    the user set "Wi-Fi only" and the connection isn't Wi-Fi.
///  - **Stays under the cache limit.** Before writing a remote download, the
///    policy evicts least-recently-used, unpinned, not-currently-playing tracks
///    to make room; if it still won't fit, the download is refused with a
///    friendly [CacheStorageException] and nothing is cached.
///
/// Safety: only app-managed cache files (in the offline directory) are ever
/// deleted — by file name derived from the non-secret track id. The user's
/// local source files (an on-device track's own path) are never passed to the
/// file store, so they can't be deleted here. A managed file the OS reclaimed
/// is detected on load and its stale metadata pruned, so playback falls back to
/// streaming instead of opening a missing file.
///
/// The authenticated URL a remote fetch needs is resolved inside the
/// [RemoteTrackDownloader] at fetch time; this repository never sees, stores, or
/// logs it. Persisted metadata carries only the non-secret track id, a
/// id-derived file name, the source's URI scheme, a byte size, timestamps, and
/// the pinned flag — never a token or URL.
class CacheDownloadRepository
    implements DownloadRepository, OfflineCacheManager, TrackPrefetcher {
  CacheDownloadRepository({
    required DownloadStore store,
    required OfflineFileStore files,
    required RemoteTrackDownloader downloader,
    required ConnectivityService connectivity,
    required DownloadPreferences preferences,
    CacheEvictionPolicy policy = const CacheEvictionPolicy(),
    DownloadScheduler? scheduler,
    String? Function()? currentlyPlayingTrackId,
    DateTime Function()? now,
  })  : _store = store,
        _files = files,
        _downloader = downloader,
        _connectivity = connectivity,
        _preferences = preferences,
        _policy = policy,
        _scheduler = scheduler ?? DownloadScheduler(),
        _currentlyPlayingTrackId = currentlyPlayingTrackId,
        _now = now ?? DateTime.now;

  final DownloadStore _store;
  final OfflineFileStore _files;
  final RemoteTrackDownloader _downloader;
  final ConnectivityService _connectivity;
  final DownloadPreferences _preferences;
  final CacheEvictionPolicy _policy;

  /// Bounds how many remote downloads fetch their bytes at the same time.
  final DownloadScheduler _scheduler;

  /// Supplies the id of the track currently playing (or `null`), so it is never
  /// evicted out from under the user. Read lazily so the repository doesn't
  /// depend on the playback layer at construction.
  final String? Function()? _currentlyPlayingTrackId;

  final DateTime Function() _now;

  final Map<String, DownloadStatus> _statuses = <String, DownloadStatus>{};

  /// The durable cache references, loaded once and kept in sync with the store,
  /// so removal can find the file to delete, eviction can sort by metadata, and
  /// usage is cheap to total.
  final Map<String, CachedTrack> _downloads = <String, CachedTrack>{};

  /// Track ids with a user download in flight (queued for a slot or actively
  /// fetching). Reserved synchronously at the start of [requestDownload] so two
  /// rapid taps — or two callers — can never start the same fetch twice.
  final Set<String> _inFlight = <String>{};

  /// Live byte progress for in-flight downloads, surfaced via [progressStream].
  final Map<String, DownloadProgress> _progress = <String, DownloadProgress>{};

  /// Serializes the cache *commit* (eviction + write + metadata) across the
  /// otherwise-parallel downloads, so the limit can't be overshot when several
  /// finish at once. Bytes are fetched in parallel; only this step is ordered.
  Future<void> _commitChain = Future<void>.value();

  final StreamController<Map<String, DownloadStatus>> _changes =
      StreamController<Map<String, DownloadStatus>>.broadcast();

  final StreamController<CacheSnapshot> _cacheChanges =
      StreamController<CacheSnapshot>.broadcast();

  final StreamController<Map<String, DownloadProgress>> _progressChanges =
      StreamController<Map<String, DownloadProgress>>.broadcast();

  bool _loaded = false;

  /// Seeds the in-memory state from the durable cache, once. Along the way it
  /// self-heals: a managed entry whose file is gone is dropped (stale metadata),
  /// and a managed entry missing its byte size (e.g. written by an earlier
  /// version) is backfilled from disk, so usage and eviction are accurate.
  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    bool changed = false;
    for (final CachedTrack cached in await _store.loadDownloads()) {
      if (cached.isManaged) {
        final int? size = await _files.sizeFor(cached.fileName!);
        if (size == null) {
          // The managed file is gone; drop the record so it isn't counted and
          // playback falls back to streaming.
          changed = true;
          continue;
        }
        CachedTrack entry = cached;
        if (cached.sizeBytes == 0 && size > 0) {
          entry = cached.copyWith(sizeBytes: size);
          changed = true;
        }
        _downloads[entry.trackId] = entry;
      } else {
        _downloads[cached.trackId] = cached;
      }
      // A preloaded entry is cached and playable, but never a *download*: it
      // stays out of the status map so the downloads UI doesn't show it.
      if (!cached.preloaded) {
        _statuses[cached.trackId] = DownloadStatus.downloaded;
      }
    }
    if (changed) await _save();
    _loaded = true;
  }

  @override
  Stream<Map<String, DownloadStatus>> get statusStream async* {
    await _ensureLoaded();
    yield _snapshot();
    yield* _changes.stream;
  }

  @override
  Future<DownloadStatus> statusFor(String trackId) async {
    await _ensureLoaded();
    return _statuses[trackId] ?? DownloadStatus.notDownloaded;
  }

  @override
  Stream<Map<String, DownloadProgress>> get progressStream async* {
    yield _progressSnapshot();
    yield* _progressChanges.stream;
  }

  @override
  Future<void> requestDownload(Track track) async {
    if (!_downloader.isRemote(track)) {
      // On-device track: no bytes to fetch and no network gate, so record it as
      // available offline directly.
      await _requestOnDeviceDownload(track);
      return;
    }

    // Reserve the in-flight slot synchronously, before any `await`, so a second
    // request for the same track (a double tap, or a second caller) bails out
    // here instead of starting a duplicate fetch.
    if (!_inFlight.add(track.id)) return;
    try {
      await _runRemoteRequest(track);
    } on CacheStorageException {
      // The cache is full with nothing safe to evict; surface the friendly,
      // secret-free error so the UI can prompt to free space or raise the
      // limit. Status was already reset to not-downloaded before the throw.
      rethrow;
    } catch (_) {
      // Other errors may carry source-specific detail; the UI only needs the
      // failed state (which offers a retry).
      _set(track.id, DownloadStatus.failed);
    } finally {
      _inFlight.remove(track.id);
      _clearProgress(track.id);
    }
  }

  /// Records an on-device track as available offline: its bytes are already
  /// local, so there is no fetch, no managed file, and no Wi-Fi gate.
  Future<void> _requestOnDeviceDownload(Track track) async {
    await _ensureLoaded();
    if (_statuses[track.id] == DownloadStatus.downloaded) return;
    _downloads[track.id] = CachedTrack(
      trackId: track.id,
      sourceType: _sourceTypeOf(track),
      cachedAt: _now(),
    );
    await _save();
    _statuses[track.id] = DownloadStatus.downloaded;
    _emitStatus();
    _emitCache();
  }

  /// Drives one remote download: skip if already cached, promote a preloaded
  /// copy in place, honor "Wi-Fi only", then wait for a concurrency slot before
  /// fetching the bytes and committing them under the cache limit.
  Future<void> _runRemoteRequest(Track track) async {
    await _ensureLoaded();
    // Already cached — nothing to do. (A track that is downloading or queued is
    // already in [_inFlight], so it never reaches here a second time.)
    if (_statuses[track.id] == DownloadStatus.downloaded) return;

    // A track preloaded ahead of play is already cached: promote it to a user
    // download in place, without re-fetching its bytes.
    final CachedTrack? preloadedEntry = _downloads[track.id];
    if (preloadedEntry != null &&
        preloadedEntry.preloaded &&
        preloadedEntry.isManaged) {
      _downloads[track.id] = preloadedEntry.copyWith(preloaded: false);
      await _save();
      _statuses[track.id] = DownloadStatus.downloaded;
      _emitStatus();
      _emitCache();
      return;
    }

    // The Wi-Fi gate only matters here, where there are bytes to pull over the
    // network. When it blocks, the track waits as "queued" for an explicit
    // retry once on Wi-Fi (the in-flight reservation is released by the caller).
    if (!await _allowedToDownloadNow()) {
      _set(track.id, DownloadStatus.queued);
      return;
    }

    // Accepted: show "queued" until a concurrency slot frees up, then fetch.
    _set(track.id, DownloadStatus.queued);
    await _scheduler.schedule(() async {
      _set(track.id, DownloadStatus.downloading);
      final RemoteTrackData data = await _downloader.fetch(
        track,
        onProgress: (int received, int? total) =>
            _reportProgress(track.id, received, total),
      );
      // Commit serially so concurrent downloads can't jointly overshoot the
      // limit; the (slow) byte fetch above already ran in parallel.
      await _commit(() => _cacheRemote(track, data));
    });
  }

  /// Writes a freshly fetched remote track's bytes, evicting first to stay under
  /// the limit. A user download ([preloaded] `false`) takes on the `downloaded`
  /// status; a [preloaded] one is cached but stays out of the status map.
  ///
  /// Throws [CacheStorageException] (after resetting status) when a user
  /// download can't fit even after evicting everything safe to remove; a preload
  /// that can't fit returns quietly (it's best-effort).
  Future<void> _cacheRemote(
    Track track,
    RemoteTrackData data, {
    bool preloaded = false,
  }) async {
    if (preloaded) {
      final CachedTrack? existing = _downloads[track.id];
      // A user download for the same track raced this preload (commits are
      // serialized, so by now the winner is known). Don't clobber or duplicate
      // a real download with a preloaded copy — let the user's copy stand.
      if (_inFlight.contains(track.id) ||
          (existing != null && !existing.preloaded)) {
        return;
      }
    }
    final int incoming = data.bytes.length;
    final int maxBytes = await _preferences.maxCacheBytes();
    final EvictionPlan plan = _policy.plan(
      cached: _downloads.values,
      incomingBytes: incoming,
      maxBytes: maxBytes,
      protectTrackId: _currentlyPlayingTrackId?.call(),
      incomingTrackId: track.id,
    );

    if (!plan.fits) {
      if (preloaded) return;
      _set(track.id, DownloadStatus.notDownloaded);
      throw const CacheStorageException();
    }

    bool evictedAStatus = false;
    for (final CachedTrack victim in plan.evict) {
      await _deleteManagedFile(victim);
      _downloads.remove(victim.trackId);
      if (_statuses.remove(victim.trackId) != null) evictedAStatus = true;
    }

    final String fileName = await _files.write(
      track.id,
      data.bytes,
      extension: data.fileExtension,
    );
    final DateTime now = _now();
    _downloads[track.id] = CachedTrack(
      trackId: track.id,
      fileName: fileName,
      sourceType: _sourceTypeOf(track),
      sizeBytes: incoming,
      cachedAt: now,
      // A preload hasn't been played yet, so it has no access time — which also
      // keeps it ahead of played tracks of its own kind in eviction order.
      lastAccessedAt: preloaded ? null : now,
      preloaded: preloaded,
    );
    await _save();
    if (!preloaded) {
      _statuses[track.id] = DownloadStatus.downloaded;
    }
    // A preload changes only cache usage; a user download (or an eviction that
    // dropped a download) also changes download status.
    if (!preloaded || evictedAStatus) _emitStatus();
    _emitCache();
  }

  @override
  Future<void> prefetch(Track track) async {
    await _ensureLoaded();
    // Only remote tracks have bytes to fetch; local ones are already on disk.
    if (!_downloader.isRemote(track)) return;
    // Already cached (download or earlier preload), or a user download already
    // has it in flight — skip rather than fetch the same bytes twice.
    if (_downloads.containsKey(track.id)) return;
    if (_inFlight.contains(track.id)) return;
    if (_statuses[track.id] == DownloadStatus.downloading) return;
    // Preload is best-effort and network-heavy, so it honours "Wi-Fi only" and
    // simply skips (rather than queueing) when it can't run right now.
    if (!await _allowedToDownloadNow()) return;
    try {
      final RemoteTrackData data = await _downloader.fetch(track);
      // Share the one commit lock so a preload write can't race a user
      // download's and overshoot the limit.
      await _commit(() => _cacheRemote(track, data, preloaded: true));
    } catch (_) {
      // Best-effort: a failed preload caches nothing and changes no status; the
      // track still streams normally when it's reached.
    }
  }

  @override
  Future<void> removeDownload(String trackId) async {
    await _ensureLoaded();
    final CachedTrack? existing = _downloads.remove(trackId);
    await _deleteManagedFile(existing);
    await _save();
    // Also clears a queued/failed/downloading marker, so this doubles as cancel.
    _set(trackId, DownloadStatus.notDownloaded);
    _emitCache();
  }

  @override
  Future<List<String>> downloadedTrackIds() async {
    await _ensureLoaded();
    return _statuses.entries
        .where((MapEntry<String, DownloadStatus> e) =>
            e.value == DownloadStatus.downloaded)
        .map((MapEntry<String, DownloadStatus> e) => e.key)
        .toList();
  }

  @override
  Stream<CacheSnapshot> get cacheStream async* {
    await _ensureLoaded();
    yield _cacheSnapshot();
    yield* _cacheChanges.stream;
  }

  @override
  Future<CacheSnapshot> cacheSnapshot() async {
    await _ensureLoaded();
    return _cacheSnapshot();
  }

  @override
  Future<void> setPinned(String trackId, bool pinned) async {
    await _ensureLoaded();
    final CachedTrack? existing = _downloads[trackId];
    if (existing == null || existing.pinned == pinned) return;
    _downloads[trackId] = existing.copyWith(pinned: pinned);
    await _save();
    _emitCache();
  }

  @override
  Future<void> notePlayed(String trackId) async {
    await _ensureLoaded();
    final CachedTrack? existing = _downloads[trackId];
    if (existing == null) return;
    _downloads[trackId] = existing.copyWith(lastAccessedAt: _now());
    await _save();
    _emitCache();
  }

  @override
  Future<void> clearAll() => _clear(keepPinned: false);

  @override
  Future<void> clearUnpinned() => _clear(keepPinned: true);

  /// Removes offline entries (optionally keeping pinned ones), deleting their
  /// app-managed cache files. On-device markers carry no managed file, so the
  /// user's local source files are never touched.
  Future<void> _clear({required bool keepPinned}) async {
    await _ensureLoaded();
    final List<CachedTrack> victims = _downloads.values
        .where((CachedTrack c) => !(keepPinned && c.pinned))
        .toList();
    if (victims.isEmpty) return;
    for (final CachedTrack victim in victims) {
      await _deleteManagedFile(victim);
      _downloads.remove(victim.trackId);
      _statuses.remove(victim.trackId);
    }
    await _save();
    _emitStatus();
    _emitCache();
  }

  /// Releases the change streams. Call when the owning provider is disposed.
  Future<void> dispose() async {
    await _changes.close();
    await _cacheChanges.close();
    await _progressChanges.close();
  }

  /// The connectivity gate. With "Wi-Fi only" off, anything goes; with it on,
  /// only a Wi-Fi connection clears a download to start now.
  Future<bool> _allowedToDownloadNow() async {
    if (!await _preferences.wifiOnly()) return true;
    return await _connectivity.currentStatus() == NetworkStatus.wifi;
  }

  /// Deletes the app-managed cache file behind [entry], if any. A `null` entry
  /// or an on-device record (no managed file) is a safe no-op — the file store
  /// is only ever asked to delete files it created in the offline directory.
  Future<void> _deleteManagedFile(CachedTrack? entry) async {
    final String? fileName = entry?.fileName;
    if (fileName != null && fileName.isNotEmpty) {
      await _files.delete(fileName);
    }
  }

  Future<void> _save() => _store.saveDownloads(_downloads.values.toList());

  void _set(String trackId, DownloadStatus status) {
    if (status == DownloadStatus.notDownloaded) {
      _statuses.remove(trackId);
    } else {
      _statuses[trackId] = status;
    }
    _emitStatus();
  }

  void _emitStatus() => _changes.add(_snapshot());

  void _emitCache() => _cacheChanges.add(_cacheSnapshot());

  void _emitProgress() => _progressChanges.add(_progressSnapshot());

  /// Runs [action] (a cache commit) only after any in-flight commit finishes,
  /// so the eviction + write step is never interleaved across the otherwise
  /// parallel downloads — which is what keeps the cache limit exact under load.
  /// The chain itself never rejects (errors are routed to [action]'s future),
  /// so one failed commit doesn't stall the ones behind it.
  Future<T> _commit<T>(Future<T> Function() action) {
    final Completer<T> result = Completer<T>();
    _commitChain = _commitChain.then((_) async {
      try {
        result.complete(await action());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  void _reportProgress(String trackId, int received, int? total) {
    _progress[trackId] = DownloadProgress(
      trackId: trackId,
      receivedBytes: received,
      totalBytes: total,
    );
    _emitProgress();
  }

  void _clearProgress(String trackId) {
    if (_progress.remove(trackId) != null) _emitProgress();
  }

  Map<String, DownloadStatus> _snapshot() =>
      Map<String, DownloadStatus>.unmodifiable(_statuses);

  Map<String, DownloadProgress> _progressSnapshot() =>
      Map<String, DownloadProgress>.unmodifiable(_progress);

  CacheSnapshot _cacheSnapshot() {
    int used = 0;
    for (final CachedTrack c in _downloads.values) {
      used += c.sizeBytes;
    }
    return CacheSnapshot(
      usedBytes: used,
      entries: List<CachedTrack>.unmodifiable(_downloads.values),
    );
  }

  /// The track's non-secret URI scheme (`jellyfin`, `file`, …), never the full
  /// URL — safe to persist as the cached track's source type.
  static String? _sourceTypeOf(Track track) {
    final int colon = track.uri.indexOf(':');
    if (colon <= 0) return null;
    final String scheme = track.uri.substring(0, colon).toLowerCase();
    return scheme.isEmpty ? null : scheme;
  }
}
