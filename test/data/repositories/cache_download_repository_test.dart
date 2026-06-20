import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/download_progress.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/repositories/offline_file_store.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/download_scheduler.dart';
import 'package:linthra/core/services/offline_cache_manager.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/data/repositories/cache_download_repository.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/data/repositories/in_memory_download_store.dart';
import 'package:linthra/data/repositories/in_memory_offline_file_store.dart';
import 'package:linthra/data/repositories/store_cached_track_locator.dart';

/// A connectivity stand-in whose reported status the test can flip at will.
class _FakeConnectivity implements ConnectivityService {
  _FakeConnectivity(this.status);

  NetworkStatus status;

  @override
  Stream<NetworkStatus> get statusStream => Stream<NetworkStatus>.value(status);

  @override
  Future<NetworkStatus> currentStatus() async => status;
}

/// A remote downloader fake: treats `jellyfin:` tracks as remote and returns
/// canned bytes, or throws when [error] is set, so the repository's remote path
/// can be driven without a server or HTTP.
///
/// When [gate] is set, every [fetch] awaits it before completing, so a test can
/// hold downloads in flight and observe how many run at once ([maxActive]).
/// [error] is mutable so a test can fail an attempt, then clear it and retry.
class _FakeRemoteDownloader implements RemoteTrackDownloader {
  _FakeRemoteDownloader({
    this.error,
    this.gate,
    this.schemes = const <String>['jellyfin:'],
  });

  /// The canned bytes every successful fetch returns.
  static const List<int> bytes = <int>[1, 2, 3, 4];

  /// When set, [fetch] throws this instead of returning bytes.
  Object? error;

  /// When set, [fetch] awaits this before completing.
  final Future<void>? gate;

  /// The remote URI schemes this fake claims. Defaults to Jellyfin so existing
  /// tests are unchanged; the Plex group overrides it (and the isolation test
  /// claims both providers at once).
  final List<String> schemes;

  int fetchCount = 0;
  int activeNow = 0;
  int maxActive = 0;
  final List<Track> fetched = <Track>[];

  @override
  bool isRemote(Track track) => schemes.any(track.uri.startsWith);

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    fetchCount++;
    activeNow++;
    if (activeNow > maxActive) maxActive = activeNow;
    fetched.add(track);
    try {
      onProgress?.call(2, bytes.length);
      final Future<void>? pending = gate;
      if (pending != null) await pending;
      final Object? err = error;
      if (err != null) throw err;
      onProgress?.call(bytes.length, bytes.length);
      return const RemoteTrackData(bytes: bytes, fileExtension: 'mp3');
    } finally {
      activeNow--;
    }
  }
}

/// Wraps an in-memory file store and records every delete, so a test can prove
/// the cache only ever deletes app-managed files (never a local source file).
class _SpyOfflineFileStore implements OfflineFileStore {
  _SpyOfflineFileStore(this._inner);

  final InMemoryOfflineFileStore _inner;
  final List<String> deleted = <String>[];

  List<int>? bytesFor(String fileName) => _inner.bytesFor(fileName);

  @override
  Future<String> write(String trackId, List<int> bytes, {String? extension}) =>
      _inner.write(trackId, bytes, extension: extension);

  @override
  Future<String?> pathFor(String fileName) => _inner.pathFor(fileName);

  @override
  Future<int?> sizeFor(String fileName) => _inner.sizeFor(fileName);

  @override
  Future<void> delete(String fileName) {
    deleted.add(fileName);
    return _inner.delete(fileName);
  }
}

