// A download whose record can't be saved (#786).
//
// On a full disk the preferences write fails, and before this a download
// still showed as downloaded for the rest of the session; the next launch then
// removed its file as one no record names (#747). Staged with the real file
// store over a temp folder, so a "next launch" runs the real sweep, and a
// record store whose saves fail while [_FullDiskStore.full] is set.
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

class _Wifi implements ConnectivityService {
  @override
  Stream<NetworkStatus> get statusStream => const Stream<NetworkStatus>.empty();

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
}

class _InstantDownloader implements RemoteTrackDownloader {
  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async =>
      const RemoteTrackData(bytes: <int>[1, 2, 3, 4], fileExtension: 'mp3');
}

/// The download records, on a disk that can fill up: while [full], every save
/// fails the way the preferences store's does, and leaves the last saved set.
class _FullDiskStore implements DownloadStore {
  _FullDiskStore([List<CachedTrack> initial = const <CachedTrack>[]])
      : _inner = InMemoryDownloadStore(initialDownloads: initial);

  final InMemoryDownloadStore _inner;
  bool full = false;

  @override
  Future<List<CachedTrack>> loadDownloads() => _inner.loadDownloads();

  @override
  Future<void> saveDownloads(List<CachedTrack> downloads) async {
    if (full) throw const DownloadStoreWriteException();
    await _inner.saveDownloads(downloads);
  }
}

const Track _track = Track(
  id: 't1',
  title: 'Nightcall',
  uri: 'jellyfin:t1',
);

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('linthra_full_disk_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
  });

  CacheDownloadRepository launch(DownloadStore store) =>
      CacheDownloadRepository(
        store: store,
        files: FileSystemOfflineFileStore(directory: () async => dir),
        downloader: _InstantDownloader(),
        connectivity: _Wifi(),
        preferences: InMemoryDownloadPreferences(),
      );

  Future<List<String>> filesOnDisk() async => <String>[
        await for (final FileSystemEntity entity in dir.list())
          entity.uri.pathSegments.last,
      ];

  test(
      'a download whose record cannot be saved fails now, rather than '
      'vanishing at the next launch', () async {
    final _FullDiskStore store = _FullDiskStore();
    final CacheDownloadRepository repository = launch(store);
    await repository.cacheSnapshot();
    store.full = true;

    await expectLater(
      repository.requestDownload(_track),
      throwsA(
        isA<CacheStorageException>().having(
          (CacheStorageException error) => error.message,
          'message',
          contains('out of storage space'),
        ),
      ),
    );
    expect(await repository.statusFor(_track.id), DownloadStatus.notDownloaded);
    expect(await filesOnDisk(), isEmpty);
    expect((await repository.cacheSnapshot()).usedBytes, 0);

    // The next launch agrees with what this one said.
    store.full = false;
    final CacheDownloadRepository relaunched = launch(store);
    expect(await relaunched.statusFor(_track.id), DownloadStatus.notDownloaded);
  });

  test('a pre-cache whose record cannot be saved is dropped quietly', () async {
    final _FullDiskStore store = _FullDiskStore();
    final CacheDownloadRepository repository = launch(store);
    await repository.cacheSnapshot();
    store.full = true;

    await repository.prefetch(_track);

    expect(await filesOnDisk(), isEmpty);
    expect((await repository.cacheSnapshot()).usedBytes, 0);
  });

  test(
      'downloading a pre-cached song whose record cannot be saved leaves it '
      'a pre-cache', () async {
    final _FullDiskStore store = _FullDiskStore();
    final CacheDownloadRepository repository = launch(store);
    await repository.prefetch(_track);
    expect((await repository.cacheSnapshot()).usedBytes, 4);
    store.full = true;

    await expectLater(
      repository.requestDownload(_track),
      throwsA(isA<CacheStorageException>()),
    );
    expect(await repository.statusFor(_track.id), DownloadStatus.notDownloaded);
    expect((await repository.cacheSnapshot()).usedBytes, 4,
        reason: 'still cached, as the pre-cache it was');

    store.full = false;
    final CacheDownloadRepository relaunched = launch(store);
    expect(await relaunched.statusFor(_track.id), DownloadStatus.notDownloaded);
    expect((await relaunched.cacheSnapshot()).usedBytes, 4);
  });

  test('a full disk still lets the cache be read', () async {
    // A record written by an earlier version, with no size: the first load
    // fills it in from the file and saves the healed set, which fails here.
    await File('${dir.path}/kept.mp3').writeAsBytes(<int>[1, 2, 3, 4]);
    final _FullDiskStore store = _FullDiskStore(<CachedTrack>[
      const CachedTrack(
        trackId: 't1',
        fileName: 'kept.mp3',
        sourceType: 'jellyfin',
      ),
    ])
      ..full = true;

    final CacheDownloadRepository repository = launch(store);

    expect(await repository.statusFor('t1'), DownloadStatus.downloaded);
    expect((await repository.cacheSnapshot()).usedBytes, 4);
    expect(await filesOnDisk(), <String>['kept.mp3']);
  });
}
