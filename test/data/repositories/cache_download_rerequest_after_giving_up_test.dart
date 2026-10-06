// A download asked for again once its cancelled request can no longer
// deliver.
//
// A removal (or a Clear all) only marks a running download cancelled; the
// download notices at its next check and gives up. Asking for the song again
// before that request has finished takes it back ("A fresh, explicit request
// supersedes a pending cancellation"). That is right while the request can
// still save its bytes, but not in two windows:
//
//  - Its commit has already seen the cancellation and given up, and is
//    handing its draft back (on the disk: closing and deleting the temp
//    file). Nothing will ever save the bytes: the row went back to
//    "Downloading" and stayed there, with nothing downloading, and smart
//    pre-cache skipped the song for the rest of the session.
//  - Its commit was past its last check, saving the record, so the removal
//    took the copy (record and file) back out. The request then marked the
//    song Downloaded anyway: a row with no record and no file behind it, which
//    a further tap can't fix (it is "already downloaded").
//
// Both windows are real I/O (a temp file closed and deleted, a record save
// that is a platform-channel round trip on Android), so the listener's tap,
// or a "Download all" reaching the song, lands while they run.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/download_progress.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/repositories/offline_file_store.dart';
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

class _Downloader implements RemoteTrackDownloader {
  int fetches = 0;

  /// When set, every fetch after the first waits on it.
  Completer<void>? holdLaterFetches;

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    fetches++;
    final Completer<void>? hold = holdLaterFetches;
    if (fetches > 1 && hold != null) await hold.future;
    return const RemoteTrackData(
        bytes: <int>[1, 2, 3, 4], fileExtension: 'mp3');
  }
}

/// Holds the cache limit read made inside a download's commit (a user
/// download reads it once before fetching and once in its commit), so a
/// removal can land while the commit is parked before its next check.
class _HeldCommitPreferences extends InMemoryDownloadPreferences {
  int _reads = 0;
  final Completer<void> reached = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<int> maxCacheBytes() async {
    _reads++;
    if (_reads == 2) {
      reached.complete();
      await release.future;
    }
    return super.maxCacheBytes();
  }
}

/// Drafts whose discard of unpublished bytes can be held, the way closing and
/// deleting a temp file on the disk takes a moment during which other work
/// (a tap) runs.
class _SlowDiscardFileStore implements OfflineFileStore {
  _SlowDiscardFileStore(this._inner);

  final InMemoryOfflineFileStore _inner;

  /// When set, discarding an unpublished draft waits on it.
  Completer<void>? hold;
  final Completer<void> reachedDiscard = Completer<void>();

  List<int>? bytesFor(String fileName) => _inner.bytesFor(fileName);

  @override
  Future<OfflineFileDraft> createDraft(String trackId) async =>
      _SlowDiscardDraft(this, await _inner.createDraft(trackId));

  @override
  Future<String?> pathFor(String fileName) => _inner.pathFor(fileName);

  @override
  Future<int?> sizeFor(String fileName) => _inner.sizeFor(fileName);

  @override
  Future<void> delete(String fileName) => _inner.delete(fileName);

  @override
  Future<void> removeAbandoned(
    Set<String> referenced, {
    bool temporaryOnly = false,
  }) =>
      _inner.removeAbandoned(referenced, temporaryOnly: temporaryOnly);
}

class _SlowDiscardDraft implements OfflineFileDraft {
  _SlowDiscardDraft(this._store, this._inner);

  final _SlowDiscardFileStore _store;
  final OfflineFileDraft _inner;
  bool _published = false;

  @override
  int get length => _inner.length;

  @override
  Future<void> add(List<int> chunk) => _inner.add(chunk);

  @override
  Future<String> publish({String? extension}) async {
    final String name = await _inner.publish(extension: extension);
    _published = true;
    return name;
  }

  @override
  Future<void> discard() async {
    final Completer<void>? pending = _store.hold;
    if (!_published && pending != null) {
      if (!_store.reachedDiscard.isCompleted) {
        _store.reachedDiscard.complete();
      }
      await pending.future;
    }
    await _inner.discard();
  }
}

const Track _song = Track(id: 'j1', title: 'Nightcall', uri: 'jellyfin:j1');

/// The download records, applied the moment a save is asked for (as
/// SharedPreferences updates its value at once), with the completion of the
/// first save that holds [_song] as a download held open: on Android that
/// completion is a platform-channel round trip, so other work runs before it.
class _SlowRecordStore implements DownloadStore {
  final InMemoryDownloadStore _inner = InMemoryDownloadStore();
  final Completer<void> reachedSave = Completer<void>();
  final Completer<void> releaseSave = Completer<void>();

  /// When set, the held save fails once released (the disk filled up),
  /// leaving the last saved set as it was.
  bool failHeldSave = false;

  @override
  Future<List<CachedTrack>> loadDownloads() => _inner.loadDownloads();

  @override
  Future<void> saveDownloads(List<CachedTrack> downloads) async {
    final bool holdsSong =
        downloads.any((CachedTrack c) => c.trackId == _song.id && !c.preloaded);
    if (holdsSong && !reachedSave.isCompleted) {
      if (!failHeldSave) await _inner.saveDownloads(downloads);
      reachedSave.complete();
      await releaseSave.future;
      if (failHeldSave) throw const DownloadStoreWriteException();
      return;
    }
    await _inner.saveDownloads(downloads);
  }
}

