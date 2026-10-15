// "Clear cache" stops an unpinned download still on its way, and keeps the
// pinned ones.
//
// Clear cache (clear unpinned) frees everything except songs set to "Keep
// offline". A download still fetching has no copy yet, so it can't be
// pinned: it goes with the clear like any unpinned song, rather than landing
// a moment later and filling the space just freed. The tests for an in-flight
// download cover Clear all only, where nothing is kept, so they can't tell a
// clear that cancels too much from one that cancels too little.
import 'dart:async';

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

class _Wifi implements ConnectivityService {
  @override
  Stream<NetworkStatus> get statusStream => const Stream<NetworkStatus>.empty();

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
}

/// Returns canned bytes for `jellyfin:` tracks, holding each fetch on [gate]
/// while one is set.
class _GatedDownloader implements RemoteTrackDownloader {
  Completer<void>? gate;
  int fetchCount = 0;

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    fetchCount++;
    final Completer<void>? pending = gate;
    if (pending != null) await pending.future;
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

void main() {
  test('clear unpinned drops a download in flight and keeps a pinned one',
      () async {
    final InMemoryDownloadStore store = InMemoryDownloadStore();
    final InMemoryOfflineFileStore files = InMemoryOfflineFileStore();
    final _GatedDownloader downloader = _GatedDownloader();
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: store,
      files: files,
      downloader: downloader,
      connectivity: _Wifi(),
      preferences: InMemoryDownloadPreferences(),
    );
    addTearDown(repository.dispose);

    await repository.requestDownload(_jellyfin('j0'));
    await repository.setPinned(_jellyfin('j0'), true);

    downloader.gate = Completer<void>();
    final Future<DownloadRequestOutcome> request =
        repository.requestDownload(_jellyfin('j1'));
    await _pumpUntil(() => downloader.fetchCount >= 2);
    expect(await repository.statusFor('j1'), DownloadStatus.downloading);

    await repository.clearUnpinned();
    // The row reads cleared at once, not only when its fetch ends.
    expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);

    downloader.gate!.complete();
    await request;
    await _pumpUntil(() => false);

    // The fetch that was out commits nothing.
    expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
    expect(files.bytesFor('jellyfin_j1.mp3'), isNull);
    // The pinned song is untouched.
    expect(await repository.statusFor('j0'), DownloadStatus.downloaded);
    expect(files.bytesFor('jellyfin_j0.mp3'), <int>[1, 2, 3, 4]);
    final List<CachedTrack> saved = await store.loadDownloads();
    expect(saved.map((CachedTrack c) => c.trackId), <String>['j0']);
    expect(saved.single.pinned, isTrue);
    expect((await repository.cacheSnapshot()).usedBytes, 4);
    expect(await repository.downloadedTrackKeys(),
        <String>[CachedTrack.cacheKeyForTrack(_jellyfin('j0'))]);
  });
}
