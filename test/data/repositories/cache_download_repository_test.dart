import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/services/connectivity_service.dart';
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
  });
}

/// Lets the broadcast stream deliver any pending events.
Future<void> _settle() => Future<void>.delayed(Duration.zero);