/// How the listener calls a running download off.
enum _CallOff { remove, clearAll }

Future<void> _callOff(CacheDownloadRepository repository, _CallOff how) =>
    switch (how) {
      _CallOff.remove => repository.removeDownload(_song),
      _CallOff.clearAll => repository.clearAll(),
    };

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  for (final _CallOff how in _CallOff.values) {
    group('called off with ${how.name}', () {
      test(
          'asked for again once its cancelled commit has given up, a download '
          'is fetched afresh instead of sticking at Downloading', () async {
        final _Downloader downloader = _Downloader();
        final _HeldCommitPreferences preferences = _HeldCommitPreferences();
        final _SlowDiscardFileStore files =
            _SlowDiscardFileStore(InMemoryOfflineFileStore());
        final CacheDownloadRepository repository = CacheDownloadRepository(
          store: InMemoryDownloadStore(),
          files: files,
          downloader: downloader,
          connectivity: _Wifi(),
          preferences: preferences,
        );
        final List<Map<String, DownloadProgress>> progress =
            <Map<String, DownloadProgress>>[];
        final StreamSubscription<Map<String, DownloadProgress>> progressSub =
            repository.progressStream.listen(progress.add);

        // The bytes are in, and the commit is parked before its next check...
        final Future<DownloadRequestOutcome> first =
            repository.requestDownload(_song);
        await preferences.reached.future;
        // ...when the listener calls the download off.
        await _callOff(repository, how);
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);

        // The commit sees the cancellation and gives up; its draft is being
        // discarded when the listener asks for the song again.
        files.hold = Completer<void>();
        preferences.release.complete();
        await files.reachedDiscard.future;
        final Future<DownloadRequestOutcome> second =
            repository.requestDownload(_song);
        files.hold!.complete();
        await Future.wait(<Future<DownloadRequestOutcome>>[first, second]);
        await _settle();

        // The second request is the listener's: it ends downloaded, not on a
        // row that says "Downloading" while nothing downloads.
        expect(
          await repository.statusFor('j1'),
          DownloadStatus.downloaded,
          reason: 'fetches: ${downloader.fetches}, cached file: '
              '${files.bytesFor('jellyfin_j1.mp3')}, '
              'progress: ${progress.last}',
        );
        expect(files.bytesFor('jellyfin_j1.mp3'), isNotNull);
        await progressSub.cancel();
      });

      test(
          'called off while its record is being saved, then asked for again, '
          'a download never reads Downloaded without its record and file',
          () async {
        final _Downloader downloader = _Downloader();
        final _SlowRecordStore store = _SlowRecordStore();
        final InMemoryOfflineFileStore files = InMemoryOfflineFileStore();
        final CacheDownloadRepository repository = CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: _Wifi(),
          preferences: InMemoryDownloadPreferences(),
        );

        // The file is in place and the record saying so is on its way to
        // disk...
        final Future<DownloadRequestOutcome> first =
            repository.requestDownload(_song);
        await store.reachedSave.future;
        // ...when the listener calls the download off (its file goes with
        // it)...
        await _callOff(repository, how);
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect(files.bytesFor('jellyfin_j1.mp3'), isNull);
        // ...and asks for it again (a tap, or "Download all" reaching it).
        final Future<DownloadRequestOutcome> second =
            repository.requestDownload(_song);
        store.releaseSave.complete();
        await Future.wait(<Future<DownloadRequestOutcome>>[first, second]);
        await _settle();

        final DownloadStatus status = await repository.statusFor('j1');
        final bool recorded = (await store.loadDownloads())
            .any((CachedTrack c) => c.trackId == 'j1' && !c.preloaded);
        final bool onDisk = files.bytesFor('jellyfin_j1.mp3') != null;
        // The listener's last word was "download": the song ends downloaded,
        // with a record and a file behind the row.
        expect(
          (status: status, recorded: recorded, onDisk: onDisk),
          (status: DownloadStatus.downloaded, recorded: true, onDisk: true),
          reason: 'fetches: ${downloader.fetches}',
        );
      });
    });
  }

  test(
      'a removed download whose record then fails to save leaves the row to '
      'the request asked after it', () async {
    final _Downloader downloader = _Downloader()
      ..holdLaterFetches = Completer<void>();
    final _SlowRecordStore store = _SlowRecordStore()..failHeldSave = true;
    final InMemoryOfflineFileStore files = InMemoryOfflineFileStore();
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: store,
      files: files,
      downloader: downloader,
      connectivity: _Wifi(),
      preferences: InMemoryDownloadPreferences(),
    );

    final Future<DownloadRequestOutcome> first =
        repository.requestDownload(_song);
    await store.reachedSave.future;
    await repository.removeDownload(_song);
    final Future<DownloadRequestOutcome> second =
        repository.requestDownload(_song);
    for (int i = 0; i < 20 && downloader.fetches < 2; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    // The second request is fetching when the first one's save fails.
    store.releaseSave.complete();
    await expectLater(first, throwsA(isA<CacheStorageException>()));
    await _settle();
    expect(await repository.statusFor('j1'), DownloadStatus.downloading);

    downloader.holdLaterFetches!.complete();
    await second;
    expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
    expect(files.bytesFor('jellyfin_j1.mp3'), isNotNull);
  });
}
