import 'dart:async';

import 'package:linthra/core/models/download_progress.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/download_store.dart';

/// A scriptable [DownloadRepository] for the bulk-download tests.
///
/// Mirrors the real repository's *contract* rather than its internals: a
/// request completes only after an await (so concurrency is observable), an
/// already-downloaded track is a no-op, a failing track is marked `failed` and
/// reported as `started` (exactly as [CacheDownloadRepository] does), and only a
/// full cache throws.
class FakeDownloadRepository implements DownloadRepository {
  FakeDownloadRepository({
    Set<String> alreadyDownloaded = const <String>{},
    this.failingUris = const <String>{},
    this.outcomes = const <String, DownloadRequestOutcome>{},
    this.outOfSpaceAfter,
    this.tooLargeUris = const <String>{},
    this.inFlightElsewhereUris = const <String>{},
    this.maxCachedTracks,
    this.hold,
    this.failDownloadedKeys = false,
  })  : _downloaded = <String>{...alreadyDownloaded},
        // The real repository seeds a `downloaded` status for every cached
        // entry when it loads, and the status map is what callers read back.
        _statuses = <String, DownloadStatus>{
          for (final String key in alreadyDownloaded)
            key: DownloadStatus.downloaded,
        };

  /// Tracks whose fetch blows up mid-download. The repository swallows the error
  /// (the row shows `failed` with a retry), so the call still returns `started`.
  final Set<String> failingUris;

  /// Per-uri request outcomes, for the network-policy cases.
  final Map<String, DownloadRequestOutcome> outcomes;

  /// Once this many requests have been served, every later one throws
  /// [CacheStorageException], since the cache is full with nothing safe to
  /// evict.
  final int? outOfSpaceAfter;

  /// Tracks the cache refuses on their own size: the repository throws the same
  /// [CacheStorageException] for a track larger than the whole free-able cache
  /// as it does for a cache with nothing left to evict, and a smaller track
  /// after one of these can still fit.
  final Set<String> tooLargeUris;

  /// Tracks another surface is already downloading. The real repository sees its
  /// own in-flight reservation and returns "started" at once, leaving the track
  /// `downloading` rather than finished.
  final Set<String> inFlightElsewhereUris;

  /// A crude stand-in for the cache size limit: once this many tracks are
  /// cached, caching another evicts the least-recently added one, exactly as the
  /// real eviction policy drops unpinned, least-recently-played downloads.
  final int? maxCachedTracks;

  /// Makes [downloadedTrackKeys] throw, standing in for a durable store that
  /// cannot be read at all (so the batch itself cannot run).
  final bool failDownloadedKeys;

  /// When set, every request waits on it, so a test can hold a batch mid-flight
  /// and look at what the UI shows while it runs.
  final Completer<void>? hold;

  /// Every requested track uri, in the order the requests were made.
  final List<String> requested = <String>[];

  /// Track uris passed to [removeDownload].
  final List<String> removed = <String>[];

  /// The most requests that were ever outstanding at the same time.
  int peakConcurrency = 0;
  int _outstanding = 0;

  final Set<String> _downloaded;
  final Map<String, DownloadStatus> _statuses;
  final StreamController<Map<String, DownloadStatus>> _changes =
      StreamController<Map<String, DownloadStatus>>.broadcast();

  @override
  Stream<Map<String, DownloadStatus>> get statusStream async* {
    // The real repository opens with a snapshot before its change events, and
    // the downloads screen's lists depend on that first emission.
    yield Map<String, DownloadStatus>.unmodifiable(_statuses);
    yield* _changes.stream;
  }

  @override
  Stream<Map<String, DownloadProgress>> get progressStream =>
      const Stream<Map<String, DownloadProgress>>.empty();

  @override
  Future<DownloadStatus> statusFor(String trackId) async =>
      _statuses[trackId] ?? DownloadStatus.notDownloaded;

  @override
  Future<DownloadRequestOutcome> requestDownload(Track track) async {
    requested.add(track.uri);
    _outstanding++;
    peakConcurrency =
        _outstanding > peakConcurrency ? _outstanding : peakConcurrency;
    try {
      // A real request always crosses an await before it resolves; without one
      // the workers would run to completion one at a time and the concurrency
      // assertions would prove nothing.
      await Future<void>.delayed(Duration.zero);
      if (hold != null) await hold!.future;
      final String key = CachedTrack.cacheKeyForTrack(track);
      if (_downloaded.contains(key)) return DownloadRequestOutcome.started;
      if (outOfSpaceAfter != null && requested.length > outOfSpaceAfter!) {
        throw const CacheStorageException();
      }
      if (tooLargeUris.contains(track.uri)) {
        _set(key, DownloadStatus.notDownloaded);
        throw const CacheStorageException();
      }
      if (inFlightElsewhereUris.contains(track.uri)) {
        _set(key, DownloadStatus.downloading);
        return DownloadRequestOutcome.started;
      }
      final DownloadRequestOutcome outcome =
          outcomes[track.uri] ?? DownloadRequestOutcome.started;
      if (outcome != DownloadRequestOutcome.started) {
        _set(key, DownloadStatus.queued);
        return outcome;
      }
      if (failingUris.contains(track.uri)) {
        // What the real repository does with a mid-fetch failure: mark it
        // failed, then report the request itself as accepted.
        _set(key, DownloadStatus.failed);
        return DownloadRequestOutcome.started;
      }
      _downloaded.add(key);
      _set(key, DownloadStatus.downloaded);
      final int? limit = maxCachedTracks;
      while (limit != null && _downloaded.length > limit) {
        final String victim = _downloaded.first;
        _downloaded.remove(victim);
        _set(victim, DownloadStatus.notDownloaded);
      }
      return DownloadRequestOutcome.started;
    } finally {
      _outstanding--;
    }
  }

  @override
  Future<void> removeDownload(Track track) async {
    removed.add(track.uri);
    final String key = CachedTrack.cacheKeyForTrack(track);
    _downloaded.remove(key);
    _set(key, DownloadStatus.notDownloaded);
  }

  @override
  Future<List<String>> downloadedTrackKeys() async {
    if (failDownloadedKeys) throw StateError('store unavailable');
    return _downloaded.toList();
  }

  void _set(String key, DownloadStatus status) {
    _statuses[key] = status;
    _changes.add(Map<String, DownloadStatus>.unmodifiable(_statuses));
  }
}
