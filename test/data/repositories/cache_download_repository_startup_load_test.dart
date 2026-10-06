import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/repositories/offline_file_store.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/offline_cache_manager.dart';
import 'package:linthra/core/services/offline_copy_origins.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/data/repositories/cache_download_repository.dart';
import 'package:linthra/data/repositories/file_system_offline_file_store.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/data/repositories/in_memory_download_store.dart';
import 'package:linthra/data/repositories/in_memory_offline_file_store.dart';

import '../../support/offline_file_writes.dart';

/// A connectivity stand-in whose reported status the test can flip at will.
class _FakeConnectivity implements ConnectivityService {
  _FakeConnectivity(this.status);

  NetworkStatus status;

  @override
  Stream<NetworkStatus> get statusStream => const Stream<NetworkStatus>.empty();

  @override
  Future<NetworkStatus> currentStatus() async => status;
}

/// One fetch held until the test settles it.
class _HeldFetch {
  _HeldFetch(this.track);

  final Track track;
  final Completer<void> gate = Completer<void>();
}

/// A remote downloader whose every fetch waits on its own [_HeldFetch], in
/// call order, and records which network the fetch started on.
class _HeldDownloader implements RemoteTrackDownloader {
  _HeldDownloader(this._connectivity);

  final _FakeConnectivity _connectivity;
  final List<_HeldFetch> calls = <_HeldFetch>[];

  /// The network each fetch started on, by track id.
  final Map<String, NetworkStatus> startedOn = <String, NetworkStatus>{};

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    startedOn[track.id] = _connectivity.status;
    final _HeldFetch held = _HeldFetch(track);
    calls.add(held);
    await held.gate.future;
    onProgress?.call(4, 4);
    return const RemoteTrackData(
        bytes: <int>[1, 2, 3, 4], fileExtension: 'mp3');
  }
}

/// Wraps an in-memory file store and parks the [sizeFor] calls whose index
/// (0-based, in call order) is in [parked] until the test releases them: the
/// one await per record inside the repository's startup load.
class _GatedSizeFileStore implements OfflineFileStore {
  _GatedSizeFileStore(this._inner, {Set<int> parked = const <int>{}})
      : _parked = parked;

  final InMemoryOfflineFileStore _inner;
  final Set<int> _parked;
  int _sizeCalls = 0;
  final Map<int, Completer<void>> gates = <int, Completer<void>>{};

  @override
  Future<OfflineFileDraft> createDraft(String trackId) =>
      _inner.createDraft(trackId);

  @override
  Future<String?> pathFor(String fileName) => _inner.pathFor(fileName);

  @override
  Future<int?> sizeFor(String fileName) async {
    final int call = _sizeCalls++;
    if (_parked.contains(call)) {
      final Completer<void> gate = gates[call] = Completer<void>();
      await gate.future;
    }
    return _inner.sizeFor(fileName);
  }

  @override
  Future<void> delete(String fileName) => _inner.delete(fileName);

  @override
  Future<void> removeAbandoned(
    Set<String> referenced, {
    bool temporaryOnly = false,
  }) =>
      _inner.removeAbandoned(referenced, temporaryOnly: temporaryOnly);
}

/// Plex copies bound to their server, with [_server] connected now.
class _PlexOn implements OfflineCopyOrigins {
  _PlexOn(this._server);

  final String _server;

  @override
  bool binds(String scheme) => scheme == 'plex';

  @override
  String? current(String scheme) => scheme == 'plex' ? _server : null;

  @override
  Stream<void> get changes => const Stream<void>.empty();
}

