// A "Keep offline" pin that lands while a download is making room.
//
// A download's commit works out what to evict once, then deletes the victims
// one at a time. A song the listener pins while an earlier victim is being
// deleted is still on that list, and was deleted anyway, right after the pin
// was saved and shown: "Pinned tracks are never evicted automatically".
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

class _Wifi implements ConnectivityService {
  @override
  Stream<NetworkStatus> get statusStream => const Stream<NetworkStatus>.empty();

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
}

/// Serves each track with as many bytes as [sizes] says (4 by default).
class _SizedDownloader implements RemoteTrackDownloader {
  _SizedDownloader(this.sizes);

  final Map<String, int> sizes;

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async =>
      RemoteTrackData(
        bytes: List<int>.filled(sizes[track.id] ?? 4, 7),
        fileExtension: 'mp3',
      );
}

/// Holds the delete of one chosen file until the test lets it go, the way a
/// delete on the disk takes a moment during which other work runs.
class _HeldDeleteFileStore implements OfflineFileStore {
  _HeldDeleteFileStore(this._inner);

  final InMemoryOfflineFileStore _inner;
  String? holdFile;
  final Completer<void> reached = Completer<void>();
  final Completer<void> release = Completer<void>();

  List<int>? bytesFor(String fileName) => _inner.bytesFor(fileName);

  @override
  Future<OfflineFileDraft> createDraft(String trackId) =>
      _inner.createDraft(trackId);

  @override
  Future<String?> pathFor(String fileName) => _inner.pathFor(fileName);

  @override
  Future<int?> sizeFor(String fileName) => _inner.sizeFor(fileName);

  @override
  Future<void> delete(String fileName) async {
    if (fileName == holdFile && !reached.isCompleted) {
      reached.complete();
      await release.future;
    }
    await _inner.delete(fileName);
  }

  @override
  Future<void> removeAbandoned(
    Set<String> referenced, {
    bool temporaryOnly = false,
  }) =>
      _inner.removeAbandoned(referenced, temporaryOnly: temporaryOnly);
}

