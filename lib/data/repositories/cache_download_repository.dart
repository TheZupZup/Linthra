import 'dart:async';

import '../../core/models/track.dart';
import '../../core/repositories/download_preferences.dart';
import '../../core/repositories/download_repository.dart';
import '../../core/repositories/download_store.dart';
import '../../core/repositories/offline_file_store.dart';
import '../../core/services/cache_eviction_policy.dart';
import '../../core/services/connectivity_service.dart';
import '../../core/services/offline_cache_manager.dart';
import '../../core/services/remote_track_downloader.dart';

/// The app's [DownloadRepository] *and* [OfflineCacheManager]: it owns the
/// offline-cache *policy* in one place and delegates the moving parts to focused
/// seams — durable metadata to a [DownloadStore], cached bytes to an
/// [OfflineFileStore], the remote byte-fetch to a [RemoteTrackDownloader], and
/// the (pure) eviction decision to a [CacheEvictionPolicy].
///
/// Promises enforced here so a caller can't skip them:
///  - **User-initiated only.** Nothing is ever downloaded automatically; status
///    changes happen solely in response to [requestDownload] / [removeDownload]
///    (or an explicit clear / pin).
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
    implements DownloadRepository, OfflineCacheManager {
  CacheDownloadRepository({
    required DownloadStore store,
    required OfflineFileStore files,
    required RemoteTrackDownloader downloader,
    required ConnectivityService connectivity,
    required DownloadPreferences preferences,
    CacheEvictionPolicy policy = const CacheEvictionPolicy(),
    String? Function()? currentlyPlayingTrackId,
    DateTime Function()? now,
  })  : _store = store,
        _files = files,
        _downloader = downloader,
        _connectivity = connectivity,
        _preferences = preferences,
        _policy = policy,
        _currentlyPlayingTrackId = currentlyPlayingTrackId,
        _now = now ?? DateTime.now;

  final DownloadStore _store;
  final OfflineFileStore _files;
  final RemoteTrackDownloader _downloader;
  final ConnectivityService _connectivity;
  final DownloadPreferences _preferences;
  final CacheEvictionPolicy _policy;

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

  final StreamController<Map<String, DownloadStatus>> _changes =
      StreamController<Map<String, DownloadStatus>>.broadcast();

  final StreamController<CacheSnapshot> _cacheChanges =
      StreamController<CacheSnapshot>.broadcast();

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
      _statuses[cached.trackId] = DownloadStatus.downloaded;
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
  Future<void> requestDownload(Track track) async {
    await _ensureLoaded();
    final DownloadStatus current =
        _statuses[track.id] ?? DownloadStatus.notDownloaded;
    // Already done or in flight — never re-trigger. A queued or failed track,
    // by contrast, is fair game for an explicit retry.
    if (current == DownloadStatus.downloaded ||
        current == DownloadStatus.downloading) {
      return;
    }

    if (!_downloader.isRemote(track)) {
      // On-device track: the bytes are already local, so there's nothing to
      // fetch and no managed file — just record it as available offline.
      _downloads[track.id] = CachedTrack(
        trackId: track.id,
        sourceType: _sourceTypeOf(track),
        cachedAt: _now(),
      );
      await _save();
      _statuses[track.id] = DownloadStatus.downloaded;
      _emitStatus();
      _emitCache();
      return;
    }

    // Remote track: the Wi-Fi gate only matters here, where there are bytes to
    // pull over the network.
    if (!await _allowedToDownloadNow()) {
      _set(track.id, DownloadStatus.queued);
      return;
    }

    _set(track.id, DownloadStatus.downloading);
    try {
      final RemoteTrackData data = await _downloader.fetch(track);
      await _cacheRemote(track, data);
    } on CacheStorageException {
      // Space was reset below before throwing; surface the friendly error so
      // the UI can tell the user to free space or raise the limit.
      rethrow;
    } catch (_) {
      // Other errors may carry source-specific detail; the UI only needs the
      // failed state (offering a retry).
      _set(track.id, DownloadStatus.failed);
    }
  }

  /// Writes a freshly fetched remote download, evicting first to stay under the
  /// limit. Throws [CacheStorageException] (after resetting status) when it
  /// can't fit even after evicting everything safe to remove.
  Future<void> _cacheRemote(Track track, RemoteTrackData data) async {
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
      _set(track.id, DownloadStatus.notDownloaded);
      throw const CacheStorageException();
    }

    for (final CachedTrack victim in plan.evict) {
      await _deleteManagedFile(victim);
      _downloads.remove(victim.trackId);
      _statuses.remove(victim.trackId);
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
      lastAccessedAt: now,
    );
    await _save();
    _statuses[track.id] = DownloadStatus.downloaded;
    _emitStatus();
    _emitCache();
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

  Map<String, DownloadStatus> _snapshot() =>
      Map<String, DownloadStatus>.unmodifiable(_statuses);

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
