// A body that ends before its announced length is not saved as a download.
//
// The repository read the body to its end and never compared the bytes
// received with the size the server announced, so a transfer cut off on the
// way that still ended cleanly was published, recorded and served as the
// offline copy. dart:io already raises an error for such a body over HTTP;
// this keeps the repository from relying on every source doing that.
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

/// Announces 8 bytes and sends 4, then ends the body cleanly.
class _ShortBodyDownloader implements RemoteTrackDownloader {
  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final StreamController<List<int>> body = StreamController<List<int>>();
    body.add(const <int>[1, 2, 3, 4]);
    unawaited(body.close());
    return RemoteTrackData.streamed(
      body: body.stream,
      length: 8,
      fileExtension: 'mp3',
    );
  }
}

/// Announces [announced] bytes and sends 4, then ends the body cleanly.
class _Downloader implements RemoteTrackDownloader {
  _Downloader(this.announced);

  final int? announced;

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async =>
      RemoteTrackData.streamed(
        body: Stream<List<int>>.value(const <int>[1, 2, 3, 4]),
        length: announced,
        fileExtension: 'mp3',
      );
}

void main() {
  late InMemoryDownloadStore store;
  late InMemoryOfflineFileStore files;

  CacheDownloadRepository repositoryWith(RemoteTrackDownloader downloader) {
    store = InMemoryDownloadStore();
    files = InMemoryOfflineFileStore();
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: store,
      files: files,
      downloader: downloader,
      connectivity: _Wifi(),
      preferences: InMemoryDownloadPreferences(),
    );
    addTearDown(repository.dispose);
    return repository;
  }

  test('a body shorter than its announced length is not kept', () async {
    final CacheDownloadRepository repository =
        repositoryWith(_ShortBodyDownloader());

    await repository.requestDownload(
      const Track(id: 'j1', title: 'j1', uri: 'jellyfin:j1'),
    );

    final List<CachedTrack> saved = await store.loadDownloads();
    expect(
      saved.map((CachedTrack c) => '${c.trackId}: ${c.sizeBytes} bytes'),
      isEmpty,
    );
    expect(files.bytesFor('jellyfin_j1.mp3'), isNull);
    expect(await repository.statusFor('j1'), DownloadStatus.failed);
  });

  for (final int? announced in <int?>[4, null]) {
    test('a body that matches its length (${announced ?? 'none'}) is kept',
        () async {
      final CacheDownloadRepository repository =
          repositoryWith(_Downloader(announced));

      await repository.requestDownload(
        const Track(id: 'j1', title: 'j1', uri: 'jellyfin:j1'),
      );

      expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      expect(files.bytesFor('jellyfin_j1.mp3'), <int>[1, 2, 3, 4]);
    });
  }
}
