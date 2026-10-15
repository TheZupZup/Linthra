// The same track asked for twice in one turn gets one answer.
//
// The first request reserves the in-flight slot and then awaits the network
// policy. The second saw that reservation and returned `started` at once, so
// its caller stayed quiet though the download was held for Wi-Fi, and the
// first caller was told so. It now answers with the first one's decision.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/data/repositories/cache_download_repository.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/data/repositories/in_memory_download_store.dart';
import 'package:linthra/data/repositories/in_memory_offline_file_store.dart';

class _Mobile implements ConnectivityService {
  @override
  Stream<NetworkStatus> get statusStream => const Stream<NetworkStatus>.empty();

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.mobile;
}

class _Wifi implements ConnectivityService {
  @override
  Stream<NetworkStatus> get statusStream => const Stream<NetworkStatus>.empty();

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
}

class _Downloader implements RemoteTrackDownloader {
  int fetchCount = 0;

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    fetchCount++;
    return const RemoteTrackData(bytes: <int>[1, 2, 3, 4]);
  }
}

void main() {
  test('both requests for a held track say it waits for Wi-Fi', () async {
    final _Downloader downloader = _Downloader();
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: InMemoryDownloadStore(),
      files: InMemoryOfflineFileStore(),
      downloader: downloader,
      connectivity: _Mobile(),
      preferences: InMemoryDownloadPreferences(),
    );
    addTearDown(repository.dispose);
    const Track track = Track(id: 'j1', title: 'j1', uri: 'jellyfin:j1');

    final Future<DownloadRequestOutcome> first =
        repository.requestDownload(track);
    final Future<DownloadRequestOutcome> second =
        repository.requestDownload(track);

    expect(await first, DownloadRequestOutcome.waitingForWifi);
    expect(await second, DownloadRequestOutcome.waitingForWifi);
    expect(await repository.statusFor('j1'), DownloadStatus.queued);
    expect(downloader.fetchCount, 0);
  });

  test('both requests for an allowed track say it started, and fetch once',
      () async {
    final _Downloader downloader = _Downloader();
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: InMemoryDownloadStore(),
      files: InMemoryOfflineFileStore(),
      downloader: downloader,
      connectivity: _Wifi(),
      preferences: InMemoryDownloadPreferences(),
    );
    addTearDown(repository.dispose);
    const Track track = Track(id: 'j1', title: 'j1', uri: 'jellyfin:j1');

    final Future<DownloadRequestOutcome> first =
        repository.requestDownload(track);
    final Future<DownloadRequestOutcome> second =
        repository.requestDownload(track);

    expect(await second, DownloadRequestOutcome.started);
    expect(await first, DownloadRequestOutcome.started);
    expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
    expect(downloader.fetchCount, 1);
  });
}
