// A download whose record can't be saved (#786).
//
// On a full disk the preferences write fails, and before this a download
// still showed as downloaded for the rest of the session; the next launch then
// removed its file as one no record names (#747). Staged with the real file
// store over a temp folder, so a "next launch" runs the real sweep, and a
// record store whose saves fail while [_FullDiskStore.full] is set.
import 'dart:async';
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
  int fetches = 0;

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    fetches++;
    return const RemoteTrackData(
        bytes: <int>[1, 2, 3, 4], fileExtension: 'mp3');
  }
}

/// Holds the first read of the cache limit made once [holdWhen] says so, until
/// [release], so a test can land something else in the middle of the step
/// that reads it.
class _HeldLimitPreferences extends InMemoryDownloadPreferences {
  _HeldLimitPreferences({required this.holdWhen});

  final bool Function() holdWhen;
  final Completer<void> _reached = Completer<void>();
  final Completer<void> _released = Completer<void>();

  /// Completes once a read is being held.
  Future<void> get reached => _reached.future;

  void release() => _released.complete();

  @override
  Future<int> maxCacheBytes() async {
    if (!_reached.isCompleted && holdWhen()) {
      _reached.complete();
      await _released.future;
    }
    return super.maxCacheBytes();
  }
}

/// The download records, on a disk that can fill up: while [full], every save
/// fails the way the preferences store's does, and leaves the last saved set.
class _FullDiskStore implements DownloadStore {
  _FullDiskStore([List<CachedTrack> initial = const <CachedTrack>[]])
      : _inner = InMemoryDownloadStore(initialDownloads: initial);

  final InMemoryDownloadStore _inner;
  bool full = false;

  /// Fails only the saves it matches, for a disk that fills up at one exact
  /// write.
  bool Function(List<CachedTrack> downloads)? failWhen;

  @override
  Future<List<CachedTrack>> loadDownloads() => _inner.loadDownloads();

  @override
  Future<void> saveDownloads(List<CachedTrack> downloads) async {
    if (full || (failWhen?.call(downloads) ?? false)) {
      throw const DownloadStoreWriteException();
    }
    await _inner.saveDownloads(downloads);
  }
}

const Track _track = Track(
  id: 't1',
  title: 'Nightcall',
  uri: 'jellyfin:t1',
);

/// A song on this device: kept offline by its record alone, with no file of
/// the cache's own for a launch to check it against.
const Track _onDevice = Track(
  id: '/music/a.mp3',
  title: 'Midnight City',
  uri: '/music/a.mp3',
);

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('linthra_full_disk_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
  });

  CacheDownloadRepository launch(
    DownloadStore store, {
    RemoteTrackDownloader? downloader,
    InMemoryDownloadPreferences? preferences,
  }) =>
      CacheDownloadRepository(
        store: store,
        files: FileSystemOfflineFileStore(directory: () async => dir),
        downloader: downloader ?? _InstantDownloader(),
        connectivity: _Wifi(),
        preferences: preferences ?? InMemoryDownloadPreferences(),
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

  group('a change the user asked for that cannot be saved is not kept', () {
    test('keeping an on-device song offline fails now', () async {
      final _FullDiskStore store = _FullDiskStore();
      final CacheDownloadRepository repository = launch(store);
      await repository.cacheSnapshot();
      store.full = true;

      await expectLater(
        repository.requestDownload(_onDevice),
        throwsA(isA<CacheStorageException>()),
      );
      expect(await repository.statusFor(_onDevice.id),
          DownloadStatus.notDownloaded);

      store.full = false;
      expect(await launch(store).statusFor(_onDevice.id),
          DownloadStatus.notDownloaded);
    });

    test(
        "an on-device song's removal stays undone, as the next launch would "
        'find it', () async {
      final _FullDiskStore store = _FullDiskStore();
      final CacheDownloadRepository repository = launch(store);
      await repository.requestDownload(_onDevice);
      store.full = true;

      await repository.removeDownload(_onDevice);

      expect(
          await repository.statusFor(_onDevice.id), DownloadStatus.downloaded);
      store.full = false;
      expect(await launch(store).statusFor(_onDevice.id),
          DownloadStatus.downloaded);
    });

    test('a pin does not stick', () async {
      final _FullDiskStore store = _FullDiskStore();
      final CacheDownloadRepository repository = launch(store);
      await repository.requestDownload(_track);
      store.full = true;

      await repository.setPinned(_track, true);

      expect((await repository.cacheSnapshot()).entries.single.pinned, isFalse);
      store.full = false;
      expect(
          (await launch(store).cacheSnapshot()).entries.single.pinned, isFalse);
    });

    test(
        'Clear all still frees the files, and keeps the on-device songs it '
        'could not forget', () async {
      final _FullDiskStore store = _FullDiskStore();
      final CacheDownloadRepository repository = launch(store);
      await repository.requestDownload(_track);
      await repository.requestDownload(_onDevice);
      store.full = true;

      await repository.clearAll();

      expect(await filesOnDisk(), isEmpty);
      expect(
          await repository.statusFor(_track.id), DownloadStatus.notDownloaded);
      expect(
          await repository.statusFor(_onDevice.id), DownloadStatus.downloaded);

      store.full = false;
      final CacheDownloadRepository relaunched = launch(store);
      expect(
          await relaunched.statusFor(_track.id), DownloadStatus.notDownloaded);
      expect(
          await relaunched.statusFor(_onDevice.id), DownloadStatus.downloaded);
    });
  });

  test(
      'a download racing a pre-cache of the same song keeps that pre-cache '
      'when its own record cannot be saved', () async {
    // Only the download's record fails to save: the pre-cache's goes through.
    final _FullDiskStore store = _FullDiskStore()
      ..failWhen = (List<CachedTrack> records) => records.any(
          (CachedTrack record) =>
              record.trackId == _track.id && !record.preloaded);
    final _InstantDownloader downloader = _InstantDownloader();
    // The pre-cache reads the limit in its commit, once it has the bytes.
    final _HeldLimitPreferences preferences =
        _HeldLimitPreferences(holdWhen: () => downloader.fetches == 1);
    final CacheDownloadRepository repository =
        launch(store, downloader: downloader, preferences: preferences);
    await repository.cacheSnapshot();

    // The pre-cache is inside its commit, past its check for a download of
    // the same song, when the user asks for that download: both fetch, and
    // both write the same file.
    final Future<void> warming = repository.prefetch(_track);
    await preferences.reached;
    final Future<DownloadRequestOutcome> asking =
        repository.requestDownload(_track);
    for (int i = 0; i < 100 && downloader.fetches < 2; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(downloader.fetches, 2);
    preferences.release();
    await warming;

    await expectLater(asking, throwsA(isA<CacheStorageException>()));
    expect((await repository.cacheSnapshot()).entries.single.preloaded, isTrue);
    expect((await repository.cacheSnapshot()).usedBytes, 4);
    expect(await filesOnDisk(), hasLength(1),
        reason: 'the file the saved pre-cache record names was deleted');

    final CacheDownloadRepository relaunched = launch(store);
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
