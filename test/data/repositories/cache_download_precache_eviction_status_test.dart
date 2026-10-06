// Evicting a pre-cached copy must not touch the row of the listener's own
// download of that song.
//
// A download that failed keeps its row ("Failed", with Retry) until the
// listener retries or removes it. Smart pre-cache may warm the same song
// meanwhile (it is in the queue), and later evict that pre-cached copy to make
// room for the next one. The eviction forgot the copy's record and with it
// whatever status the song had, so the failed download vanished from the
// Downloads screen on its own: "A track's download status changes only in
// response to requestDownload / removeDownload (or an explicit clear / pin)".
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

/// Serves 4 bytes per song, or fails while [failing] is set.
class _FlakyDownloader implements RemoteTrackDownloader {
  bool failing = false;

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    if (failing) throw StateError('Jellyfin download failed.');
    return const RemoteTrackData(
        bytes: <int>[1, 2, 3, 4], fileExtension: 'mp3');
  }
}

Track _jellyfin(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');

void main() {
  test(
      'evicting a pre-cached copy leaves the failed download of that song '
      'where the listener left it', () async {
    final _FlakyDownloader downloader = _FlakyDownloader();
    final InMemoryOfflineFileStore files = InMemoryOfflineFileStore();
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: InMemoryDownloadStore(),
      files: files,
      downloader: downloader,
      connectivity: _Wifi(),
      // Room for one song.
      preferences: InMemoryDownloadPreferences(maxCacheBytes: 4),
    );

    // The listener's download of a fails (the server dropped the transfer).
    downloader.failing = true;
    await repository.requestDownload(_jellyfin('a'));
    expect(await repository.statusFor('a'), DownloadStatus.failed);

    // Smart pre-cache warms a (next in the queue) once the server is back...
    downloader.failing = false;
    await repository.prefetch(_jellyfin('a'));
    expect(files.bytesFor('jellyfin_a.mp3'), isNotNull);
    expect(await repository.statusFor('a'), DownloadStatus.failed);

    // ...and later makes room for the song after it by evicting that copy.
    await repository.prefetch(_jellyfin('b'));
    expect(files.bytesFor('jellyfin_a.mp3'), isNull);
    expect(files.bytesFor('jellyfin_b.mp3'), isNotNull);

    // Nothing the listener did: the failed download still offers Retry.
    expect(await repository.statusFor('a'), DownloadStatus.failed);
  });
}
