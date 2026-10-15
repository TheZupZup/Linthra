// dispose() while a download is still fetching doesn't throw.
//
// dispose() closes the status, cache and progress streams, but a fetch
// already out still finishes afterwards and reported through them, so
// "Cannot add new events after calling close" escaped requestDownload. Only
// reachable at shutdown.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
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

class _HeldDownloader implements RemoteTrackDownloader {
  final Completer<void> gate = Completer<void>();
  int fetchCount = 0;

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    fetchCount++;
    await gate.future;
    return const RemoteTrackData(bytes: <int>[1, 2, 3, 4]);
  }
}

Future<void> _pumpUntil(bool Function() condition) async {
  for (int i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('a download that finishes after dispose does not throw', () async {
    final _HeldDownloader downloader = _HeldDownloader();
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: InMemoryDownloadStore(),
      files: InMemoryOfflineFileStore(),
      downloader: downloader,
      connectivity: _Wifi(),
      preferences: InMemoryDownloadPreferences(),
    );

    final Future<DownloadRequestOutcome> request =
        repository.requestDownload(const Track(
      id: 'j1',
      title: 'j1',
      uri: 'jellyfin:j1',
    ));
    await _pumpUntil(() => downloader.fetchCount >= 1);
    await repository.dispose();
    downloader.gate.complete();

    await expectLater(request, completes);
  });

  test('a download that fails after dispose does not throw either', () async {
    final _HeldDownloader downloader = _HeldDownloader();
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: InMemoryDownloadStore(),
      files: InMemoryOfflineFileStore(),
      downloader: downloader,
      connectivity: _Wifi(),
      preferences: InMemoryDownloadPreferences(),
    );

    final Future<DownloadRequestOutcome> request =
        repository.requestDownload(const Track(
      id: 'j1',
      title: 'j1',
      uri: 'jellyfin:j1',
    ));
    await _pumpUntil(() => downloader.fetchCount >= 1);
    await repository.dispose();
    downloader.gate.completeError(StateError('the connection dropped'));

    await expectLater(request, completes);
  });
}
