import 'dart:async';

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
  Future<String> write(String trackId, List<int> bytes, {String? extension}) =>
      _inner.write(trackId, bytes, extension: extension);

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
}
