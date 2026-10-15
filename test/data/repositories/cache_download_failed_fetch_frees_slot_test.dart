// One download failing frees its slot and leaves the others alone.
//
// The repository's slot tests cover a download that is cancelled while
// queued, and a failure with nothing queued behind it. A failed fetch with
// downloads waiting is the common one ("Download all" on an album while the
// server drops one request): the failed track must read failed with nothing
// of it kept, the next in line must start in its place, and the downloads
// fetching beside it must commit as if nothing happened.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/download_progress.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/download_scheduler.dart';
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

/// One fetch held by [_PerCallDownloader] until the test settles it.
class _HeldFetch {
  _HeldFetch(this.track);

  final Track track;
  final Completer<void> _gate = Completer<void>();
  Object? _error;

  void complete() => _gate.complete();

  void fail(Object error) {
    _error = error;
    _gate.complete();
  }
}

/// A remote downloader whose every fetch waits on its own [_HeldFetch], in
/// call order, so a test decides which fetch fails and when.
class _PerCallDownloader implements RemoteTrackDownloader {
  final List<_HeldFetch> calls = <_HeldFetch>[];

  List<String> get fetched => <String>[
        for (final _HeldFetch call in calls) call.track.id,
      ];

  _HeldFetch callFor(String id) =>
      calls.singleWhere((_HeldFetch call) => call.track.id == id);

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final _HeldFetch held = _HeldFetch(track);
    calls.add(held);
    // Partway in, so a progress ring is showing when the fetch fails.
    onProgress?.call(2, 4);
    await held._gate.future;
    final Object? error = held._error;
    if (error != null) throw error;
    onProgress?.call(4, 4);
    return const RemoteTrackData(
        bytes: <int>[1, 2, 3, 4], fileExtension: 'mp3');
  }
}

Track _jellyfin(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');

Future<void> _pumpUntil(bool Function() condition) async {
  for (int i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _settle() => _pumpUntil(() => false);

void main() {
  late InMemoryDownloadStore store;
  late InMemoryOfflineFileStore files;
  late _PerCallDownloader downloader;

  setUp(() {
    store = InMemoryDownloadStore();
    files = InMemoryOfflineFileStore();
    downloader = _PerCallDownloader();
  });

  CacheDownloadRepository build({required int maxConcurrent}) {
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: store,
      files: files,
      downloader: downloader,
      connectivity: _Wifi(),
      preferences: InMemoryDownloadPreferences(),
      scheduler: DownloadScheduler(maxConcurrent: maxConcurrent),
    );
    addTearDown(repository.dispose);
    return repository;
  }

  Future<List<String>> savedIds() async => <String>[
        for (final CachedTrack c in await store.loadDownloads()) c.trackId,
      ];

  test('a failed fetch hands its one slot to the download queued behind it',
      () async {
    final CacheDownloadRepository repository = build(maxConcurrent: 1);
    final List<Map<String, DownloadProgress>> progress =
        <Map<String, DownloadProgress>>[];
    final StreamSubscription<Map<String, DownloadProgress>> sub =
        repository.progressStream.listen(progress.add);
    addTearDown(sub.cancel);
    final String aKey = CachedTrack.cacheKeyForTrack(_jellyfin('a'));

    final List<Future<DownloadRequestOutcome>> requests =
        <Future<DownloadRequestOutcome>>[
      repository.requestDownload(_jellyfin('a')),
      repository.requestDownload(_jellyfin('b')),
    ];
    await _pumpUntil(() => downloader.calls.isNotEmpty);
    await _settle();
    expect(downloader.fetched, <String>['a']);
    expect(await repository.statusFor('b'), DownloadStatus.queued);
    expect(progress.last.containsKey(aKey), isTrue);

    downloader.callFor('a').fail(StateError('Jellyfin download failed.'));
    await _pumpUntil(() => downloader.calls.length >= 2);

    // b started in the slot a gave up, without waiting for anything else.
    expect(downloader.fetched, <String>['a', 'b']);
    expect(await repository.statusFor('a'), DownloadStatus.failed);
    expect(await repository.statusFor('b'), DownloadStatus.downloading);
    // a's progress ring went with it.
    expect(progress.last.containsKey(aKey), isFalse);

    downloader.callFor('b').complete();
    final List<DownloadRequestOutcome> outcomes = await Future.wait(requests);
    await _settle();

    // A failed download still reports the request as accepted: its row says
    // failed and offers a retry.
    expect(outcomes, <DownloadRequestOutcome>[
      DownloadRequestOutcome.started,
      DownloadRequestOutcome.started,
    ]);
    expect(await repository.statusFor('a'), DownloadStatus.failed);
    expect(await repository.statusFor('b'), DownloadStatus.downloaded);
    expect(files.bytesFor('jellyfin_a.mp3'), isNull);
    expect(files.bytesFor('jellyfin_b.mp3'), <int>[1, 2, 3, 4]);
    expect(await savedIds(), <String>['b']);
    expect(progress.last, isEmpty);
  });

  test('a failure among parallel downloads leaves the others to commit',
      () async {
    final CacheDownloadRepository repository = build(maxConcurrent: 3);

    final List<Future<DownloadRequestOutcome>> requests =
        <Future<DownloadRequestOutcome>>[
      for (final String id in <String>['a', 'b', 'c'])
        repository.requestDownload(_jellyfin(id)),
    ];
    await _pumpUntil(() => downloader.calls.length >= 3);
    expect(downloader.fetched, <String>['a', 'b', 'c']);

    // The one in the middle fails while the other two are still fetching.
    downloader.callFor('b').fail(StateError('Jellyfin download failed.'));
    await _settle();
    expect(await repository.statusFor('b'), DownloadStatus.failed);
    expect(await repository.statusFor('a'), DownloadStatus.downloading);
    expect(await repository.statusFor('c'), DownloadStatus.downloading);

    downloader.callFor('c').complete();
    downloader.callFor('a').complete();
    await Future.wait(requests);

    expect(await repository.statusFor('a'), DownloadStatus.downloaded);
    expect(await repository.statusFor('b'), DownloadStatus.failed);
    expect(await repository.statusFor('c'), DownloadStatus.downloaded);
    expect(files.bytesFor('jellyfin_b.mp3'), isNull);
    expect(await savedIds(), unorderedEquals(<String>['a', 'c']));
    // Nothing was fetched twice to make up for the failure.
    expect(downloader.fetched, <String>['a', 'b', 'c']);
  });
}