Track _jellyfin(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');

Future<void> _pumpUntil(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('the startup load', () {
    // The repository loads its durable records once, on first use, and many
    // callers ask at once at launch (each row's status, the cache card, the
    // media browser, smart pre-cache). Each of them has to wait for that one
    // load. If a later caller ran a load of its own, it would put the records
    // back as they were on disk over whatever changed once the first load
    // finished. The file store here makes any second load's file check slower
    // than the first's, so the first finishes while a second would still be
    // reading.
    late InMemoryOfflineFileStore inner;
    late InMemoryDownloadStore store;
    late _GatedSizeFileStore files;
    late _FakeConnectivity connectivity;
    late InMemoryDownloadPreferences preferences;

    setUp(() async {
      // Last session pre-cached p ahead of play.
      inner = InMemoryOfflineFileStore();
      final String fileName =
          await inner.write('jellyfin_p', <int>[1, 2, 3, 4], extension: 'mp3');
      store = InMemoryDownloadStore(
        initialDownloads: <CachedTrack>[
          CachedTrack(
            trackId: 'p',
            fileName: fileName,
            sourceType: 'jellyfin',
            sizeBytes: 4,
            cachedAt: DateTime(2026),
            preloaded: true,
          ),
        ],
      );
      files = _GatedSizeFileStore(inner, parked: <int>{1});
      connectivity = _FakeConnectivity(NetworkStatus.wifi);
      preferences = InMemoryDownloadPreferences();
    });

    /// Launches the repository with two early readers, lets the first load
    /// finish, has the listener download the pre-cached song p (promoted in
    /// place), then lets the second load finish.
    Future<CacheDownloadRepository> downloadDuringSecondLoad(
        _HeldDownloader downloader) async {
      final CacheDownloadRepository repository = CacheDownloadRepository(
        store: store,
        files: files,
        downloader: downloader,
        connectivity: connectivity,
        preferences: preferences,
      );
      final Future<CacheSnapshot> first = repository.cacheSnapshot();
      final Future<List<String>> second = repository.downloadedTrackKeys();
      await first;

      await repository.requestDownload(_jellyfin('p'));
      expect(await repository.statusFor('p'), DownloadStatus.downloaded);

      // Whatever is still reading the disk finishes now.
      for (final Completer<void> gate in files.gates.values) {
        if (!gate.isCompleted) gate.complete();
      }
      await second;
      return repository;
    }

    test('a song downloaded meanwhile is still downloaded after a restart',
        () async {
      final CacheDownloadRepository repository =
          await downloadDuringSecondLoad(_HeldDownloader(connectivity));

      // Any later metadata write (here: the song is played from the cache)
      // saves what the repository holds in memory.
      await repository.notePlayed(_jellyfin('p'));

      final CacheDownloadRepository restarted = CacheDownloadRepository(
        store: store,
        files: inner,
        downloader: _HeldDownloader(connectivity),
        connectivity: connectivity,
        preferences: preferences,
      );
      expect(await restarted.statusFor('p'), DownloadStatus.downloaded);
    });

    test('smart pre-cache never evicts a song downloaded meanwhile', () async {
      final _HeldDownloader downloader = _HeldDownloader(connectivity);
      final CacheDownloadRepository repository =
          await downloadDuringSecondLoad(downloader);

      // The cache holds exactly p. A pre-cache of the next song may only make
      // room from other pre-caches, never from a download.
      await preferences.setMaxCacheBytes(4);
      final Future<void> warm = repository.prefetch(_jellyfin('q'));
      await _pumpUntil(() => downloader.calls.isNotEmpty);
      for (final _HeldFetch call in downloader.calls) {
        if (!call.gate.isCompleted) call.gate.complete();
      }
      await warm;

      expect(await repository.statusFor('p'), DownloadStatus.downloaded);
      expect(inner.bytesFor('jellyfin_p.mp3'), isNotNull);
    });

    test('a song taken off "Keep offline" meanwhile does not come back',
        () async {
      const Track kept =
          Track(id: '/music/k.mp3', title: 'k', uri: '/music/k.mp3');
      // Kept offline last session too.
      final CacheDownloadRepository earlier = CacheDownloadRepository(
        store: store,
        files: inner,
        downloader: _HeldDownloader(connectivity),
        connectivity: connectivity,
        preferences: preferences,
      );
      await earlier.requestDownload(kept);
      await earlier.dispose();

      final CacheDownloadRepository repository = CacheDownloadRepository(
        store: store,
        files: files,
        downloader: _HeldDownloader(connectivity),
        connectivity: connectivity,
        preferences: preferences,
      );
      final Future<CacheSnapshot> first = repository.cacheSnapshot();
      final Future<List<String>> second = repository.downloadedTrackKeys();
      await first;

      await repository.removeDownload(kept);
      for (final Completer<void> gate in files.gates.values) {
        if (!gate.isCompleted) gate.complete();
      }
      await second;

      expect(await repository.statusFor(kept.id), DownloadStatus.notDownloaded);
      // Nor after a restart, once something else is saved.
      await repository.notePlayed(_jellyfin('p'));
      final CacheDownloadRepository restarted = CacheDownloadRepository(
        store: store,
        files: inner,
        downloader: _HeldDownloader(connectivity),
        connectivity: connectivity,
        preferences: preferences,
      );
      expect(await restarted.statusFor(kept.id), DownloadStatus.notDownloaded);
    });
  });

  // #747: a download cut off mid-commit leaves its `.part` temp, or a finished
  // file whose record was never saved. The load only checked that each record's
  // file exists, never that each file has a record, so these were never
  // counted, evicted or cleared.
  group('files no record names (#747)', () {
    late Directory dir;
    final DateTime lastSession = DateTime.now().subtract(
      const Duration(hours: 1),
    );

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('linthra_offline_sweep');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
    });

    /// A file the last session left in the offline directory.
    Future<File> leftover(String name, {int bytes = 4}) async {
      final File file = File('${dir.path}/$name');
      await file.writeAsBytes(List<int>.filled(bytes, 7));
      await file.setLastModified(lastSession);
      return file;
    }

    CachedTrack record(String id, String fileName) => CachedTrack(
          trackId: id,
          fileName: fileName,
          sourceType: 'jellyfin',
          sizeBytes: 4,
          cachedAt: DateTime(2026),
        );

    CacheDownloadRepository launch(
      InMemoryDownloadStore store,
      FileSystemOfflineFileStore files, {
      OfflineCopyOrigins? origins,
    }) {
      final _FakeConnectivity connectivity =
          _FakeConnectivity(NetworkStatus.wifi);
      return CacheDownloadRepository(
        store: store,
        files: files,
        downloader: _HeldDownloader(connectivity),
        connectivity: connectivity,
        preferences: InMemoryDownloadPreferences(),
        origins: origins,
      );
    }

    Future<Set<String>> namesOnDisk() async => <String>{
          await for (final FileSystemEntity entity in dir.list())
            entity.uri.pathSegments.last,
        };

    test('the first load leaves only the files a record names', () async {
      await leftover('kept.flac');
      await leftover('also-kept.mp3');
      await leftover('cut-off.flac.part', bytes: 2);
      await leftover('never-recorded.flac', bytes: 9);
      final InMemoryDownloadStore store = InMemoryDownloadStore(
        initialDownloads: <CachedTrack>[
          record('k', 'kept.flac'),
          // A pre-cached copy is a cache file too.
          record('a', 'also-kept.mp3').copyWith(preloaded: true),
        ],
      );
      final CacheDownloadRepository repository = launch(
        store,
        FileSystemOfflineFileStore(directory: () async => dir),
      );

      final CacheSnapshot snapshot = await repository.cacheSnapshot();

      expect(await namesOnDisk(), <String>{'kept.flac', 'also-kept.mp3'});
      expect(snapshot.usedBytes, 8,
          reason: 'what is left is exactly what is counted');
      expect(await repository.statusFor('k'), DownloadStatus.downloaded);
    });

    test("another server's copies, set aside while away, are kept", () async {
      await leftover('home.flac');
      final CacheDownloadRepository repository = launch(
        InMemoryDownloadStore(
          initialDownloads: <CachedTrack>[
            const CachedTrack(
              trackId: '7',
              fileName: 'home.flac',
              sourceType: 'plex',
              origin: 'machine-home',
              sizeBytes: 4,
            ),
          ],
        ),
        FileSystemOfflineFileStore(directory: () async => dir),
        origins: _PlexOn('machine-friend'),
      );

      await repository.cacheSnapshot();

      expect(await namesOnDisk(), <String>{'home.flac'});
    });

    test('nothing this run writes is ever taken', () async {
      await leftover('kept.flac');
      final FileSystemOfflineFileStore files =
          FileSystemOfflineFileStore(directory: () async => dir);
      // Written after the store was made, as this run's own writes are.
      await File('${dir.path}/in-flight.flac.part').writeAsBytes(<int>[1]);
      await File('${dir.path}/just-moved.flac').writeAsBytes(<int>[1]);
      final CacheDownloadRepository repository = launch(
        InMemoryDownloadStore(
          initialDownloads: <CachedTrack>[record('k', 'kept.flac')],
        ),
        files,
      );

      await repository.cacheSnapshot();

      expect(await namesOnDisk(),
          <String>{'kept.flac', 'in-flight.flac.part', 'just-moved.flac'});
    });

    test('a repository built again later never sweeps the shared store',
        () async {
      await leftover('kept.flac');
      final FileSystemOfflineFileStore files =
          FileSystemOfflineFileStore(directory: () async => dir);
      final InMemoryDownloadStore store = InMemoryDownloadStore(
        initialDownloads: <CachedTrack>[record('k', 'kept.flac')],
      );
      await launch(store, files).cacheSnapshot();

      // The first repository's download is mid-commit: renamed into place,
      // its record not saved yet. Even dated as old, a second repository's
      // load leaves it alone.
      await leftover('mid-commit.flac');
      await launch(store, files).cacheSnapshot();

      expect(await namesOnDisk(), <String>{'kept.flac', 'mid-commit.flac'});
    });

    test('records that read as none leave finished files alone', () async {
      // An unreadable record document reads as no downloads. Taking every
      // file then would be the one thing worse than the leftovers.
      await leftover('maybe-a-download.flac');
      await leftover('cut-off.flac.part');
      final CacheDownloadRepository repository = launch(
        InMemoryDownloadStore(),
        FileSystemOfflineFileStore(directory: () async => dir),
      );

      await repository.cacheSnapshot();

      expect(await namesOnDisk(), <String>{'maybe-a-download.flac'});
    });
  });
}
