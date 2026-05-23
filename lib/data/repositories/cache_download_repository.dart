import 'dart:async';

import '../../core/repositories/download_preferences.dart';
import '../../core/repositories/download_repository.dart';
import '../../core/repositories/download_store.dart';
import '../../core/services/connectivity_service.dart';

/// The app's [DownloadRepository]: it owns the offline-cache *policy* in one
/// place and delegates only the durable bit (which IDs are cached) to a
/// [DownloadStore].
///
/// Two promises are enforced here so they can't be skipped by a caller:
///  - **User-initiated only.** Nothing is ever downloaded automatically; status
///    changes happen solely in response to [requestDownload] / [removeDownload].
///  - **Wi-Fi only is respected.** When the user has set [DownloadPreferences.
///    wifiOnly] and the connection isn't Wi-Fi, a request is *queued* rather
///    than run, instead of silently going over mobile data.
///
/// Only the `downloaded` state is durable; `queued`/`downloading`/`failed` are
/// transient and live in memory, so a restart never resurrects a half-finished
/// download (there is no background worker yet — see README).
///
/// "Downloading" is trivial today because the only source is local files that
/// are already on disk, so marking a track offline just records it. The real
/// byte-fetch for remote sources slots in at [_obtainOfflineCopy] without
/// touching the policy above.
class CacheDownloadRepository implements DownloadRepository {
  CacheDownloadRepository({
    required DownloadStore store,
    required ConnectivityService connectivity,
    required DownloadPreferences preferences,
  })  : _store = store,
        _connectivity = connectivity,
        _preferences = preferences;

  final DownloadStore _store;
  final ConnectivityService _connectivity;
  final DownloadPreferences _preferences;

  final Map<String, DownloadStatus> _statuses = <String, DownloadStatus>{};
  final StreamController<Map<String, DownloadStatus>> _changes =
      StreamController<Map<String, DownloadStatus>>.broadcast();

  bool _loaded = false;

  /// Seeds the in-memory status map from the durable set of cached IDs, once.
  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    for (final String id in await _store.loadDownloadedIds()) {
      _statuses[id] = DownloadStatus.downloaded;
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
  Future<void> requestDownload(String trackId) async {
    await _ensureLoaded();
    final DownloadStatus current =
        _statuses[trackId] ?? DownloadStatus.notDownloaded;
    // Already done or in flight — never re-trigger. A queued or failed track,
    // by contrast, is fair game for an explicit retry.
    if (current == DownloadStatus.downloaded ||
        current == DownloadStatus.downloading) {
      return;
    }

    if (!await _allowedToDownloadNow()) {
      _set(trackId, DownloadStatus.queued);
      return;
    }

    _set(trackId, DownloadStatus.downloading);
    try {
      await _obtainOfflineCopy(trackId);
      await _persistDownloaded(trackId);
      _set(trackId, DownloadStatus.downloaded);
    } catch (_) {
      _set(trackId, DownloadStatus.failed);
    }
  }

  @override
  Future<void> removeDownload(String trackId) async {
    await _ensureLoaded();
    final Set<String> ids = await _store.loadDownloadedIds();
    ids.remove(trackId);
    await _store.saveDownloadedIds(ids);
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

  /// Fetches/produces the offline copy for [trackId]. A no-op for local files
  /// (the bytes are already on disk); the extension point for remote sources.
  Future<void> _obtainOfflineCopy(String trackId) async {}

  Future<void> _persistDownloaded(String trackId) async {
    final Set<String> ids = await _store.loadDownloadedIds();
    ids.add(trackId);
    await _store.saveDownloadedIds(ids);
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
