// A cache file that is no longer all there is not served or counted.
//
// The file store refuses to publish an empty or short download, since the
// playback locator only checked that a file exists. A file already on disk in
// that state (cut short or emptied after it was saved) was never checked
// again: the startup load dropped a record only when its file was gone, and
// the locator served whatever it found. Both now hold the file to the size
// its record says was saved.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/data/repositories/cache_download_repository.dart';
import 'package:linthra/data/repositories/file_system_offline_file_store.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/data/repositories/in_memory_download_store.dart';
import 'package:linthra/data/repositories/store_cached_track_locator.dart';

class _Wifi implements ConnectivityService {
  @override
  Stream<NetworkStatus> get statusStream => const Stream<NetworkStatus>.empty();

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
}

class _NoFetch implements RemoteTrackDownloader {
  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) =>
      throw StateError('nothing is fetched here');
}

const Track _a1 = Track(id: 'a1', title: 'A1', uri: 'jellyfin:a1');

void main() {
  late Directory dir;
  late InMemoryDownloadStore records;
  late FileSystemOfflineFileStore files;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('linthra_incomplete_cache_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    // The record says four bytes were published.
    records = InMemoryDownloadStore(
      initialDownloads: <CachedTrack>[
        CachedTrack(
          trackId: 'a1',
          fileName: 'a1.mp3',
          sourceType: 'jellyfin',
          sizeBytes: 4,
          cachedAt: DateTime(2026),
        ),
      ],
    );
    files = FileSystemOfflineFileStore(directory: () async => dir);
  });

  CacheDownloadRepository launch() {
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: records,
      files: files,
      downloader: _NoFetch(),
      connectivity: _Wifi(),
      preferences: InMemoryDownloadPreferences(),
    );
    addTearDown(repository.dispose);
    return repository;
  }

  for (final ({String name, List<int> bytes}) damaged
      in <({String name, List<int> bytes})>[
    (name: 'an empty', bytes: const <int>[]),
    (name: 'a truncated', bytes: const <int>[1, 2]),
  ]) {
    group('${damaged.name} cache file on disk', () {
      setUp(() async {
        await File('${dir.path}/a1.mp3').writeAsBytes(damaged.bytes);
      });

      test('is not served for playback', () async {
        final String? path =
            await StoreCachedTrackLocator(records, files).cachedFilePath(_a1);

        expect(path, isNull, reason: 'served ${damaged.bytes.length} bytes');
      });

      test('is not reported downloaded once the cache loads', () async {
        final CacheDownloadRepository repository = launch();

        expect(await repository.statusFor('a1'), DownloadStatus.notDownloaded);
      });
    });
  }

  test('a whole cache file is still served and downloaded', () async {
    await File('${dir.path}/a1.mp3').writeAsBytes(const <int>[1, 2, 3, 4]);

    expect(
      await StoreCachedTrackLocator(records, files).cachedFilePath(_a1),
      '${dir.path}/a1.mp3',
    );
    expect(await launch().statusFor('a1'), DownloadStatus.downloaded);
  });

  test('a record saved without its size still serves a non-empty file',
      () async {
    // Records from before sizes were kept carry 0; the load backfills them.
    records = InMemoryDownloadStore(
      initialDownloads: const <CachedTrack>[
        CachedTrack(trackId: 'a1', fileName: 'a1.mp3', sourceType: 'jellyfin'),
      ],
    );
    await File('${dir.path}/a1.mp3').writeAsBytes(const <int>[1, 2]);

    expect(
      await StoreCachedTrackLocator(records, files).cachedFilePath(_a1),
      '${dir.path}/a1.mp3',
    );
    expect(await launch().statusFor('a1'), DownloadStatus.downloaded);
  });
}
