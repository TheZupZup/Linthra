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
///  - **The mobile-data policy is respected.** A *remote* request runs on Wi-Fi
///    always, on mobile data only when the user turned on "Allow mobile data",
///    and never while offline. When the connection isn't allowed the request is
///    queued (not run) and [requestDownload] reports why, so the UI can prompt
///    the user instead of failing silently.
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
    Track? Function()? currentlyPlayingTrack,
    DateTime Function()? now,
    Future<List<Track>> Function()? catalogForMigration,
  })  : _store = store,
        _files = files,
        _downloader = downloader,
        _connectivity = connectivity,
        _preferences = preferences,
        _policy = policy,
        _scheduler = scheduler ?? DownloadScheduler(),
        _currentlyPlayingTrack = currentlyPlayingTrack,
        _now = now ?? DateTime.now,
        _catalogForMigration = catalogForMigration;

  final DownloadStore _store;
  final OfflineFileStore _files;
  final RemoteTrackDownloader _downloader;
  final ConnectivityService _connectivity;
  final DownloadPreferences _preferences;
  final CacheEvictionPolicy _policy;

  /// Bounds how many remote downloads fetch their bytes at the same time.
  final DownloadScheduler _scheduler;

  /// Supplies the track currently playing (or `null`), so it is never evicted
  /// out from under the user. A whole [Track] (not just an id) so its
  /// provider-aware [CachedTrack.cacheKey] protects exactly that provider's
  /// copy — a same-id track from another provider stays evictable. Read lazily
  /// so the repository doesn't depend on the playback layer at construction.
  final Track? Function()? _currentlyPlayingTrack;

  final DateTime Function() _now;

  /// Resolves the current catalog tracks, used once on load to migrate legacy
  /// (pre-v0.1.6, `sourceType`-less) cache records to provider-aware keys by
  /// inferring each record's provider from the catalog. The pre-v0.1.6 catalog is
  /// 1:1 bare-id→provider, so an unambiguous match is safe; an id the catalog now
  /// exposes under two providers is left unmigrated rather than mis-attributed.
  /// Null in tests/dev that don't exercise migration; the app wires it to the
  /// music library.
  final Future<List<Track>> Function()? _catalogForMigration;

  final Map<String, DownloadStatus> _statuses = <String, DownloadStatus>{};

  /// The durable cache references, loaded once and kept in sync with the store,
  /// so removal can find the file to delete, eviction can sort by metadata, and
  /// usage is cheap to total.
  final Map<String, CachedTrack> _downloads = <String, CachedTrack>{};

  /// Track ids with a user download in flight (queued for a slot or actively
  /// fetching). Reserved synchronously at the start of [requestDownload] so two
  /// rapid taps — or two callers — can never start the same fetch twice.
  final Set<String> _inFlight = <String>{};

  /// Track ids whose bytes are being pre-cached right now. Reserved
  /// synchronously at the start of [prefetch] so two concurrent prefetches of
  /// the same track can't both spend network fetching it. Kept separate from
  /// [_inFlight] so a preload never makes a user [requestDownload] think the
  /// track is already a download.
  final Set<String> _preloading = <String>{};

  /// Track ids whose in-flight fetch must NOT commit, because the user removed
  /// or cleared the download while its bytes were still downloading. Checked at
  /// commit time so a late fetch can't resurrect a cancelled download or leave a
  /// stray file behind. A fresh [requestDownload] clears any stale entry, and
  /// the commit/cleanup paths drop it once handled.
  final Set<String> _canceled = <String>{};

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
    final List<CachedTrack> records = await _store.loadDownloads();
    final Map<String, String?> legacyScheme = await _legacySchemeFor(records);
    for (final CachedTrack record in records) {
      CachedTrack cached = record;
      // Legacy (pre-v0.1.6) records carry no sourceType, so they key as
      // `\0<id>` while a live track keys as `<scheme>\0<id>` — the download would
      // look missing to the row/offline consumers, and a fresh request would
      // re-fetch it. Re-key by inferring the provider from the catalog
      // (unambiguous matches only); the cache file name is untouched, so the
      // bytes keep resolving, and re-saving heals the record for next launch.
      final String? inferred = legacyScheme[cached.trackId];
      if (inferred != null &&
          inferred.isNotEmpty &&
          (cached.sourceType == null || cached.sourceType!.isEmpty)) {
        cached = cached.copyWith(sourceType: inferred);
        changed = true;
      }
      if (cached.isManaged) {
        final int? size = await _files.sizeFor(cached.fileName!);
        if (size == null) {
          // The managed file is gone; drop the record so it isn't counted and
          // playback falls back to streaming.
          changed = true;
          continue;
        }
        if (cached.sizeBytes == 0 && size > 0) {
          cached = cached.copyWith(sizeBytes: size);
          changed = true;
        }
      }
      _downloads[_keyForCached(cached)] = cached;
      // A preloaded entry is cached and playable, but never a *download*: it
      // stays out of the status map so the downloads UI doesn't show it.
      if (!cached.preloaded) {
        _statuses[_keyForCached(cached)] = DownloadStatus.downloaded;
      }
    }
    if (changed) await _save();
    _loaded = true;
  }

  /// The provider scheme for each legacy (sourceType-less) record's bare id,
  /// resolved via the catalog oracle so those records can be re-keyed to
  /// provider-aware identity. Empty when there's nothing to migrate or no oracle
  /// is wired. A bare id the catalog exposes under more than one provider maps to
  /// null (ambiguous → left unmigrated rather than mis-attributed).
  Future<Map<String, String?>> _legacySchemeFor(
      List<CachedTrack> records) async {
    final Future<List<Track>> Function()? oracle = _catalogForMigration;
    if (oracle == null) return const <String, String?>{};
    final bool hasLegacy = records
        .any((CachedTrack c) => c.sourceType == null || c.sourceType!.isEmpty);
    if (!hasLegacy) return const <String, String?>{};
    final List<Track> tracks;
    try {
      tracks = await oracle();
    } catch (_) {
      return const <String, String?>{};
    }
    final Map<String, String?> byId = <String, String?>{};
    for (final Track track in tracks) {
      byId[track.id] =
          byId.containsKey(track.id) ? null : CachedTrack.schemeOf(track.uri);
    }
    return byId;
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
    // A plain catalog-id convenience: the catalog's primary key makes ids unique
    // there, so a bare id resolves to one track. The cache itself is keyed
    // provider-aware (see [_snapshot]) and [statusStream] emits those keys — the
    // app's per-row status joins on the cache key, never this. Scans the
    // provider-aware map by id so a caller can still ask by plain id; under a
    // cross-provider same-id collision it returns the first matching copy.
    for (final MapEntry<String, DownloadStatus> e in _statuses.entries) {
      if (_trackIdOfKey(e.key) == trackId) return e.value;
    }
    return DownloadStatus.notDownloaded;
  }

  @override
  Stream<Map<String, DownloadProgress>> get progressStream async* {
    yield _progressSnapshot();
    yield* _progressChanges.stream;
  }

  @override
  Future<DownloadRequestOutcome> requestDownload(Track track) async {
    if (!_downloader.isRemote(track)) {
      // On-device track: no bytes to fetch and no network gate, so record it as
      // available offline directly.
      await _requestOnDeviceDownload(track);
      return DownloadRequestOutcome.started;
    }

    final String key = _keyForTrack(track);
    // A fresh, explicit request supersedes any pending cancellation for this id
    // (e.g. the user removed it mid-fetch and immediately asked again).
    _canceled.remove(key);
    // Reserve the in-flight slot synchronously, before any `await`, so a second
    // request for the same track (a double tap, or a second caller) bails out
    // here instead of starting a duplicate fetch.
    if (!_inFlight.add(key)) return DownloadRequestOutcome.started;
    try {
      return await _runRemoteRequest(track);
    } on CacheStorageException {
      // The cache is full with nothing safe to evict; surface the friendly,
      // secret-free error so the UI can prompt to free space or raise the
      // limit. Status was already reset to not-downloaded before the throw.
      rethrow;
    } catch (_) {
      // Other errors may carry source-specific detail; the UI only needs the
      // failed state (which offers a retry) — but a download the user cancelled
      // mid-fetch must stay gone, not flip to "failed".
      if (!_canceled.contains(key)) {
        _set(key, DownloadStatus.failed);
      }
      return DownloadRequestOutcome.started;
    } finally {
      _canceled.remove(key);
      _inFlight.remove(key);
      _clearProgress(key);
    }
  }

  /// Records an on-device track as available offline: its bytes are already
  /// local, so there is no fetch, no managed file, and no network gate.
  Future<void> _requestOnDeviceDownload(Track track) async {
    await _ensureLoaded();
    final String key = _keyForTrack(track);
    if (_statuses[key] == DownloadStatus.downloaded) return;
    _downloads[key] = CachedTrack(
      trackId: track.id,
      sourceType: _sourceTypeOf(track),
      cachedAt: _now(),
    );
    await _save();
    _statuses[key] = DownloadStatus.downloaded;
    _emitStatus();
    _emitCache();
  }

  /// Drives one remote download: skip if already cached, promote a preloaded
  /// copy in place, apply the mobile-data policy, then wait for a concurrency
  /// slot before fetching the bytes and committing them under the cache limit.
  Future<DownloadRequestOutcome> _runRemoteRequest(Track track) async {
    await _ensureLoaded();
    final String key = _keyForTrack(track);
    // Already cached — nothing to do. (A track that is downloading or queued is
    // already in [_inFlight], so it never reaches here a second time.)
    if (_statuses[key] == DownloadStatus.downloaded) {
      return DownloadRequestOutcome.started;
    }

    // A track preloaded ahead of play is already cached: promote it to a user
    // download in place, without re-fetching its bytes.
    final CachedTrack? preloadedEntry = _downloads[key];
    if (preloadedEntry != null &&
        preloadedEntry.preloaded &&
        preloadedEntry.isManaged) {
      _downloads[key] = preloadedEntry.copyWith(preloaded: false);
      await _save();
      _statuses[key] = DownloadStatus.downloaded;
      _emitStatus();
      _emitCache();
      return DownloadRequestOutcome.started;
    }

    // The network gate only matters here, where there are bytes to pull over the
    // network. When it blocks, the track waits as "queued" for an explicit
    // retry once allowed (the in-flight reservation is released by the caller),
    // and the outcome tells the UI why so it can prompt instead of failing.
    final _NetworkDecision decision = await _networkDecision();
    if (decision != _NetworkDecision.allowed) {
      _set(key, DownloadStatus.queued);
      return decision == _NetworkDecision.offline
          ? DownloadRequestOutcome.waitingForConnection
          : DownloadRequestOutcome.waitingForWifi;
    }

    // Accepted: show "queued" until a concurrency slot frees up, then fetch.
    _set(key, DownloadStatus.queued);
    await _scheduler.schedule(() async {
      _set(key, DownloadStatus.downloading);
      final RemoteTrackData data = await _downloader.fetch(
        track,
        onProgress: (int received, int? total) =>
            _reportProgress(track, received, total),
      );
      // Commit serially so concurrent downloads can't jointly overshoot the
      // limit; the (slow) byte fetch above already ran in parallel.
      await _commit(() => _cacheRemote(track, data));
    });
    return DownloadRequestOutcome.started;
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
    final String key = _keyForTrack(track);
    // The user removed or cleared this download while its bytes were still in
    // flight: honour that and commit nothing — no file write, no metadata, no
    // status — so a late fetch can't resurrect it or leave a stray file.
    if (_canceled.remove(key)) return;
    if (preloaded) {
      final CachedTrack? existing = _downloads[key];
      // A user download for the same track raced this preload (commits are
      // serialized, so by now the winner is known). Don't clobber or duplicate
      // a real download with a preloaded copy — let the user's copy stand.
      if (_inFlight.contains(key) ||
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
      protectKey: _protectKey(),
      incomingKey: key,
    );

    if (!plan.fits) {
      if (preloaded) return;
      _set(key, DownloadStatus.notDownloaded);
      throw const CacheStorageException();
    }

    bool evictedAStatus = false;
    for (final CachedTrack victim in plan.evict) {
      await _deleteManagedFile(victim);
      final String victimKey = _keyForCached(victim);
      _downloads.remove(victimKey);
      if (_statuses.remove(victimKey) != null) evictedAStatus = true;
    }

    final String fileName = await _files.write(
      _fileBaseName(track),
      data.bytes,
      extension: data.fileExtension,
    );
    final DateTime now = _now();
    _downloads[key] = CachedTrack(
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
      _statuses[key] = DownloadStatus.downloaded;
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
    final String key = _keyForTrack(track);
    // Already cached (download or earlier preload), or a user download already
    // has it in flight — skip rather than fetch the same bytes twice.
    if (_downloads.containsKey(key)) return;
    if (_inFlight.contains(key)) return;
    if (_statuses[key] == DownloadStatus.downloading) return;
    // Reserve synchronously, before any await, so a second concurrent prefetch
    // of the same track bails here instead of fetching the same bytes twice.
    if (!_preloading.add(key)) return;
    try {
      // Preload is best-effort and network-heavy, so it honours the mobile-data
      // policy and simply skips (rather than queueing) when it can't run now.
      if (!await _allowedToDownloadNow()) return;
      // Respect the cache limit *before* spending data: if the cache is already
      // full and nothing is safe to evict (every entry pinned or playing), a
      // best-effort preload can never fit — skip the fetch rather than pull
      // bytes we'd immediately discard. The exact fit is re-checked at commit.
      if (!_hasRoomForPrecache(await _preferences.maxCacheBytes())) return;
      final RemoteTrackData data = await _downloader.fetch(track);
      // Share the one commit lock so a preload write can't race a user
      // download's and overshoot the limit.
      await _commit(() => _cacheRemote(track, data, preloaded: true));
    } catch (_) {
      // Best-effort: a failed preload caches nothing and changes no status; the
      // track still streams normally when it's reached.
    } finally {
      _canceled.remove(key);
      _preloading.remove(key);
    }
  }

  @override
  Future<void> removeDownload(Track track) async {
    await _ensureLoaded();
    final String key = _keyForTrack(track);
    // If a fetch for this track is still in flight, mark it cancelled so its
    // late commit won't re-add the entry or leave a managed file on disk.
    if (_inFlight.contains(key) || _preloading.contains(key)) {
      _canceled.add(key);
    }
    final CachedTrack? existing = _downloads.remove(key);
    await _deleteManagedFile(existing);
    await _save();
    // Also clears a queued/failed/downloading marker, so this doubles as cancel.
    _set(key, DownloadStatus.notDownloaded);
    _emitCache();
  }

  @override
  Future<List<String>> downloadedTrackKeys() async {
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
  Future<void> setPinned(Track track, bool pinned) async {
    await _ensureLoaded();
    final String key = _keyForTrack(track);
    final CachedTrack? existing = _downloads[key];
    if (existing == null || existing.pinned == pinned) return;
    _downloads[key] = existing.copyWith(pinned: pinned);
    await _save();
    _emitCache();
  }

  @override
  Future<void> notePlayed(Track track) async {
    await _ensureLoaded();
    final String key = _keyForTrack(track);
    final CachedTrack? existing = _downloads[key];
    if (existing == null) return;
    _downloads[key] = existing.copyWith(lastAccessedAt: _now());
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
    // Cancel any in-flight fetch first (synchronously, before any await), so a
    // download finishing mid-clear can't write a file and re-add an entry the
    // user just cleared. An in-flight download holds no committed entry yet, so
    // it is unpinned by nature — correct to drop under either clear mode.
    _canceled.addAll(_inFlight);
    _canceled.addAll(_preloading);
    await _ensureLoaded();
    final List<CachedTrack> victims = _downloads.values
        .where((CachedTrack c) => !(keepPinned && c.pinned))
        .toList();
    if (victims.isEmpty) return;
    for (final CachedTrack victim in victims) {
      await _deleteManagedFile(victim);
      final String victimKey = _keyForCached(victim);
      _downloads.remove(victimKey);
      _statuses.remove(victimKey);
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

  /// Whether a best-effort pre-cache could plausibly fit right now: either the
  /// cache is below its limit, or there is at least one entry the policy could
  /// evict (a prior pre-cache, or an unpinned download that isn't playing). When
  /// the cache is full of pinned/playing tracks there is no room a pre-cache
  /// could ever take, so the caller skips the fetch entirely. A cheap, in-memory
  /// scan — the exact fit is decided by [CacheEvictionPolicy] at commit time.
  bool _hasRoomForPrecache(int maxBytes) {
    final String? protectKey = _protectKey();
    int used = 0;
    bool hasEvictable = false;
    for (final CachedTrack c in _downloads.values) {
      used += c.sizeBytes;
      if (c.isManaged &&
          c.sizeBytes > 0 &&
          !c.pinned &&
          c.cacheKey != protectKey) {
        hasEvictable = true;
      }
    }
    return used < maxBytes || hasEvictable;
  }

  /// The provider-aware cache key of the currently playing track (or `null`),
  /// for the eviction policy to protect exactly that provider's copy. Built from
  /// the live [Track] so a same-id track from another provider isn't shielded.
  String? _protectKey() {
    final Track? playing = _currentlyPlayingTrack?.call();
    return playing == null ? null : _keyForTrack(playing);
  }

  /// The connectivity gate as a simple yes/no, for the best-effort pre-cache
  /// path that just skips when it can't run.
  Future<bool> _allowedToDownloadNow() async =>
      await _networkDecision() == _NetworkDecision.allowed;

  /// Decides whether a download may run right now, and (when it can't) why:
  ///  - Wi-Fi: always allowed.
  ///  - Mobile data: allowed only when the user turned on "Allow mobile data";
  ///    otherwise held for Wi-Fi.
  ///  - Unknown: treated conservatively, like mobile data — allowed only when
  ///    the user allowed mobile data, so an undetermined link is never assumed
  ///    unmetered.
  ///  - Offline: never allowed; the request waits for a connection.
  Future<_NetworkDecision> _networkDecision() async {
    final NetworkStatus status = await _connectivity.currentStatus();
    switch (status) {
      case NetworkStatus.wifi:
        return _NetworkDecision.allowed;
      case NetworkStatus.mobile:
      case NetworkStatus.unknown:
        return await _preferences.allowMobileData()
            ? _NetworkDecision.allowed
            : _NetworkDecision.needsWifi;
      case NetworkStatus.offline:
        return _NetworkDecision.offline;
    }
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

  void _set(String key, DownloadStatus status) {
    if (status == DownloadStatus.notDownloaded) {
      _statuses.remove(key);
    } else {
      _statuses[key] = status;
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

  void _reportProgress(Track track, int received, int? total) {
    _progress[_keyForTrack(track)] = DownloadProgress(
      trackId: track.id,
      receivedBytes: received,
      totalBytes: total,
    );
    _emitProgress();
  }

  void _clearProgress(String key) {
    if (_progress.remove(key) != null) _emitProgress();
  }

  /// A copy of the provider-aware status map, keyed by each track's
  /// [CachedTrack.cacheKey] (`scheme\0id`) — the very key a live [Track] produces
  /// via [CachedTrack.cacheKeyForTrack]. Keeping the provider-aware key in the
  /// public projection is what stops two providers' same-id copies (`jellyfin:101`
  /// vs `subsonic:101`) from sharing a status: the per-row status/progress
  /// providers and the downloaded/offline sets all join on this key, so a
  /// download of one copy never lights up the other.
  Map<String, DownloadStatus> _snapshot() =>
      Map<String, DownloadStatus>.of(_statuses);

  Map<String, DownloadProgress> _progressSnapshot() =>
      Map<String, DownloadProgress>.of(_progress);

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
  /// URL — safe to persist as the cached track's source type. Delegates to
  /// [CachedTrack.schemeOf] so the repository's stored key and the key a consumer
  /// computes from a live [Track] via [CachedTrack.cacheKeyForTrack] can never
  /// drift to different scheme logic.
  static String? _sourceTypeOf(Track track) => CachedTrack.schemeOf(track.uri);

  /// The provider-aware cache identity for [track]: its source scheme **plus**
  /// catalog id, so two providers that expose the same local id (e.g. a Plex
  /// ratingKey `101` and a Subsonic id `101`) never share a cache slot, file, or
  /// status. This is the key for every in-memory map below.
  static String _keyForTrack(Track track) =>
      _cacheKey(_sourceTypeOf(track), track.id);

  /// The same identity for a persisted [entry] — its provider-aware
  /// [CachedTrack.cacheKey], built from the same `(sourceType, trackId)` it was
  /// written with, so a reloaded entry maps back to exactly the key its live
  /// track produces and cache state stays stable across restarts.
  static String _keyForCached(CachedTrack entry) => entry.cacheKey;

  /// Composes a credential-free cache key from a source scheme and catalog id —
  /// delegating to the one shared definition [CachedTrack.cacheKeyFor], so the
  /// repository, the metadata records, and the eviction policy can never drift
  /// to different key formats. [_trackIdOfKey] recovers the id for the id-keyed
  /// snapshots the UI reads.
  static String _cacheKey(String? sourceType, String trackId) =>
      CachedTrack.cacheKeyFor(sourceType, trackId);

  /// The catalog id embedded in a [key] from [_cacheKey] — used to project the
  /// internal, provider-aware maps back onto the id-keyed snapshots the UI and
  /// the cross-provider sync layers consume.
  static String _trackIdOfKey(String key) =>
      key.substring(key.indexOf(String.fromCharCode(0)) + 1);

  /// A provider-namespaced base name for [track]'s cache file, so two providers
  /// with the same id write to distinct files (`plex_101`, `jellyfin_101`). The
  /// [OfflineFileStore] sanitizes it further; the resulting file name is what's
  /// persisted, so existing files (named from the bare id) keep resolving.
  static String _fileBaseName(Track track) =>
      '${_sourceTypeOf(track) ?? 'local'}_${track.id}';
}

/// Whether the network policy lets a download run now, and why not when it
/// doesn't: held for Wi-Fi (mobile data not allowed) or waiting for a
/// connection (offline).
enum _NetworkDecision { allowed, needsWifi, offline }
