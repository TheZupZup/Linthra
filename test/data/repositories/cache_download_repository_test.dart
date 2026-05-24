import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/repositories/offline_file_store.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/offline_cache_manager.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/data/repositories/cache_download_repository.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/data/repositories/in_memory_download_store.dart';
import 'package:linthra/data/repositories/in_memory_offline_file_store.dart';

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
class _FakeRemoteDownloader implements RemoteTrackDownloader {
  _FakeRemoteDownloader({this.error});

  /// The canned bytes every successful fetch returns.
  static const List<int> bytes = <int>[1, 2, 3, 4];

  /// When set, [fetch] throws this instead of returning bytes.
  final Object? error;

  int fetchCount = 0;
  final List<Track> fetched = <Track>[];

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(Track track) async {
    fetchCount++;
    fetched.add(track);
    final Object? err = error;
    if (err != null) throw err;
    return const RemoteTrackData(bytes: bytes, fileExtension: 'mp3');
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

      await repository.removeDownload('j1');

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

        await repository.removeDownload('a');

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

    group('Wi-Fi only policy (remote downloads)', () {
      test('queues instead of downloading when on mobile', () async {
        await preferences.setWifiOnly(true);
        connectivity.status = NetworkStatus.mobile;
        final repository = build();

        await repository.requestDownload(_jellyfin('j1'));

        expect(await repository.statusFor('j1'), DownloadStatus.queued);
        expect(downloader.fetchCount, 0);
        expect(await store.loadDownloads(), isEmpty);
      });

      test('downloads when on Wi-Fi', () async {
        await preferences.setWifiOnly(true);
        connectivity.status = NetworkStatus.wifi;
        final repository = build();

        await repository.requestDownload(_jellyfin('j1'));

        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      });

      test('downloads over mobile when the preference is off', () async {
        await preferences.setWifiOnly(false);
        connectivity.status = NetworkStatus.mobile;
        final repository = build();

        await repository.requestDownload(_jellyfin('j1'));

        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      });

      test('a local track is never queued, even off Wi-Fi', () async {
        await preferences.setWifiOnly(true);
        connectivity.status = NetworkStatus.mobile;
        final repository = build();

        await repository.requestDownload(_local('a'));

        // Already local: the Wi-Fi gate doesn't apply (no bytes to fetch).
        expect(await repository.statusFor('a'), DownloadStatus.downloaded);
      });

      test('a queued track downloads on an explicit retry once on Wi-Fi',
          () async {
        await preferences.setWifiOnly(true);
        connectivity.status = NetworkStatus.mobile;
        final repository = build();
        await repository.requestDownload(_jellyfin('j1'));
        expect(await repository.statusFor('j1'), DownloadStatus.queued);

        connectivity.status = NetworkStatus.wifi;
        await repository.requestDownload(_jellyfin('j1'));

        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
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
        String? Function()? currentlyPlaying,
        DateTime Function()? now,
      }) {
        preferences = InMemoryDownloadPreferences(maxCacheBytes: maxBytes);
        return CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
          currentlyPlayingTrackId: currentlyPlaying,
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
        expect(files.bytesFor('j1.mp3'), isNull);
      });

      test('playing a track refreshes it so a stale one is evicted instead',
          () async {
        final repository = buildLimited(maxBytes: 10, now: incrementingClock());

        await repository.requestDownload(_jellyfin('j1'));
        await repository.requestDownload(_jellyfin('j2'));
        // j1 was just played, so j2 is now the least-recently-used.
        await repository.notePlayed('j1');
        await repository.requestDownload(_jellyfin('j3'));

        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
        expect(await repository.statusFor('j2'), DownloadStatus.notDownloaded);
        expect(await repository.statusFor('j3'), DownloadStatus.downloaded);
      });

      test('pinned tracks are never evicted automatically', () async {
        final repository = buildLimited(maxBytes: 10, now: incrementingClock());

        await repository.requestDownload(_jellyfin('j1')); // oldest
        await repository.setPinned('j1', true);
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
          currentlyPlaying: () => 'j1',
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
        await repository.setPinned('j1', true);

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
        expect(files.bytesFor('j1.mp3'), isNotNull);
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
        await repository.setPinned('j1', true);

        await repository.clearAll();

        // Pinned items included: clear-all is the nuclear option.
        expect(await repository.downloadedTrackIds(), isEmpty);
        expect(await store.loadDownloads(), isEmpty);
        expect(spy.bytesFor('j1.mp3'), isNull);
        expect(spy.bytesFor('j2.mp3'), isNull);
      });

      test('clear unpinned preserves pinned tracks', () async {
        final repository = build();
        await repository.requestDownload(_jellyfin('keep'));
        await repository.requestDownload(_jellyfin('drop'));
        await repository.setPinned('keep', true);

        await repository.clearUnpinned();

        expect(await repository.statusFor('keep'), DownloadStatus.downloaded);
        expect(
            await repository.statusFor('drop'), DownloadStatus.notDownloaded);
        expect(files.bytesFor('keep.mp3'), isNotNull);
        expect(files.bytesFor('drop.mp3'), isNull);
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
        expect(spy.deleted, <String>['remote.mp3']);
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
  });
}

/// Lets the broadcast stream deliver any pending events.
Future<void> _settle() => Future<void>.delayed(Duration.zero);
