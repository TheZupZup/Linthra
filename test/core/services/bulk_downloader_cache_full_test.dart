// "Download all" on a collection bigger than the cache limit.
//
// Each song in a batch must not evict the batch's own earlier songs to make
// room. Otherwise the whole collection is fetched, only about one limit's
// worth stays on disk, and the batch never reports that it ran out of space.
// The batch protects its own songs, so it fills the cache, hits real
// refusals, and stops with "not enough space" before asking for the rest.
//
// Runs against the real CacheDownloadRepository, since the fake one used by
// the other batch tests does not evict anything.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/bulk_download_summary.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/services/bulk_downloader.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/data/repositories/cache_download_repository.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/data/repositories/in_memory_download_store.dart';
import 'package:linthra/data/repositories/in_memory_offline_file_store.dart';

class _Wifi implements ConnectivityService {
  @override
  Stream<NetworkStatus> get statusStream => const Stream<NetworkStatus>.empty();

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
}

/// Serves every track as ten bytes, and records which ones were fetched.
class _TenBytes implements RemoteTrackDownloader {
  final List<String> fetched = <String>[];

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    fetched.add(track.id);
    return RemoteTrackData(
      bytes: List<int>.filled(10, 7),
      fileExtension: 'mp3',
    );
  }
}

Track _song(String id) =>
    Track(id: id, title: 'Song $id', uri: 'jellyfin:$id', albumName: 'Album');

void main() {
  late _TenBytes downloader;
  late CacheDownloadRepository repository;

  setUp(() {
    downloader = _TenBytes();
    repository = CacheDownloadRepository(
      store: InMemoryDownloadStore(),
      files: InMemoryOfflineFileStore(),
      downloader: downloader,
      connectivity: _Wifi(),
      // Room for four songs.
      preferences: InMemoryDownloadPreferences(maxCacheBytes: 40),
    );
  });

  tearDown(() => repository.dispose());

  Future<Set<String>> offlineIds() async => <String>{
        for (final String key in await repository.downloadedTrackKeys())
          key.split('\u0000').last,
      };

  test('a batch keeps its own songs and stops once the cache is full',
      () async {
    final List<Track> album = <Track>[
      for (int i = 1; i <= 10; i++) _song('$i'),
    ];

    final BulkDownloadSummary summary =
        await const BulkDownloader(maxOutstanding: 1).run(
      repository: repository,
      label: 'Album',
      tracks: album,
    );

    // The first four fill the cache and stay there.
    expect(await offlineIds(), <String>{'1', '2', '3', '4'});
    expect(summary.downloaded, 4);
    // The next three are refused in a row, which ends the batch...
    expect(summary.cacheRefused, BulkDownloader.maxConsecutiveCacheRefusals);
    expect(summary.outOfSpace, isTrue);
    // ...so the last three are never asked for.
    expect(downloader.fetched, <String>['1', '2', '3', '4', '5', '6', '7']);
    expect(summary.evictedExisting, 0);
  });

  test('an older download still makes room for the batch', () async {
    await repository.requestDownload(_song('old'));
    expect(await offlineIds(), <String>{'old'});

    final BulkDownloadSummary summary =
        await const BulkDownloader(maxOutstanding: 1).run(
      repository: repository,
      label: 'Album',
      tracks: <Track>[for (int i = 1; i <= 4; i++) _song('$i')],
    );

    // Not part of the batch, so it is evicted like before, and the summary
    // says so.
    expect(await offlineIds(), <String>{'1', '2', '3', '4'});
    expect(summary.downloaded, 4);
    expect(summary.evictedExisting, 1);
    expect(summary.outOfSpace, isFalse);
  });

  test('the cache key separator is what the test reads ids by', () {
    expect(CachedTrack.cacheKeyForTrack(_song('1')).split('\u0000').last, '1');
  });
}
