// A removal whose file can't be deleted (permission denied, a read-only
// filesystem).
//
// The removal forgot the copy before it tried to delete the file, and threw
// when the delete failed. The song still read Downloaded and its file stayed
// on disk, but the cache no longer counted or listed it (no size, no pin, its
// bytes outside the limit), and asking to remove it again then "succeeded"
// without deleting anything: the file stayed on disk with no record naming it.
import 'dart:async';
import 'dart:io';

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

class _Downloader implements RemoteTrackDownloader {
  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async =>
      const RemoteTrackData(bytes: <int>[1, 2, 3, 4], fileExtension: 'mp3');
}

/// A file store whose deletes fail while [deniedDeletes] is set (or for the
/// files in [denied]), the way they do in a directory the app may no longer
/// write to.
class _DenyingFileStore implements OfflineFileStore {
  final InMemoryOfflineFileStore _inner = InMemoryOfflineFileStore();
  bool deniedDeletes = false;
  final Set<String> denied = <String>{};

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
    if (deniedDeletes || denied.contains(fileName)) {
      throw FileSystemException('Cannot delete file', fileName,
          const OSError('Permission denied', 13));
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

const Track _song = Track(id: 'j1', title: 'Nightcall', uri: 'jellyfin:j1');

void main() {
  test(
      'a removal whose file cannot be deleted keeps the copy counted, and a '
      'second try never reports it gone while its file stays', () async {
    final InMemoryDownloadStore store = InMemoryDownloadStore();
    final _DenyingFileStore files = _DenyingFileStore();
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: store,
      files: files,
      downloader: _Downloader(),
      connectivity: _Wifi(),
      preferences: InMemoryDownloadPreferences(),
    );
    await repository.requestDownload(_song);
    expect((await repository.cacheSnapshot()).usedBytes, 4);

    files.deniedDeletes = true;
    await expectLater(repository.removeDownload(_song), throwsA(anything));

    // The file is still there, so the copy still is: downloaded, listed and
    // counted toward the limit.
    expect(files.bytesFor('jellyfin_j1.mp3'), isNotNull);
    final DownloadStatus statusAfterFailure = await repository.statusFor('j1');
    final CacheSnapshot afterFailure = await repository.cacheSnapshot();

    // Asked again while the file still can't be deleted.
    Object? secondError;
    try {
      await repository.removeDownload(_song);
    } catch (error) {
      secondError = error;
    }

    expect(
      (
        statusAfterFailure: statusAfterFailure,
        listed: afterFailure.entries.map((CachedTrack c) => c.trackId).join(),
        usedBytes: afterFailure.usedBytes,
        // The second try fails too, rather than reading as removed while the
        // file stays on disk with no record naming it.
        secondFails: secondError != null,
        status: await repository.statusFor('j1'),
        recorded: (await store.loadDownloads())
            .any((CachedTrack c) => c.trackId == 'j1'),
        fileOnDisk: files.bytesFor('jellyfin_j1.mp3') != null,
      ),
      (
        statusAfterFailure: DownloadStatus.downloaded,
        listed: 'j1',
        usedBytes: 4,
        secondFails: true,
        status: DownloadStatus.downloaded,
        recorded: true,
        fileOnDisk: true,
      ),
    );

    // Once the file can be deleted, the removal goes through.
    files.deniedDeletes = false;
    await repository.removeDownload(_song);
    expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
    expect(files.bytesFor('jellyfin_j1.mp3'), isNull);
    expect(await store.loadDownloads(), isEmpty);
  });

  test(
      'Clear all goes on past a file it cannot delete, and leaves the cache '
      'saying what is still on disk', () async {
    final InMemoryDownloadStore store = InMemoryDownloadStore();
    final _DenyingFileStore files = _DenyingFileStore();
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: store,
      files: files,
      downloader: _Downloader(),
      connectivity: _Wifi(),
      preferences: InMemoryDownloadPreferences(),
    );
    for (final String id in <String>['a', 'b', 'c']) {
      await repository
          .requestDownload(Track(id: id, title: id, uri: 'jellyfin:$id'));
    }
    final List<Map<String, DownloadStatus>> rows =
        <Map<String, DownloadStatus>>[];
    final StreamSubscription<Map<String, DownloadStatus>> sub =
        repository.statusStream.listen(rows.add);
    await Future<void>.delayed(Duration.zero);

    // b's file can't be deleted (left behind by a run as another user, say).
    files.denied.add('jellyfin_b.mp3');
    Object? error;
    try {
      await repository.clearAll();
    } catch (e) {
      error = e;
    }
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(
      (
        onDisk: <String>[
          for (final String id in <String>['a', 'b', 'c'])
            if (files.bytesFor('jellyfin_$id.mp3') != null) id,
        ].join(','),
        // What the Downloads screen was last told.
        shownDownloaded: (<String>[
          for (final MapEntry<String, DownloadStatus> e in rows.last.entries)
            if (e.value == DownloadStatus.downloaded)
              e.key.substring(e.key.indexOf(String.fromCharCode(0)) + 1),
        ]..sort())
            .join(','),
        recorded: <String>[
          for (final CachedTrack c in await store.loadDownloads()) c.trackId,
        ].join(','),
      ),
      (onDisk: 'b', shownDownloaded: 'b', recorded: 'b'),
      reason: 'clearAll threw: $error',
    );
  });
}