Track _jellyfin(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');

void main() {
  test(
      'a song pinned while a download is evicting songs before it on the '
      'list is never deleted once the pin is shown', () async {
    DateTime clock = DateTime(2026);
    final _HeldDeleteFileStore files =
        _HeldDeleteFileStore(InMemoryOfflineFileStore());
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: InMemoryDownloadStore(),
      files: files,
      // a and b are 4 bytes each, c is 8: c only fits once both are gone.
      downloader: _SizedDownloader(<String, int>{'c': 8}),
      connectivity: _Wifi(),
      preferences: InMemoryDownloadPreferences(maxCacheBytes: 8),
      now: () => clock = clock.add(const Duration(minutes: 1)),
    );
    final List<CacheSnapshot> shown = <CacheSnapshot>[];
    final StreamSubscription<CacheSnapshot> sub =
        repository.cacheStream.listen(shown.add);

    await repository.requestDownload(_jellyfin('a'));
    await repository.requestDownload(_jellyfin('b'));
    expect(files.bytesFor('jellyfin_a.mp3'), isNotNull);
    expect(files.bytesFor('jellyfin_b.mp3'), isNotNull);

    // c makes room by evicting a, then b (least recently used first). a's
    // file is being deleted...
    files.holdFile = 'jellyfin_a.mp3';
    final Future<DownloadRequestOutcome> c =
        repository.requestDownload(_jellyfin('c'));
    await files.reached.future;
    // ...when the listener taps "Keep offline" on b.
    final Future<void> pinning = repository.setPinned(_jellyfin('b'), true);
    for (int i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    files.release.complete();
    await pinning;
    try {
      await c;
    } on CacheStorageException {
      // c may be refused: once b is kept, there is no room for it.
    }
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    final bool pinShown = shown.any((CacheSnapshot snapshot) => snapshot.entries
        .any((CachedTrack entry) => entry.trackId == 'b' && entry.pinned));
    final bool bOnDisk = files.bytesFor('jellyfin_b.mp3') != null;
    // Once b reads as kept offline, it stays: its file and its row.
    expect(
      (pinShown: pinShown, bOnDisk: bOnDisk),
      anyOf(
        (pinShown: true, bOnDisk: true),
        (pinShown: false, bOnDisk: false),
      ),
      reason: 'b status: ${await repository.statusFor('b')}, '
          'c status: ${await repository.statusFor('c')}',
    );
    if (pinShown) {
      expect(await repository.statusFor('b'), DownloadStatus.downloaded);
    }
  });

  test(
      'a song that starts playing while a download is evicting songs before '
      'it on the list keeps its file', () async {
    DateTime clock = DateTime(2026);
    Track? playing;
    final _HeldDeleteFileStore files =
        _HeldDeleteFileStore(InMemoryOfflineFileStore());
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: InMemoryDownloadStore(),
      files: files,
      downloader: _SizedDownloader(<String, int>{'c': 8}),
      connectivity: _Wifi(),
      preferences: InMemoryDownloadPreferences(maxCacheBytes: 8),
      currentlyPlayingTrack: () => playing,
      now: () => clock = clock.add(const Duration(minutes: 1)),
    );
    await repository.requestDownload(_jellyfin('a'));
    await repository.requestDownload(_jellyfin('b'));

    // c makes room by evicting a, then b. a's file is being deleted when the
    // listener starts playing b, from its offline copy.
    files.holdFile = 'jellyfin_a.mp3';
    final Future<DownloadRequestOutcome> c =
        repository.requestDownload(_jellyfin('c'));
    await files.reached.future;
    playing = _jellyfin('b');
    files.release.complete();
    try {
      await c;
    } on CacheStorageException {
      // c may be refused: with b playing, there is no room for it.
    }

    // "The currently playing track is never evicted."
    expect(
      files.bytesFor('jellyfin_b.mp3'),
      isNotNull,
      reason: 'b status: ${await repository.statusFor('b')}, '
          'c status: ${await repository.statusFor('c')}',
    );
    expect(await repository.statusFor('b'), DownloadStatus.downloaded);
  });

  test(
      'room still missing once a song on the list is kept comes from the '
      'next song that may go', () async {
    DateTime clock = DateTime(2026);
    final _HeldDeleteFileStore files =
        _HeldDeleteFileStore(InMemoryOfflineFileStore());
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: InMemoryDownloadStore(),
      files: files,
      downloader: _SizedDownloader(<String, int>{'c': 8}),
      connectivity: _Wifi(),
      preferences: InMemoryDownloadPreferences(maxCacheBytes: 12),
      now: () => clock = clock.add(const Duration(minutes: 1)),
    );
    for (final String id in <String>['a', 'b', 'd']) {
      await repository.requestDownload(_jellyfin(id));
    }

    // c evicts a, then b. b is pinned while a is being deleted, so d goes
    // instead.
    files.holdFile = 'jellyfin_a.mp3';
    final Future<DownloadRequestOutcome> c =
        repository.requestDownload(_jellyfin('c'));
    await files.reached.future;
    final Future<void> pinning = repository.setPinned(_jellyfin('b'), true);
    for (int i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    files.release.complete();
    await pinning;
    await c;

    expect(
      (
        a: await repository.statusFor('a'),
        b: await repository.statusFor('b'),
        c: await repository.statusFor('c'),
        d: await repository.statusFor('d'),
        used: (await repository.cacheSnapshot()).usedBytes,
      ),
      (
        a: DownloadStatus.notDownloaded,
        b: DownloadStatus.downloaded,
        c: DownloadStatus.downloaded,
        d: DownloadStatus.notDownloaded,
        used: 12,
      ),
    );
    expect(files.bytesFor('jellyfin_b.mp3'), isNotNull);
  });
}
