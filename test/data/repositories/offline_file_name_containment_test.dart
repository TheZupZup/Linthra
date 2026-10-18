// A download record can only ever name a file inside the offline folder.
//
// `CachedTrack.fromJson` takes any string as a file name, and the file store
// resolved it with `p.join(offlineDir, fileName)`, which keeps an absolute
// name as it is and follows `../`. A stored record naming one (a hand-edited
// or damaged preferences file) made Clear all and Remove download delete a
// file outside the folder: the listener's own music. The store only ever
// writes plain names, so it now answers anything else as no file at all.
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

class _NoFetch implements RemoteTrackDownloader {
  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) =>
      throw StateError('nothing is fetched here');
}

void main() {
  late Directory root;
  late Directory offline;
  late File song;
  late FileSystemOfflineFileStore files;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('linthra_name_containment_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    offline = await Directory('${root.path}/offline_audio').create();
    song = File('${root.path}/Music/song.flac');
    await song.create(recursive: true);
    await song.writeAsBytes(const <int>[1, 2, 3, 4]);
    files = FileSystemOfflineFileStore(directory: () async => offline);
  });

  CacheDownloadRepository launchWith(String fileName) {
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: InMemoryDownloadStore(
        initialDownloads: <CachedTrack>[
          CachedTrack.fromJson(<String, dynamic>{
            'trackId': 'x1',
            'fileName': fileName,
            'sourceType': 'jellyfin',
            'sizeBytes': 4,
          })!,
        ],
      ),
      files: files,
      downloader: _NoFetch(),
      connectivity: _Wifi(),
      preferences: InMemoryDownloadPreferences(),
    );
    addTearDown(repository.dispose);
    return repository;
  }

  test('Clear all leaves a file a "../" record names outside the folder',
      () async {
    final CacheDownloadRepository repository = launchWith('../Music/song.flac');

    await repository.clearAll();

    expect(song.existsSync(), isTrue, reason: 'Music/song.flac was deleted');
  });

  test('Remove download leaves a file an absolute record names', () async {
    final CacheDownloadRepository repository = launchWith(song.path);

    await repository.removeDownload(
      const Track(id: 'x1', title: 'X1', uri: 'jellyfin:x1'),
    );

    expect(song.existsSync(), isTrue, reason: 'Music/song.flac was deleted');
  });

  test('such a record is never served, nor counted as downloaded', () async {
    final CacheDownloadRepository repository = launchWith('../Music/song.flac');

    expect(await repository.statusFor('x1'), DownloadStatus.notDownloaded);
    for (final String name in <String>[
      '../Music/song.flac',
      song.path,
      '..',
      '.',
      'sub/../../Music/song.flac',
    ]) {
      expect(await files.pathFor(name), isNull, reason: name);
      expect(await files.sizeFor(name), isNull, reason: name);
    }
    expect(song.existsSync(), isTrue);
  });

  test('a plain name in the folder still resolves', () async {
    final File cached = File('${offline.path}/x1.mp3')
      ..writeAsBytesSync(const <int>[1, 2, 3]);

    expect(await files.pathFor('x1.mp3'), cached.path);
    expect(await files.sizeFor('x1.mp3'), 3);
    await files.delete('x1.mp3');
    expect(cached.existsSync(), isFalse);
  });
}