Track _local(String id) => Track(id: id, title: id, uri: 'file:///$id.mp3');
Track _jellyfin(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');
Track _plex(String id) => Track(id: id, title: id, uri: 'plex:$id');
Track _subsonic(String id) => Track(id: id, title: id, uri: 'subsonic:$id');

void main() {
  group('CacheDownloadRepository', () {
    late InMemoryDownloadStore store;
    late InMemoryOfflineFileStore files;
    late InMemoryDownloadPreferences preferences;
    late _FakeConnectivity connectivity;
    late _FakeRemoteDownloader downloader;

    CacheDownloadRepository build() {
      return CacheDownloadRepository(
        store: store,
        files: files,
        downloader: downloader,
        connectivity: connectivity,
        preferences: preferences,
      );
    }

    setUp(() {
      store = InMemoryDownloadStore();
      files = InMemoryOfflineFileStore();
      preferences = InMemoryDownloadPreferences();
      connectivity = _FakeConnectivity(NetworkStatus.wifi);
      downloader = _FakeRemoteDownloader();
    });

    test('a Jellyfin track starts not downloaded', () async {
      final repository = build();
      expect(
        await repository.statusFor('j1'),
        DownloadStatus.notDownloaded,
      );
      expect(await repository.downloadedTrackIds(), isEmpty);
    });

    test('downloading a Jellyfin track stores a cached file reference',
        () async {
      final repository = build();

      await repository.requestDownload(_jellyfin('j1'));

      expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      expect(downloader.fetchCount, 1);

      final List<CachedTrack> saved = await store.loadDownloads();
      expect(saved, hasLength(1));
      expect(saved.single.trackId, 'j1');
      expect(saved.single.fileName, isNotNull);
      // The fetched bytes were written to the cache under that file name.
      expect(files.bytesFor(saved.single.fileName!), <int>[1, 2, 3, 4]);
    });

    test('removing a downloaded Jellyfin track deletes the cached file',
        () async {
      final repository = build();
      await repository.requestDownload(_jellyfin('j1'));
      final String fileName = (await store.loadDownloads()).single.fileName!;

      await repository.removeDownload(_jellyfin('j1'));

      expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
      expect(await repository.downloadedTrackIds(), isEmpty);
      expect(await store.loadDownloads(), isEmpty);
      expect(files.bytesFor(fileName), isNull);
    });

    test('a failed remote fetch surfaces as failed and stores nothing',
        () async {
      downloader = _FakeRemoteDownloader(error: Exception('boom'));
      final repository = build();

      await repository.requestDownload(_jellyfin('j1'));

      expect(await repository.statusFor('j1'), DownloadStatus.failed);
      expect(await store.loadDownloads(), isEmpty);
      expect(await repository.downloadedTrackIds(), isEmpty);
    });

    test('a failed Jellyfin track can be retried', () async {
      downloader = _FakeRemoteDownloader(error: Exception('boom'));
      final repository = build();
      await repository.requestDownload(_jellyfin('j1'));
      expect(await repository.statusFor('j1'), DownloadStatus.failed);

      // A retry with a downloader that now succeeds reaches downloaded.
      downloader = _FakeRemoteDownloader();
      final retryRepository = CacheDownloadRepository(
        store: store,
        files: files,
        downloader: downloader,
        connectivity: connectivity,
        preferences: preferences,
      );
      await retryRepository.requestDownload(_jellyfin('j1'));

      expect(await retryRepository.statusFor('j1'), DownloadStatus.downloaded);
    });

    group('local tracks are treated as already local', () {
      test('a local track is recorded without a remote fetch or cached file',
          () async {
        final repository = build();

        await repository.requestDownload(_local('a'));

        expect(await repository.statusFor('a'), DownloadStatus.downloaded);
        // No remote fetch happened, and no managed cache file was written.
        expect(downloader.fetchCount, 0);
        final List<CachedTrack> saved = await store.loadDownloads();
        expect(saved.single.trackId, 'a');
        expect(saved.single.fileName, isNull);
      });

      test('removing a local track clears it without touching files', () async {
        final repository = build();
        await repository.requestDownload(_local('a'));

        await repository.removeDownload(_local('a'));

        expect(await repository.statusFor('a'), DownloadStatus.notDownloaded);
        expect(await store.loadDownloads(), isEmpty);
      });
    });

    test('no token is stored in the track uri or the cache metadata', () async {
      const String token = 'super-secret-token';
      // Even if a downloader's source minted a tokenized URL, the repository
      // only ever sees bytes — the persisted file name is derived from the id.
      final track = _jellyfin('item-42');
      final repository = build();

      await repository.requestDownload(track);

      final CachedTrack saved = (await store.loadDownloads()).single;
      expect(saved.trackId, 'item-42');
      expect(saved.fileName, isNot(contains(token)));
      expect(saved.fileName, isNot(contains('api_key')));
      // The track itself still carries only the opaque jellyfin: uri.
      expect(track.uri, 'jellyfin:item-42');
    });

    test('downloaded references are reloaded by a fresh repository', () async {
      await build().requestDownload(_jellyfin('j1'));

      final reopened = build();
      expect(await reopened.statusFor('j1'), DownloadStatus.downloaded);
      expect(await reopened.downloadedTrackIds(), <String>['j1']);
    });

    test('statusStream seeds the current snapshot then emits changes',
        () async {
      await build().requestDownload(_jellyfin('j1'));
      final repository = build();

      final emissions = <Map<String, DownloadStatus>>[];
      final sub = repository.statusStream.listen(emissions.add);
      await _settle();

      expect(emissions.first, <String, DownloadStatus>{
        'j1': DownloadStatus.downloaded,
      });

      await repository.requestDownload(_jellyfin('j2'));
      await _settle();

      expect(emissions.last['j2'], DownloadStatus.downloaded);
      await sub.cancel();
    });

    test('a downloaded track is not re-downloaded', () async {
      final repository = build();
      await repository.requestDownload(_jellyfin('j1'));
      expect(downloader.fetchCount, 1);

      await repository.requestDownload(_jellyfin('j1'));

      // No second fetch was attempted.
      expect(downloader.fetchCount, 1);
    });

    group('mobile-data policy (remote downloads)', () {
      test('Wi-Fi only by default: queues on mobile and reports why', () async {
        // Default preference: mobile data is not allowed.
        connectivity.status = NetworkStatus.mobile;
        final repository = build();

        final DownloadRequestOutcome outcome =
            await repository.requestDownload(_jellyfin('j1'));

        expect(outcome, DownloadRequestOutcome.waitingForWifi);
        expect(await repository.statusFor('j1'), DownloadStatus.queued);
        expect(downloader.fetchCount, 0);
        expect(await store.loadDownloads(), isEmpty);
      });

      test('downloads when on Wi-Fi even with mobile data not allowed',
          () async {
        connectivity.status = NetworkStatus.wifi;
        final repository = build();

        final DownloadRequestOutcome outcome =
            await repository.requestDownload(_jellyfin('j1'));

        expect(outcome, DownloadRequestOutcome.started);
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      });

      test('downloads over mobile when the user allows mobile data', () async {
        await preferences.setAllowMobileData(true);
        connectivity.status = NetworkStatus.mobile;
        final repository = build();

        final DownloadRequestOutcome outcome =
            await repository.requestDownload(_jellyfin('j1'));

        expect(outcome, DownloadRequestOutcome.started);
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      });

      test('queues with a connection-waiting reason when offline', () async {
        // Even with mobile data allowed, offline means there is no link to use.
        await preferences.setAllowMobileData(true);
        connectivity.status = NetworkStatus.offline;
        final repository = build();

        final DownloadRequestOutcome outcome =
            await repository.requestDownload(_jellyfin('j1'));

        expect(outcome, DownloadRequestOutcome.waitingForConnection);
        expect(await repository.statusFor('j1'), DownloadStatus.queued);
        expect(downloader.fetchCount, 0);
      });

      test('treats an unknown connection conservatively, like mobile data',
          () async {
        connectivity.status = NetworkStatus.unknown;
        final repository = build();

        // Mobile data not allowed: an unknown link is held for Wi-Fi…
        expect(
          await repository.requestDownload(_jellyfin('j1')),
          DownloadRequestOutcome.waitingForWifi,
        );
        expect(await repository.statusFor('j1'), DownloadStatus.queued);

        // …and allowed once the user opts into mobile data.
        await preferences.setAllowMobileData(true);
        expect(
          await repository.requestDownload(_jellyfin('j1')),
          DownloadRequestOutcome.started,
        );
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      });

      test('a local track is never queued, even on mobile data', () async {
        connectivity.status = NetworkStatus.mobile;
        final repository = build();

        final DownloadRequestOutcome outcome =
            await repository.requestDownload(_local('a'));

        // Already local: the network gate doesn't apply (no bytes to fetch).
        expect(outcome, DownloadRequestOutcome.started);
        expect(await repository.statusFor('a'), DownloadStatus.downloaded);
      });

      test('a queued track downloads on an explicit retry once on Wi-Fi',
          () async {
        connectivity.status = NetworkStatus.mobile;
        final repository = build();
        await repository.requestDownload(_jellyfin('j1'));
        expect(await repository.statusFor('j1'), DownloadStatus.queued);

        connectivity.status = NetworkStatus.wifi;
        await repository.requestDownload(_jellyfin('j1'));

        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      });

      test('blocked-download messages are friendly and secret-free', () async {
        // No URL, token, scheme, or path leaks into what the user would see.
        const String wifi =
            'Downloads are limited to Wi-Fi. Turn on "Allow mobile data" in '
            'Settings to download over mobile data.';
        const String offline =
            "You're offline. This download will start automatically when "
            "you're back online.";
        expect(DownloadRequestOutcome.waitingForWifi.blockedMessage, wifi);
        expect(
          DownloadRequestOutcome.waitingForConnection.blockedMessage,
          offline,
        );
        expect(DownloadRequestOutcome.started.blockedMessage, isNull);
        for (final String message in <String>[wifi, offline]) {
          expect(message, isNot(contains('jellyfin:')));
          expect(message, isNot(contains('http')));
          expect(message, isNot(contains('token')));
          expect(message, isNot(contains('/')));
        }
      });
    });

    group('cache metadata', () {
      test('a download records size, timestamps and source type', () async {
        final repository = build();

        await repository.requestDownload(_jellyfin('j1'));

        final CachedTrack saved = (await store.loadDownloads()).single;
        // Each canned fetch returns 4 bytes.
        expect(saved.sizeBytes, 4);
        expect(saved.cachedAt, isNotNull);
        expect(saved.lastAccessedAt, isNotNull);
        // The non-secret URI scheme, never the full URL/token.
        expect(saved.sourceType, 'jellyfin');
        expect(saved.pinned, isFalse);
      });

      test('cacheSnapshot totals only app-managed bytes', () async {
        final repository = build();
        await repository.requestDownload(_jellyfin('j1')); // 4 managed bytes
        await repository.requestDownload(_local('a')); // on-device, 0 bytes

        final CacheSnapshot snapshot = await repository.cacheSnapshot();
        expect(snapshot.usedBytes, 4);
        expect(snapshot.entries, hasLength(2));
        expect(snapshot.managedCount, 1);
      });

      test('a managed entry missing its size is backfilled from disk on load',
          () async {
        // Simulate a record written by an earlier version: file present, but
        // no sizeBytes recorded.
        final String fileName = await files
            .write('j1', const <int>[1, 2, 3, 4, 5], extension: 'mp3');
        await store.saveDownloads(<CachedTrack>[
          CachedTrack(trackId: 'j1', fileName: fileName),
        ]);

        final repository = build();
        final CacheSnapshot snapshot = await repository.cacheSnapshot();

        expect(snapshot.usedBytes, 5);
        expect((await store.loadDownloads()).single.sizeBytes, 5);
      });

      test('stale metadata for a missing file is pruned on load', () async {
        final String present =
            await files.write('here', const <int>[1, 2, 3], extension: 'mp3');
        await store.saveDownloads(<CachedTrack>[
          CachedTrack(trackId: 'here', fileName: present, sizeBytes: 3),
          // Points at a file the store doesn't have (OS reclaimed it).
          const CachedTrack(
              trackId: 'gone', fileName: 'gone.mp3', sizeBytes: 9),
        ]);

        final repository = build();

        expect(await repository.statusFor('here'), DownloadStatus.downloaded);
        expect(
            await repository.statusFor('gone'), DownloadStatus.notDownloaded);
        // The prune is persisted, so the stale record doesn't linger.
        final List<CachedTrack> remaining = await store.loadDownloads();
        expect(remaining.map((c) => c.trackId), <String>['here']);
      });
    });

    group('cache limit and eviction', () {
      // A clock that advances one minute per call, so cachedAt/lastAccessedAt
      // are distinct and least-recently-used ordering is deterministic.
      DateTime Function() incrementingClock() {
        int tick = 0;
        return () => DateTime(2024, 1, 1).add(Duration(minutes: tick++));
      }

      CacheDownloadRepository buildLimited({
        required int maxBytes,
        Track? Function()? currentlyPlaying,
        DateTime Function()? now,
      }) {
        preferences = InMemoryDownloadPreferences(maxCacheBytes: maxBytes);
        return CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
          currentlyPlayingTrack: currentlyPlaying,
          now: now,
        );
      }

      test('downloading under the limit succeeds without eviction', () async {
        // Room for two 4-byte downloads.
        final repository = buildLimited(maxBytes: 10);

        await repository.requestDownload(_jellyfin('j1'));
        await repository.requestDownload(_jellyfin('j2'));

        final List<String> ids = await repository.downloadedTrackIds();
        ids.sort();
        expect(ids, <String>['j1', 'j2']);
        expect((await repository.cacheSnapshot()).usedBytes, 8);
      });

      test('downloading over the limit evicts the least-recently-used track',
          () async {
        final repository = buildLimited(maxBytes: 10, now: incrementingClock());

        await repository.requestDownload(_jellyfin('j1')); // oldest
        await repository.requestDownload(_jellyfin('j2'));
        await repository.requestDownload(_jellyfin('j3')); // forces eviction

        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect(await repository.statusFor('j2'), DownloadStatus.downloaded);
        expect(await repository.statusFor('j3'), DownloadStatus.downloaded);
        // The evicted file's bytes are gone from disk.
        expect(files.bytesFor('jellyfin_j1.mp3'), isNull);
      });

      test(
          'the cache limit is still enforced when downloading over mobile data',
          () async {
        final repository = buildLimited(maxBytes: 10, now: incrementingClock());
        await preferences.setAllowMobileData(true);
        connectivity.status = NetworkStatus.mobile;

        await repository.requestDownload(_jellyfin('j1')); // oldest
        await repository.requestDownload(_jellyfin('j2'));
        await repository.requestDownload(_jellyfin('j3')); // forces eviction

        // Allowing mobile data never lets the cache exceed its limit.
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect(
          (await repository.cacheSnapshot()).usedBytes,
          lessThanOrEqualTo(10),
        );
      });

      test('playing a track refreshes it so a stale one is evicted instead',
          () async {
        final repository = buildLimited(maxBytes: 10, now: incrementingClock());

        await repository.requestDownload(_jellyfin('j1'));
        await repository.requestDownload(_jellyfin('j2'));
        // j1 was just played, so j2 is now the least-recently-used.
        await repository.notePlayed(_jellyfin('j1'));
        await repository.requestDownload(_jellyfin('j3'));

        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
        expect(await repository.statusFor('j2'), DownloadStatus.notDownloaded);
        expect(await repository.statusFor('j3'), DownloadStatus.downloaded);
      });

      test('pinned tracks are never evicted automatically', () async {
        final repository = buildLimited(maxBytes: 10, now: incrementingClock());

        await repository.requestDownload(_jellyfin('j1')); // oldest
        await repository.setPinned(_jellyfin('j1'), true);
        await repository.requestDownload(_jellyfin('j2'));
        await repository.requestDownload(_jellyfin('j3')); // forces eviction

        // j1 is pinned, so the unpinned j2 goes instead.
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
        expect(await repository.statusFor('j2'), DownloadStatus.notDownloaded);
        expect(await repository.statusFor('j3'), DownloadStatus.downloaded);
      });

      test('the currently playing track is never evicted', () async {
        final repository = buildLimited(
          maxBytes: 10,
          currentlyPlaying: () => _jellyfin('j1'),
          now: incrementingClock(),
        );

        await repository.requestDownload(_jellyfin('j1')); // oldest + playing
        await repository.requestDownload(_jellyfin('j2'));
        await repository.requestDownload(_jellyfin('j3')); // forces eviction

        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
        expect(await repository.statusFor('j2'), DownloadStatus.notDownloaded);
        expect(await repository.statusFor('j3'), DownloadStatus.downloaded);
      });

      test('refuses with a friendly, secret-free error when nothing is safe',
          () async {
        // Room for one 4-byte track only.
        final repository = buildLimited(maxBytes: 4);
        await repository.requestDownload(_jellyfin('j1'));
        await repository.setPinned(_jellyfin('j1'), true);

        Object? caught;
        try {
          await repository.requestDownload(_jellyfin('j2'));
        } catch (error) {
          caught = error;
        }

        expect(caught, isA<CacheStorageException>());
        // The error never carries a URL, token, or path.
        final String message = (caught! as CacheStorageException).message;
        expect(message.toLowerCase(), isNot(contains('http')));
        expect(message.toLowerCase(), isNot(contains('token')));
        expect(message, isNot(contains('/')));

        // j2 was not cached and j1 (pinned) was left untouched.
        expect(await repository.statusFor('j2'), DownloadStatus.notDownloaded);
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
        expect((await store.loadDownloads()).map((c) => c.trackId),
            <String>['j1']);
        expect(files.bytesFor('jellyfin_j1.mp3'), isNotNull);
      });
    });

    group('parallel downloads', () {
      test('runs several downloads at once, bounded by the concurrency limit',
          () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository = CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
          scheduler: DownloadScheduler(maxConcurrent: 2),
        );

        final futures = <Future<void>>[
          repository.requestDownload(_jellyfin('j1')),
          repository.requestDownload(_jellyfin('j2')),
          repository.requestDownload(_jellyfin('j3')),
        ];

        // Only two may fetch at once; the third waits its turn as "queued".
        await _pumpUntil(() => downloader.fetchCount >= 2);
        expect(downloader.fetchCount, 2);
        expect(downloader.maxActive, 2);

        final statuses = <DownloadStatus>[
          await repository.statusFor('j1'),
          await repository.statusFor('j2'),
          await repository.statusFor('j3'),
        ];
        expect(
          statuses.where((s) => s == DownloadStatus.downloading).length,
          2,
        );
        expect(statuses.where((s) => s == DownloadStatus.queued).length, 1);

        // Releasing the gate lets all three finish — still never more than two
        // fetching at any instant.
        gate.complete();
        await Future.wait(futures);
        expect(downloader.fetchCount, 3);
        expect(downloader.maxActive, 2);
        final List<String> ids = await repository.downloadedTrackIds();
        ids.sort();
        expect(ids, <String>['j1', 'j2', 'j3']);
      });

      test('a duplicate request for the same track is not started twice',
          () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository = build();

        final f1 = repository.requestDownload(_jellyfin('j1'));
        final f2 = repository.requestDownload(_jellyfin('j1'));

        // The second request bails on the in-flight guard before fetching.
        await _pumpUntil(() => downloader.fetchCount >= 1);
        expect(downloader.fetchCount, 1);

        gate.complete();
        await Future.wait(<Future<void>>[f1, f2]);

        expect(downloader.fetchCount, 1);
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      });

      test('respects the cache limit even when downloads finish concurrently',
          () async {
        // Room for exactly two 4-byte downloads.
        preferences = InMemoryDownloadPreferences(maxCacheBytes: 8);
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository = CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
          scheduler: DownloadScheduler(maxConcurrent: 3),
        );

        final futures = <Future<void>>[
          repository.requestDownload(_jellyfin('j1')),
          repository.requestDownload(_jellyfin('j2')),
          repository.requestDownload(_jellyfin('j3')),
        ];
        // All three fetch in parallel, then commit serially once released.
        await _pumpUntil(() => downloader.fetchCount >= 3);
        expect(downloader.maxActive, 3);
        gate.complete();
        await Future.wait(futures);

        // The serialized commit kept usage at the limit (never 12), evicting
        // the least-recently-used one to make room for the third.
        final CacheSnapshot snapshot = await repository.cacheSnapshot();
        expect(snapshot.usedBytes, 8);
        expect(snapshot.managedCount, 2);
      });

      test('reports byte progress while downloading, then clears it on finish',
          () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository = build();

        final emissions = <Map<String, DownloadProgress>>[];
        final sub = repository.progressStream.listen(emissions.add);

        final future = repository.requestDownload(_jellyfin('j1'));
        await _pumpUntil(() => emissions.any((m) => m['j1'] != null));

        final DownloadProgress? mid = emissions.last['j1'];
        expect(mid, isNotNull);
        expect(mid!.receivedBytes, 2);
        expect(mid.totalBytes, 4);
        expect(mid.fraction, 0.5);

        gate.complete();
        await future;
        await _settle();

        // Progress is cleared once the download finishes.
        expect(emissions.last['j1'], isNull);
        await sub.cancel();
      });

      test('a failed download can be retried on the same repository', () async {
        downloader = _FakeRemoteDownloader(error: Exception('boom'));
        final repository = build();
        await repository.requestDownload(_jellyfin('j1'));
        expect(await repository.statusFor('j1'), DownloadStatus.failed);
        expect(downloader.fetchCount, 1);

        // Clear the fault and retry through the same repository instance: the
        // in-flight reservation was released, so the retry proceeds.
        downloader.error = null;
        await repository.requestDownload(_jellyfin('j1'));

        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
        expect(downloader.fetchCount, 2);
      });
    });

    group('preload (prefetch)', () {
      test('caches a remote track without giving it a download status',
          () async {
        final repository = build();

        await repository.prefetch(_jellyfin('j1'));

        // Invisible as a download, but cached and counted toward usage.
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect(await repository.downloadedTrackIds(), isEmpty);
        final CachedTrack saved = (await store.loadDownloads()).single;
        expect(saved.trackId, 'j1');
        expect(saved.preloaded, isTrue);
        expect(saved.fileName, isNotNull);
        expect((await repository.cacheSnapshot()).usedBytes, 4);
      });

      test('skips a local track (already on disk)', () async {
        final repository = build();

        await repository.prefetch(_local('a'));

        expect(downloader.fetchCount, 0);
        expect(await store.loadDownloads(), isEmpty);
      });

      test('skips a track that is already downloaded', () async {
        final repository = build();
        await repository.requestDownload(_jellyfin('j1'));
        expect(downloader.fetchCount, 1);

        await repository.prefetch(_jellyfin('j1'));

        expect(downloader.fetchCount, 1);
      });

      test('is best-effort: a failed fetch caches nothing and never throws',
          () async {
        downloader = _FakeRemoteDownloader(error: Exception('boom'));
        final repository = build();

        await repository.prefetch(_jellyfin('j1'));

        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect(await store.loadDownloads(), isEmpty);
      });

      test('skips (without queueing) on mobile when mobile data not allowed',
          () async {
        // Default: mobile data is not allowed, so pre-cache stays Wi-Fi-only.
        connectivity.status = NetworkStatus.mobile;
        final repository = build();

        await repository.prefetch(_jellyfin('j1'));

        expect(downloader.fetchCount, 0);
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect(await store.loadDownloads(), isEmpty);
      });

      test('runs on mobile when the user allows mobile data', () async {
        await preferences.setAllowMobileData(true);
        connectivity.status = NetworkStatus.mobile;
        final repository = build();

        await repository.prefetch(_jellyfin('j1'));

        // Pre-cached over mobile, but it stays invisible as a download.
        expect(downloader.fetchCount, 1);
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect((await store.loadDownloads()).single.preloaded, isTrue);
      });

      test('skips when offline, even with mobile data allowed', () async {
        await preferences.setAllowMobileData(true);
        connectivity.status = NetworkStatus.offline;
        final repository = build();

        await repository.prefetch(_jellyfin('j1'));

        expect(downloader.fetchCount, 0);
        expect(await store.loadDownloads(), isEmpty);
      });

      test('an explicit download promotes a preloaded copy without re-fetching',
          () async {
        final repository = build();
        await repository.prefetch(_jellyfin('j1'));
        expect(downloader.fetchCount, 1);

        await repository.requestDownload(_jellyfin('j1'));

        // Promoted in place: now a real download, still only one fetch total.
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
        expect(downloader.fetchCount, 1);
        expect((await store.loadDownloads()).single.preloaded, isFalse);
      });

      test('a preloaded track is evicted before a user download', () async {
        // Room for two 4-byte entries; a third forces one out.
        preferences = InMemoryDownloadPreferences(maxCacheBytes: 10);
        final repository = CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
        );
        await repository.requestDownload(_jellyfin('keep')); // user download
        await repository.prefetch(_jellyfin('warm')); // preload
        await repository.requestDownload(_jellyfin('new')); // forces eviction

        // The preload is sacrificed; the user download survives.
        expect(await repository.statusFor('keep'), DownloadStatus.downloaded);
        expect(await repository.statusFor('new'), DownloadStatus.downloaded);
        final List<String> ids = (await store.loadDownloads())
            .map((c) => c.trackId)
            .toList()
          ..sort();
        expect(ids, <String>['keep', 'new']);
      });

      test('a repeated pre-cache for the same track does not fetch twice',
          () async {
        final repository = build();

        await repository.prefetch(_jellyfin('j1'));
        await repository.prefetch(_jellyfin('j1'));

        // The second pre-cache bails on the already-cached guard before fetch.
        expect(downloader.fetchCount, 1);
        expect((await store.loadDownloads()).single.trackId, 'j1');
      });

      test(
          'respects the cache limit: a pre-cache that cannot fit is skipped, '
          'never throws, and evicts nothing protected', () async {
        // Room for exactly one 4-byte track, already taken by a pinned
        // ("Keep offline") download — nothing safe to evict.
        preferences = InMemoryDownloadPreferences(maxCacheBytes: 4);
        final repository = CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
        );
        await repository.requestDownload(_jellyfin('keep'));
        await repository.setPinned(_jellyfin('keep'), true);
        final int fetchesBefore = downloader.fetchCount;

        // Best-effort: never throws, caches nothing, and skips the fetch
        // entirely rather than spend data on bytes it would discard.
        await repository.prefetch(_jellyfin('warm'));

        expect(downloader.fetchCount, fetchesBefore);
        expect(await repository.statusFor('keep'), DownloadStatus.downloaded);
        expect(
          (await store.loadDownloads()).map((c) => c.trackId),
          <String>['keep'],
        );
        expect((await repository.cacheSnapshot()).usedBytes, 4);
      });

      test('evicts an older pre-cache to stay under the limit', () async {
        // Room for one 4-byte entry; a second pre-cache forces the first out.
        preferences = InMemoryDownloadPreferences(maxCacheBytes: 4);
        final repository = CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
        );

        await repository.prefetch(_jellyfin('old'));
        await repository.prefetch(_jellyfin('new'));

        // The limit held: only the newest pre-cache remains, still invisible
        // as a download.
        expect((await repository.cacheSnapshot()).usedBytes, 4);
        final List<CachedTrack> saved = await store.loadDownloads();
        expect(saved.single.trackId, 'new');
        expect(saved.single.preloaded, isTrue);
        expect(await repository.downloadedTrackIds(), isEmpty);
      });

      test('a pre-cache never evicts the currently playing track', () async {
        // Room for one 4-byte track, held by the currently playing track.
        preferences = InMemoryDownloadPreferences(maxCacheBytes: 4);
        final repository = CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
          currentlyPlayingTrack: () => _jellyfin('now'),
        );
        await repository.prefetch(_jellyfin('now'));
        expect((await store.loadDownloads()).single.trackId, 'now');

        // The only cached entry is the playing track (protected), so a new
        // pre-cache is skipped — the playing track is never evicted.
        await repository.prefetch(_jellyfin('next'));

        expect(
          (await store.loadDownloads()).map((c) => c.trackId),
          <String>['now'],
        );
        expect((await repository.cacheSnapshot()).usedBytes, 4);
      });
    });

    group('manual cache controls', () {
      test('clear all removes every managed file and its metadata', () async {
        final spy = _SpyOfflineFileStore(files);
        final repository = CacheDownloadRepository(
          store: store,
          files: spy,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
        );
        await repository.requestDownload(_jellyfin('j1'));
        await repository.requestDownload(_jellyfin('j2'));
        await repository.setPinned(_jellyfin('j1'), true);

        await repository.clearAll();

        // Pinned items included: clear-all is the nuclear option.
        expect(await repository.downloadedTrackIds(), isEmpty);
        expect(await store.loadDownloads(), isEmpty);
        expect(spy.bytesFor('jellyfin_j1.mp3'), isNull);
        expect(spy.bytesFor('jellyfin_j2.mp3'), isNull);
      });

      test('clear unpinned preserves pinned tracks', () async {
        final repository = build();
        await repository.requestDownload(_jellyfin('keep'));
        await repository.requestDownload(_jellyfin('drop'));
        await repository.setPinned(_jellyfin('keep'), true);

        await repository.clearUnpinned();

        expect(await repository.statusFor('keep'), DownloadStatus.downloaded);
        expect(
            await repository.statusFor('drop'), DownloadStatus.notDownloaded);
        expect(files.bytesFor('jellyfin_keep.mp3'), isNotNull);
        expect(files.bytesFor('jellyfin_drop.mp3'), isNull);
      });

      test('clearing never deletes a local source file', () async {
        final spy = _SpyOfflineFileStore(files);
        final repository = CacheDownloadRepository(
          store: store,
          files: spy,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
        );
        await repository.requestDownload(_jellyfin('remote'));
        await repository.requestDownload(_local('song')); // local source file

        await repository.clearAll();

        // Only the app-managed remote file was ever handed to delete(); the
        // local track has no managed file, so its source is never touched.
        expect(spy.deleted, <String>['jellyfin_remote.mp3']);
        expect(spy.deleted.any((f) => f.contains('song')), isFalse);
      });

      test('cacheStream emits the current snapshot then changes', () async {
        final repository = build();
        final snapshots = <CacheSnapshot>[];
        final sub = repository.cacheStream.listen(snapshots.add);
        await _settle();

        expect(snapshots.first.usedBytes, 0);

        await repository.requestDownload(_jellyfin('j1'));
        await _settle();

        expect(snapshots.last.usedBytes, 4);
        await sub.cancel();
      });
    });

    group('cancel / clear races', () {
      test('cancelling a download mid-fetch never resurrects it', () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final spy = _SpyOfflineFileStore(files);
        final repository = CacheDownloadRepository(
          store: store,
          files: spy,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
        );

        final Future<void> request =
            repository.requestDownload(_jellyfin('j1'));
        // Wait until the bytes are actually being fetched, then cancel.
        await _pumpUntil(() => downloader.fetchCount >= 1);
        await repository.removeDownload(_jellyfin('j1'));
        // The in-flight fetch now completes — it must commit nothing.
        gate.complete();
        await request;

        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect(await repository.downloadedTrackIds(), isEmpty);
        expect(await store.loadDownloads(), isEmpty);
        final CacheSnapshot snapshot = await repository.cacheSnapshot();
        expect(snapshot.usedBytes, 0);
        expect(snapshot.entries, isEmpty);
        // The cancelled fetch wrote no managed file at all.
        expect(spy.bytesFor('jellyfin_j1.mp3'), isNull);
      });

      test('a cancelled download can be requested again and downloads',
          () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository = build();

        final Future<void> first = repository.requestDownload(_jellyfin('j1'));
        await _pumpUntil(() => downloader.fetchCount >= 1);
        await repository.removeDownload(_jellyfin('j1'));
        gate.complete();
        await first;
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);

        // A fresh, explicit request supersedes the prior cancellation.
        await repository.requestDownload(_jellyfin('j1'));
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      });

      test('clear all during an in-flight download leaves nothing behind',
          () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository = build();

        final Future<void> request =
            repository.requestDownload(_jellyfin('j1'));
        await _pumpUntil(() => downloader.fetchCount >= 1);
        await repository.clearAll();
        gate.complete();
        await request;

        expect(await repository.downloadedTrackIds(), isEmpty);
        expect(await store.loadDownloads(), isEmpty);
        expect((await repository.cacheSnapshot()).usedBytes, 0);
      });
    });

    group('preload concurrency', () {
      test('two concurrent prefetches of the same track fetch its bytes once',
          () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository = build();

        final Future<void> p1 = repository.prefetch(_jellyfin('j1'));
        final Future<void> p2 = repository.prefetch(_jellyfin('j1'));
        await _pumpUntil(() => downloader.fetchCount >= 1);
        gate.complete();
        await Future.wait(<Future<void>>[p1, p2]);

        // The reservation made the second prefetch bail before fetching, so the
        // bytes were pulled exactly once (not just de-duplicated at commit).
        expect(downloader.fetchCount, 1);
      });
    });
  });

  group('CacheDownloadRepository — Plex tracks (provider-aware caching)', () {
    late InMemoryDownloadStore store;
    late InMemoryOfflineFileStore files;
    late InMemoryDownloadPreferences preferences;
    late _FakeConnectivity connectivity;
    late _FakeRemoteDownloader plexDownloader;

    CacheDownloadRepository build({RemoteTrackDownloader? downloader}) =>
        CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader ?? plexDownloader,
          connectivity: connectivity,
          preferences: preferences,
        );

    setUp(() {
      store = InMemoryDownloadStore();
      files = InMemoryOfflineFileStore();
      preferences = InMemoryDownloadPreferences();
      connectivity = _FakeConnectivity(NetworkStatus.wifi);
      plexDownloader = _FakeRemoteDownloader(schemes: const <String>['plex:']);
    });

    Track plex(String id) => Track(id: id, title: id, uri: 'plex:$id');

    test('downloads a Plex track and tags the persisted entry as plex',
        () async {
      final repo = build();

      final outcome = await repo.requestDownload(plex('101'));

      expect(outcome, DownloadRequestOutcome.started);
      expect(await repo.statusFor('101'), DownloadStatus.downloaded);
      // Bytes are stored under the non-secret ratingKey id; no token anywhere.
      expect(files.bytesFor('plex_101.mp3'), _FakeRemoteDownloader.bytes);
      final saved = await store.loadDownloads();
      expect(saved, hasLength(1));
      expect(saved.single.trackId, '101');
      expect(saved.single.fileName, 'plex_101.mp3');
      // The source type marks it as Plex — how the cache stays provider-aware.
      expect(saved.single.sourceType, 'plex');
    });

    test('a cached Plex track survives a restart (metadata persists)',
        () async {
      await build().requestDownload(plex('101'));

      // A fresh repository over the same durable stores re-loads the download.
      final reborn = build();
      expect(await reborn.statusFor('101'), DownloadStatus.downloaded);
      final snapshot = await reborn.cacheSnapshot();
      expect(
        snapshot.entries.map((CachedTrack e) => e.trackId),
        contains('101'),
      );
    });

    test('removing a cached Plex track deletes its file and clears status',
        () async {
      final repo = build();
      await repo.requestDownload(plex('101'));
      expect(files.bytesFor('plex_101.mp3'), isNotNull);

      await repo.removeDownload(plex('101'));

      expect(await repo.statusFor('101'), DownloadStatus.notDownloaded);
      expect(files.bytesFor('plex_101.mp3'), isNull);
      expect(await store.loadDownloads(), isEmpty);
    });

    test('a failed Plex fetch marks it failed and caches nothing', () async {
      // A cache failure must not break streaming: the track is simply marked
      // failed (offering retry) and no file/metadata is written, so playback
      // streams normally when the track is reached.
      plexDownloader.error = StateError('Plex download failed.');
      final repo = build();

      await repo.requestDownload(plex('101'));

      expect(await repo.statusFor('101'), DownloadStatus.failed);
      expect(files.bytesFor('plex_101.mp3'), isNull);
      expect(await store.loadDownloads(), isEmpty);
    });

    test('Plex and Jellyfin copies cache independently — no cross-conflict',
        () async {
      // One downloader that claims both providers, so both tracks cache through
      // the same repository. They must persist as two distinct, correctly-tagged
      // entries — a Plex cache can never shadow or evict a Jellyfin one.
      final both = _FakeRemoteDownloader(
        schemes: const <String>['plex:', 'jellyfin:'],
      );
      final repo = build(downloader: both);

      await repo.requestDownload(plex('101'));
      await repo.requestDownload(_jellyfin('j1'));

      expect(await repo.statusFor('101'), DownloadStatus.downloaded);
      expect(await repo.statusFor('j1'), DownloadStatus.downloaded);
      final saved = await store.loadDownloads();
      final byId = <String, CachedTrack>{
        for (final CachedTrack c in saved) c.trackId: c,
      };
      expect(byId['101']!.sourceType, 'plex');
      expect(byId['j1']!.sourceType, 'jellyfin');
      expect(byId['101']!.fileName, 'plex_101.mp3');
      expect(byId['j1']!.fileName, 'jellyfin_j1.mp3');
      expect(files.bytesFor('plex_101.mp3'), isNotNull);
      expect(files.bytesFor('jellyfin_j1.mp3'), isNotNull);
    });

    test('Plex and Jellyfin tracks that share a catalog id never conflict',
        () async {
      // The hard case the catalog's id-uniqueness can't guarantee on its own:
      // two providers expose the SAME local id ("101"). The cache must keep them
      // fully independent — distinct files, distinct metadata, correct
      // resolution, and isolated removal — so a Plex cache can never shadow,
      // overwrite, or remove another provider's copy.
      final both = _FakeRemoteDownloader(
        schemes: const <String>['plex:', 'jellyfin:'],
      );
      final repo = build(downloader: both);
      final locator = StoreCachedTrackLocator(store, files);

      const Track plex101 = Track(id: '101', title: 'P', uri: 'plex:101');
      const Track jelly101 = Track(id: '101', title: 'J', uri: 'jellyfin:101');

      await repo.requestDownload(plex101);
      // The shared id must NOT make the second look already-downloaded.
      await repo.requestDownload(jelly101);

      // Both were actually fetched and cached.
      expect(
        both.fetched.map((Track t) => t.uri).toSet(),
        <String>{'plex:101', 'jellyfin:101'},
      );

      // Two distinct persisted entries, each tagged by its provider, written to
      // distinct, provider-namespaced files (the token-free id is namespaced).
      final saved = await store.loadDownloads();
      expect(saved, hasLength(2));
      final plexEntry =
          saved.firstWhere((CachedTrack c) => c.sourceType == 'plex');
      final jellyEntry =
          saved.firstWhere((CachedTrack c) => c.sourceType == 'jellyfin');
      expect(plexEntry.trackId, '101');
      expect(jellyEntry.trackId, '101');
      expect(plexEntry.fileName, 'plex_101.mp3');
      expect(jellyEntry.fileName, 'jellyfin_101.mp3');
      expect(plexEntry.fileName, isNot(jellyEntry.fileName));

      // Each resolves to its OWN cached file — no shadowing across providers.
      final plexPath = await locator.cachedFilePath(plex101);
      final jellyPath = await locator.cachedFilePath(jelly101);
      expect(plexPath, isNotNull);
      expect(jellyPath, isNotNull);
      expect(plexPath, isNot(jellyPath));

      // Removing the Plex copy leaves the Jellyfin copy fully intact.
      await repo.removeDownload(plex101);
      expect(await locator.cachedFilePath(plex101), isNull);
      expect(await locator.cachedFilePath(jelly101), jellyPath);
      final remaining = await store.loadDownloads();
      expect(remaining, hasLength(1));
      expect(remaining.single.sourceType, 'jellyfin');
      expect(files.bytesFor('plex_101.mp3'), isNull);
      expect(files.bytesFor('jellyfin_101.mp3'), isNotNull);
    });
  });

  // Smart cleanup is one shared, provider-agnostic policy: every offline-capable
  // remote provider (Plex, Jellyfin, Subsonic/Navidrome) caches through the same
  // repository and is evicted by the same LRU rules — keyed by the provider-aware
  // (sourceType, trackId) identity so same-id tracks never shadow or evict each
  // other. These tests drive one repository whose downloader claims all three.
  group('CacheDownloadRepository — provider-agnostic smart cleanup', () {
    late InMemoryDownloadStore store;
    late InMemoryOfflineFileStore files;
    late InMemoryDownloadPreferences preferences;
    late _FakeConnectivity connectivity;
    late _FakeRemoteDownloader downloader;

    // A clock that advances one minute per call, so least-recently-used ordering
    // is deterministic across providers.
    DateTime Function() incrementingClock() {
      int tick = 0;
      return () => DateTime(2024, 1, 1).add(Duration(minutes: tick++));
    }

    CacheDownloadRepository buildLimited({
      required int maxBytes,
      Track? Function()? currentlyPlaying,
      DateTime Function()? now,
    }) {
      preferences = InMemoryDownloadPreferences(maxCacheBytes: maxBytes);
      return CacheDownloadRepository(
        store: store,
        files: files,
        downloader: downloader,
        connectivity: connectivity,
        preferences: preferences,
        currentlyPlayingTrack: currentlyPlaying,
        now: now,
      );
    }

    setUp(() {
      store = InMemoryDownloadStore();
      files = InMemoryOfflineFileStore();
      connectivity = _FakeConnectivity(NetworkStatus.wifi);
      downloader = _FakeRemoteDownloader(
        schemes: const <String>['plex:', 'jellyfin:', 'subsonic:'],
      );
    });

    test('a Subsonic/Navidrome track is evicted like any other provider',
        () async {
      final repo = buildLimited(maxBytes: 10, now: incrementingClock());

      await repo.requestDownload(_subsonic('s1')); // oldest
      await repo.requestDownload(_subsonic('s2'));
      await repo.requestDownload(_subsonic('s3')); // forces eviction

      expect(await repo.statusFor('s1'), DownloadStatus.notDownloaded);
      expect(await repo.statusFor('s2'), DownloadStatus.downloaded);
      expect(await repo.statusFor('s3'), DownloadStatus.downloaded);
      expect(files.bytesFor('subsonic_s1.mp3'), isNull);
    });

    test('eviction ranks Plex, Jellyfin, and Subsonic together as one LRU list',
        () async {
      // Room for three 4-byte tracks; a fourth evicts the least-recently-used
      // across ALL providers (the plex track cached first).
      final repo = buildLimited(maxBytes: 12, now: incrementingClock());

      await repo.requestDownload(_plex('a')); // oldest, across providers
      await repo.requestDownload(_jellyfin('b'));
      await repo.requestDownload(_subsonic('c'));
      await repo.requestDownload(_jellyfin('d')); // forces one eviction

      expect(await repo.statusFor('a'), DownloadStatus.notDownloaded);
      expect(await repo.statusFor('b'), DownloadStatus.downloaded);
      expect(await repo.statusFor('c'), DownloadStatus.downloaded);
      expect(await repo.statusFor('d'), DownloadStatus.downloaded);
      expect(files.bytesFor('plex_a.mp3'), isNull);
    });

    test('a recently played cross-provider track is kept; a stale one evicted',
        () async {
      final repo = buildLimited(maxBytes: 12, now: incrementingClock());

      await repo.requestDownload(_plex('a')); // oldest
      await repo.requestDownload(_jellyfin('b'));
      await repo.requestDownload(_subsonic('c'));
      // Replaying the oldest (Plex 'a') makes the Jellyfin 'b' the LRU now.
      await repo.notePlayed(_plex('a'));
      await repo.requestDownload(_subsonic('d')); // forces one eviction

      expect(await repo.statusFor('a'), DownloadStatus.downloaded); // refreshed
      expect(await repo.statusFor('b'), DownloadStatus.notDownloaded); // stale
      expect(await repo.statusFor('c'), DownloadStatus.downloaded);
      expect(await repo.statusFor('d'), DownloadStatus.downloaded);
    });

    test('a download evicts a same-id track from another provider (no shadow)',
        () async {
      // The exact same-id collision: subsonic:101 is cached and is the only
      // evictable track; downloading plex:101 (same catalog id, different
      // provider) must EVICT it to fit — never treat it as the incoming track's
      // own old copy and silently overshoot the limit.
      final repo = buildLimited(maxBytes: 4, now: incrementingClock());

      await repo.requestDownload(_subsonic('101'));
      expect(await repo.statusFor('101'), DownloadStatus.downloaded);

      final outcome = await repo.requestDownload(_plex('101'));
      expect(outcome, DownloadRequestOutcome.started);

      // subsonic:101 gave way; plex:101 is the lone copy and the limit held.
      final saved = await store.loadDownloads();
      expect(saved, hasLength(1));
      expect(saved.single.sourceType, 'plex');
      expect(files.bytesFor('subsonic_101.mp3'), isNull);
      expect(files.bytesFor('plex_101.mp3'), isNotNull);
      expect((await repo.cacheSnapshot()).usedBytes, 4);
    });

    test('the playing track is protected per-provider, not by bare id',
        () async {
      // plex:101 is playing; a jellyfin:101 with the SAME id is a different
      // track and must stay evictable — only the playing provider's copy is safe.
      final repo = buildLimited(
        maxBytes: 8,
        currentlyPlaying: () => _plex('101'),
        now: incrementingClock(),
      );

      await repo.requestDownload(_plex('101')); // playing
      await repo.requestDownload(_jellyfin('101')); // same id, other provider
      await repo.requestDownload(_subsonic('x')); // full → forces one eviction

      final Set<String?> sources =
          (await store.loadDownloads()).map((c) => c.sourceType).toSet();
      expect(sources, containsAll(<String>['plex', 'subsonic']));
      // The same-id, non-playing Jellyfin copy was evicted, not the playing one.
      expect(sources, isNot(contains('jellyfin')));
      expect(files.bytesFor('plex_101.mp3'), isNotNull);
      expect(files.bytesFor('jellyfin_101.mp3'), isNull);
    });

    test('pre-cache continues after cleanup frees cross-provider space',
        () async {
      // A Jellyfin pre-cache fills the cache; a Plex pre-cache then evicts it
      // (pre-cached entries are sacrificed first) and caches itself — pre-cache
      // resumes after cleanup, and the limit holds.
      final repo = buildLimited(maxBytes: 4, now: incrementingClock());

      await repo.prefetch(_jellyfin('old'));
      expect((await store.loadDownloads()).single.trackId, 'old');

      await repo.prefetch(_plex('new'));

      final saved = await store.loadDownloads();
      expect(saved, hasLength(1));
      expect(saved.single.sourceType, 'plex');
      expect(saved.single.trackId, 'new');
      expect(saved.single.preloaded, isTrue);
      expect((await repo.cacheSnapshot()).usedBytes, 4);
    });

    test('pre-cache is skipped safely when cleanup cannot free enough',
        () async {
      // The cache is full of a pinned download (never evictable). A pre-cache
      // must skip rather than break — no fetch, no throw, nothing cached.
      final repo = buildLimited(maxBytes: 4, now: incrementingClock());
      await repo.requestDownload(_jellyfin('pinned'));
      await repo.setPinned(_jellyfin('pinned'), true);

      await repo.prefetch(_plex('want')); // no room, nothing safe to evict

      final saved = await store.loadDownloads();
      expect(saved, hasLength(1));
      expect(saved.single.trackId, 'pinned');
      expect(
          downloader.fetched.any((Track t) => t.uri == 'plex:want'), isFalse);
      expect((await repo.cacheSnapshot()).usedBytes, 4);
    });
  });
}

/// Lets the broadcast stream deliver any pending events.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// Pumps event-loop turns until [condition] holds (or a bounded number elapse),
/// so concurrency assertions don't depend on exact async scheduling.
Future<void> _pumpUntil(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
