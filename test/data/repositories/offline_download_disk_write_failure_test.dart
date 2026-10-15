// A download whose bytes the disk would not take must leave nothing behind.
//
// A download is written to a `.part` temp file as it arrives and renamed into
// place only once every byte is there (#745). Two ways a full disk shows up
// along the way: a write that only took part of its bytes, which the publish
// has to catch by comparing the temp file's length with what was added, and a
// write that throws outright (ENOSPC) part way through the body. Either way no
// cache file may appear, no temp file may be left to take up the space the
// disk just ran out of, and no record may say the song is downloaded.
//
// Staged with the real file store over a temp folder, failing the disk through
// its `openDraft` seam.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/offline_file_store.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/data/repositories/cache_download_repository.dart';
import 'package:linthra/data/repositories/file_system_offline_file_store.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/data/repositories/in_memory_download_store.dart';

import '../../support/offline_file_writes.dart';

const FileSystemException _noSpace = FileSystemException(
  'No space left on device',
  null,
  OSError('No space left on device', 28),
);

/// An open file that keeps only the first half of every write yet reports it
/// done, the way a disk that filled up mid-write can leave a short write.
class _ShortWrites implements RandomAccessFile {
  _ShortWrites(this._inner);

  final RandomAccessFile _inner;

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    final int stop = end ?? buffer.length;
    await _inner.writeFrom(buffer, start, start + (stop - start) ~/ 2);
    return this;
  }

  @override
  Future<RandomAccessFile> flush() async {
    await _inner.flush();
    return this;
  }

  @override
  Future<void> close() => _inner.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An open file that takes its first write and fails every one after it, the
/// way the disk does once it is full.
class _FullAfterFirstWrite implements RandomAccessFile {
  _FullAfterFirstWrite(this._inner);

  final RandomAccessFile _inner;
  int writes = 0;
  bool closed = false;

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    if (++writes > 1) throw _noSpace;
    await _inner.writeFrom(buffer, start, end);
    return this;
  }

  @override
  Future<RandomAccessFile> flush() async {
    await _inner.flush();
    return this;
  }

  @override
  Future<void> close() async {
    closed = true;
    await _inner.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Wifi implements ConnectivityService {
  @override
  Stream<NetworkStatus> get statusStream => const Stream<NetworkStatus>.empty();

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
}

/// Hands back a body still arriving, a chunk at a time, as the real
/// downloaders do.
class _StreamingDownloader implements RemoteTrackDownloader {
  _StreamingDownloader(this.chunks);

  final List<List<int>> chunks;

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async =>
      RemoteTrackData.streamed(
        body: Stream<List<int>>.fromIterable(chunks),
        length: chunks.fold<int>(0, (int n, List<int> c) => n + c.length),
        fileExtension: 'mp3',
      );
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('linthra_disk_full_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
  });

  List<String> namesOnDisk() => <String>[
        for (final FileSystemEntity e in dir.listSync())
          e.uri.pathSegments.last,
      ];

  group('a write the disk only partly took', () {
    late FileSystemOfflineFileStore store;

    setUp(() {
      store = FileSystemOfflineFileStore(
        directory: () async => dir,
        openDraft: (File temp) async =>
            _ShortWrites(await temp.open(mode: FileMode.writeOnly)),
      );
    });

    test('is refused at publish, leaving no cache file and no temp', () async {
      final OfflineFileDraft draft = await store.createDraft('t1');
      await draft.add(const <int>[1, 2, 3, 4]);
      await draft.add(const <int>[5, 6, 7, 8]);

      await expectLater(
        draft.publish(extension: 'mp3'),
        throwsA(
          isA<FileSystemException>().having(
            (FileSystemException e) => e.message,
            'message',
            contains('incomplete'),
          ),
        ),
      );

      expect(await store.pathFor('t1.mp3'), isNull);
      expect(await store.sizeFor('t1.mp3'), isNull);
      expect(namesOnDisk(), isEmpty);
    });

    test('over an earlier copy leaves that copy whole', () async {
      // A re-download that fails at publish never got as far as the rename,
      // so the copy already cached keeps serving.
      final FileSystemOfflineFileStore healthy =
          FileSystemOfflineFileStore(directory: () async => dir);
      await healthy.write('t1', const <int>[9, 9, 9], extension: 'mp3');

      final OfflineFileDraft draft = await store.createDraft('t1');
      await draft.add(const <int>[1, 2, 3, 4]);
      await expectLater(
        draft.publish(extension: 'mp3'),
        throwsA(isA<FileSystemException>()),
      );

      expect(namesOnDisk(), <String>['t1.mp3']);
      expect(
        await File((await store.pathFor('t1.mp3'))!).readAsBytes(),
        <int>[9, 9, 9],
      );
    });
  });

  group('a disk that fills up part way through a download', () {
    test(
        'fails the download, saves no record and leaves no temp file in the '
        'offline folder', () async {
      late _FullAfterFirstWrite opened;
      final InMemoryDownloadStore records = InMemoryDownloadStore();
      final _StreamingDownloader downloader = _StreamingDownloader(
        <List<int>>[
          <int>[1, 2, 3, 4],
          <int>[5, 6, 7, 8],
          <int>[9, 10, 11, 12],
        ],
      );
      final CacheDownloadRepository repository = CacheDownloadRepository(
        store: records,
        files: FileSystemOfflineFileStore(
          directory: () async => dir,
          openDraft: (File temp) async => opened =
              _FullAfterFirstWrite(await temp.open(mode: FileMode.writeOnly)),
        ),
        downloader: downloader,
        connectivity: _Wifi(),
        preferences: InMemoryDownloadPreferences(),
      );
      addTearDown(repository.dispose);
      const Track track = Track(id: 'j1', title: 'J1', uri: 'jellyfin:j1');

      await repository.requestDownload(track);

      expect(await repository.statusFor('j1'), DownloadStatus.failed);
      expect(await records.loadDownloads(), isEmpty);
      expect(namesOnDisk(), isEmpty, reason: 'a .part temp was left behind');
      expect(opened.closed, isTrue, reason: 'the temp file was left open');
      // The write that failed was the second; the rest of the body is not
      // written to a disk that has no room for it.
      expect(opened.writes, 2);
      expect((await repository.cacheSnapshot()).usedBytes, 0);
    });
  });
}
