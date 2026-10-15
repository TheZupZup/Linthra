// A download that fails to publish after making room persists its evictions.
//
// A download that has to make room evicts older copies (their files deleted,
// their records dropped in memory) and then publishes its own file. When that
// publish failed (the disk full at the flush), the commit threw straight out
// without saving: the evicted copies' records stayed persisted, naming files
// that no longer exist, until something else saved. Every other early exit
// after an eviction already saved first.
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
  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async =>
      const RemoteTrackData(bytes: <int>[1, 2, 3, 4], fileExtension: 'mp3');
}

/// An open file whose flush fails, the way it does once the disk is full.
class _FailingFlush implements RandomAccessFile {
  _FailingFlush(this._inner);

  final RandomAccessFile _inner;

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    await _inner.writeFrom(buffer, start, end);
    return this;
  }

  @override
  Future<RandomAccessFile> flush() async =>
      throw const FileSystemException('No space left on device');

  @override
  Future<void> close() => _inner.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('the evicted copy has no record left once the publish fails', () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('linthra_publish_after_evict_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final File oldFile = File('${dir.path}/old.mp3')
      ..writeAsBytesSync(const <int>[9, 9, 9, 9]);
    final InMemoryDownloadStore records = InMemoryDownloadStore(
      initialDownloads: <CachedTrack>[
        CachedTrack(
          trackId: 'old',
          fileName: 'old.mp3',
          sourceType: 'jellyfin',
          sizeBytes: 4,
          cachedAt: DateTime(2026),
          lastAccessedAt: DateTime(2026),
        ),
      ],
    );
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: records,
      files: FileSystemOfflineFileStore(
        directory: () async => dir,
        openDraft: (File temp) async =>
            _FailingFlush(await temp.open(mode: FileMode.writeOnly)),
      ),
      downloader: _InstantDownloader(),
      connectivity: _Wifi(),
      // Room for one 4-byte copy, so the new one evicts the old.
      preferences: InMemoryDownloadPreferences(maxCacheBytes: 6),
    );
    addTearDown(repository.dispose);

    await repository.requestDownload(
      const Track(id: 'new', title: 'New', uri: 'jellyfin:new'),
    );

    expect(await repository.statusFor('new'), DownloadStatus.failed);
    expect(oldFile.existsSync(), isFalse, reason: 'old.mp3 was not evicted');
    expect(await repository.statusFor('old'), DownloadStatus.notDownloaded);
    // What is persisted matches what is on disk.
    expect(
      (await records.loadDownloads()).map((CachedTrack c) => c.trackId),
      isNot(contains('old')),
      reason: 'the record of evicted old.mp3 is still saved',
    );
  });
}
