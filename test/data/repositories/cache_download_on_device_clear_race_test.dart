// "Keep offline" on an on-device song while Clear all runs.
//
// The song's record is all there is of it. Clear all, landing while that
// record was being saved, forgot it (and saved the set without it), and the
// request then marked the song kept offline anyway: a row with no record
// behind it, which reads as not kept after the next launch, and which a
// further request can't fix (it is "already kept").
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

class _NoRemote implements RemoteTrackDownloader {
  @override
  bool isRemote(Track track) => false;

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) =>
      throw UnsupportedError('on-device only');
}

const Track _onDevice = Track(
  id: '/music/a.mp3',
  title: 'Midnight City',
  uri: '/music/a.mp3',
);

/// Applies every save at once, holding the completion of the first one that
/// records [_onDevice] (a platform-channel round trip on Android).
class _SlowRecordStore implements DownloadStore {
  final InMemoryDownloadStore _inner = InMemoryDownloadStore();
  final Completer<void> reachedSave = Completer<void>();
  final Completer<void> releaseSave = Completer<void>();

  @override
  Future<List<CachedTrack>> loadDownloads() => _inner.loadDownloads();

  @override
  Future<void> saveDownloads(List<CachedTrack> downloads) async {
    await _inner.saveDownloads(downloads);
    if (downloads.any((CachedTrack c) => c.trackId == _onDevice.id) &&
        !reachedSave.isCompleted) {
      reachedSave.complete();
      await releaseSave.future;
    }
  }
}

void main() {
  test(
      'an on-device song cleared while it is being kept offline never reads '
      'kept without its record', () async {
    final _SlowRecordStore store = _SlowRecordStore();
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: store,
      files: InMemoryOfflineFileStore(),
      downloader: _NoRemote(),
      connectivity: _Wifi(),
      preferences: InMemoryDownloadPreferences(),
    );
    await repository.cacheSnapshot();

    final Future<DownloadRequestOutcome> keeping =
        repository.requestDownload(_onDevice);
    await store.reachedSave.future;
    await repository.clearAll();
    store.releaseSave.complete();
    await keeping;

    final DownloadStatus status = await repository.statusFor(_onDevice.id);
    final bool recorded = (await store.loadDownloads())
        .any((CachedTrack c) => c.trackId == _onDevice.id);
    final bool listed = (await repository.cacheSnapshot())
        .entries
        .any((CachedTrack c) => c.trackId == _onDevice.id);
    // Whichever wins, the row agrees with the record the next launch reads.
    expect(
      (status: status, recorded: recorded, listed: listed),
      anyOf(
        (status: DownloadStatus.downloaded, recorded: true, listed: true),
        (status: DownloadStatus.notDownloaded, recorded: false, listed: false),
      ),
    );
  });
}
