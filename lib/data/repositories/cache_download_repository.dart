import 'dart:async';

import '../../core/models/track.dart';
import '../../core/repositories/download_preferences.dart';
import '../../core/repositories/download_repository.dart';
import '../../core/repositories/download_store.dart';
import '../../core/repositories/offline_file_store.dart';
import '../../core/services/connectivity_service.dart';
import '../../core/services/remote_track_downloader.dart';

/// The app's [DownloadRepository]: it owns the offline-cache *policy* in one
/// place and delegates the moving parts to focused seams — durable metadata to
/// a [DownloadStore], cached bytes to an [OfflineFileStore], and the remote
/// byte-fetch to a [RemoteTrackDownloader].
///
/// Three promises are enforced here so a caller can't skip them:
///  - **User-initiated only.** Nothing is ever downloaded automatically; status
///    changes happen solely in response to [requestDownload] / [removeDownload].
///  - **Source-aware.** A remote (Jellyfin) track has its bytes fetched and
///    written to the offline directory; an on-device track is already local, so
///    it's recorded as available offline with no fetch and no managed file.
///  - **Wi-Fi only is respected.** When the user has set [DownloadPreferences.
///    wifiOnly] and the connection isn't Wi-Fi, a *remote* request is queued
///    rather than run, instead of silently going over mobile data.
///
/// Only the `downloaded` set is durable; `queued`/`downloading`/`failed` are
/// transient and live in memory, so a restart never resurrects a half-finished
/// download (there is no background worker yet — see README).
///
/// The authenticated URL a remote fetch needs is resolved inside the
/// [RemoteTrackDownloader] at fetch time; this repository never sees, stores, or
/// logs it, and a failed fetch surfaces only as the `failed` state.
class CacheDownloadRepository implements DownloadRepository {
  CacheDownloadRepository({
    required DownloadStore store,
    required OfflineFileStore files,
    required RemoteTrackDownloader downloader,
    required ConnectivityService connectivity,
    required DownloadPreferences preferences,
  })  : _store = store,
        _files = files,
        _downloader = downloader,
        _connectivity = connectivity,
        _preferences = preferences;

  final DownloadStore _store;
  final OfflineFileStore _files;
  final RemoteTrackDownloader _downloader;
  final ConnectivityService _connectivity;
  final DownloadPreferences _preferences;

  final Map<String, DownloadStatus> _statuses = <String, DownloadStatus>{};

  /// The durable cache references, loaded once and kept in sync with the store,
  /// so removal can find the file to delete and seeding stays cheap.
  final Map<String, CachedTrack> _downloads = <String, CachedTrack>{};

  final StreamController<Map<String, DownloadStatus>> _changes =
      StreamController<Map<String, DownloadStatus>>.broadcast();

  bool _loaded = false;

  /// Seeds the in-memory state from the durable cache, once.
  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    for (final CachedTrack cached in await _store.loadDownloads()) {
      _downloads[cached.trackId] = cached;
      _statuses[cached.trackId] = DownloadStatus.downloaded;
    }
    _loaded = true;
  }

  @override
  Stream<Map<String, DownloadStatus>> get statusStream async* {
    // Seed each listener with the current snapshot so the UI can render a
    // correct first frame, then forward live changes.
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
      // fetch — just record it as available offline (no managed cache file).
      await _record(CachedTrack(trackId: track.id));
      _set(track.id, DownloadStatus.downloaded);
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
      final String fileName = await _files.write(
        track.id,
        data.bytes,
        extension: data.fileExtension,
      );
      await _record(CachedTrack(trackId: track.id, fileName: fileName));
      _set(track.id, DownloadStatus.downloaded);
    } catch (_) {
      // The error is intentionally swallowed: it may carry source-specific
      // detail, and the UI only needs the failed state (offering a retry).
      _set(track.id, DownloadStatus.failed);
    }
  }

  @override
  Future<void> removeDownload(String trackId) async {
    await _ensureLoaded();
    final CachedTrack? existing = _downloads.remove(trackId);
    final String? fileName = existing?.fileName;
    if (fileName != null && fileName.isNotEmpty) {
      await _files.delete(fileName);
    }
    await _store.saveDownloads(_downloads.values.toList());
    // Also clears a queued/failed/downloading marker, so this doubles as cancel.
    _set(trackId, DownloadStatus.notDownloaded);
  }

  @override
  Future<List<String>> downloadedTrackIds() async {
    await _ensureLoaded();
    return _statuses.entries
        .where((e) => e.value == DownloadStatus.downloaded)
        .map((e) => e.key)
        .toList();
  }

  /// Releases the change stream. Call when the owning provider is disposed.
  Future<void> dispose() => _changes.close();

  /// The connectivity gate. With "Wi-Fi only" off, anything goes; with it on,
  /// only a Wi-Fi connection clears a download to start now.
  Future<bool> _allowedToDownloadNow() async {
    if (!await _preferences.wifiOnly()) return true;
    return await _connectivity.currentStatus() == NetworkStatus.wifi;
  }

  /// Records [cached] as downloaded and persists the updated set durably.
  Future<void> _record(CachedTrack cached) async {
    _downloads[cached.trackId] = cached;
    await _store.saveDownloads(_downloads.values.toList());
  }

  void _set(String trackId, DownloadStatus status) {
    if (status == DownloadStatus.notDownloaded) {
      _statuses.remove(trackId);
    } else {
      _statuses[trackId] = status;
    }
    _changes.add(_snapshot());
  }

  Map<String, DownloadStatus> _snapshot() =>
      Map<String, DownloadStatus>.unmodifiable(_statuses);
}
