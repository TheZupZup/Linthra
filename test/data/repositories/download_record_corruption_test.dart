// One download record that can't be read must not cost the others.
//
// `CachedTrack.fromJson` promises that one bad record can't break loading,
// but a record whose date is out of DateTime's range (or whose file name or
// track id isn't a string) threw out of the whole decode. The download
// store's memo then remembered the document as decoded, so every later read
// that session answered "nothing downloaded": the repository loaded empty,
// its next save wrote only the new records, and the next launch's sweep
// (#747) deleted every other downloaded file as one no record names.
//
// Staged with the real preferences-backed store and the real file store over
// a temp folder, so a "next launch" runs the real sweep.
import 'dart:convert';
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
import 'package:linthra/data/repositories/in_memory_offline_file_store.dart';
import 'package:linthra/data/repositories/shared_preferences_download_store.dart';
import 'package:linthra/data/repositories/store_cached_track_locator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/offline_file_writes.dart';

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

const String _key = 'offline_downloads_v2';

/// A download as the app writes it.
const Map<String, Object> _good = <String, Object>{
  'trackId': 'a1',
  'fileName': 'a1.mp3',
  'sourceType': 'jellyfin',
  'sizeBytes': 4,
  'cachedAt': 1700000000000,
};

/// The same shape, with a date past the end of DateTime's range: a damaged
/// or hand-edited record, or one from another build.
const Map<String, Object> _farFuture = <String, Object>{
  'trackId': 'b1',
  'fileName': 'b1.mp3',
  'sourceType': 'jellyfin',
  'sizeBytes': 4,
  'cachedAt': 9000000000000000,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a download record that cannot be read', () {
    test('leaves the other records readable, on every read', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _key: jsonEncode(<Object>[_good, _farFuture]),
      });
      final SharedPreferencesDownloadStore store =
          SharedPreferencesDownloadStore();

      for (int read = 1; read <= 2; read++) {
        final List<CachedTrack> loaded = await store.loadDownloads();
        expect(
          loaded.map((CachedTrack c) => c.trackId),
          <String>['a1', 'b1'],
          reason: 'read $read',
        );
        // Only the date is unusable; the record itself still names its file.
        expect(loaded.last.fileName, 'b1.mp3', reason: 'read $read');
        expect(loaded.last.cachedAt, isNull, reason: 'read $read');
      }
    });

    test('a field of the wrong type drops that record, not the others',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _key: jsonEncode(<Object>[
          _good,
          <String, Object>{'trackId': 'c1', 'fileName': 7},
          <String, Object>{'trackId': 42, 'fileName': 'd1.mp3'},
        ]),
      });
      final SharedPreferencesDownloadStore store =
          SharedPreferencesDownloadStore();

      for (int read = 1; read <= 2; read++) {
        expect(
          (await store.loadDownloads()).map((CachedTrack c) => c.trackId),
          <String>['a1'],
          reason: 'read $read',
        );
      }
    });
  });

  test('playback still finds the offline copies, and skips the rest', () async {
    // Every track resolves through the locator first, songs on the device
    // included: a throw here is "Couldn't play this track" for all of them.
    SharedPreferences.setMockInitialValues(<String, Object>{
      _key: jsonEncode(<Object>[_good, _farFuture]),
    });
    final InMemoryOfflineFileStore files = InMemoryOfflineFileStore();
    final String a1 =
        await files.write('a1', const <int>[1, 2, 3, 4], extension: 'mp3');
    final StoreCachedTrackLocator locator =
        StoreCachedTrackLocator(SharedPreferencesDownloadStore(), files);

    expect(
      await locator.cachedFilePath(
        const Track(id: '/music/x.flac', title: 'X', uri: '/music/x.flac'),
      ),
      isNull,
    );
    expect(
      await locator.cachedFilePath(
        const Track(id: 'a1', title: 'A', uri: 'jellyfin:a1'),
      ),
      await files.pathFor(a1),
    );
  });

  group('a download beside a record that cannot be read', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('linthra_bad_record_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
    });

    CacheDownloadRepository launch() => CacheDownloadRepository(
          store: SharedPreferencesDownloadStore(),
          files: FileSystemOfflineFileStore(directory: () async => dir),
          downloader: _InstantDownloader(),
          connectivity: _Wifi(),
          preferences: InMemoryDownloadPreferences(),
        );

    /// A cache file downloaded on an earlier day, so a launch's sweep of
    /// abandoned files may take it if no record names it.
    File downloadedEarlier(String name) {
      final File file = File('${dir.path}/$name')
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      file.setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 1)),
      );
      return file;
    }

    test('stays downloaded, and its file survives the next launch', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _key: jsonEncode(<Object>[_good, _farFuture]),
      });
      final File a1 = downloadedEarlier('a1.mp3');
      final File b1 = downloadedEarlier('b1.mp3');

      final CacheDownloadRepository repository = launch();
      // Whatever the first read made of the damaged document, the app carries
      // on: the screen asks again, playback resolves the next track.
      try {
        await repository.statusFor('a1');
      } catch (_) {}
      expect(await repository.statusFor('a1'), DownloadStatus.downloaded);

      // The listener downloads one more song, which saves the records.
      await repository.requestDownload(
        const Track(id: 'c1', title: 'New', uri: 'jellyfin:c1'),
      );

      SharedPreferences.resetStatic();
      final CacheDownloadRepository relaunched = launch();
      expect(await relaunched.statusFor('a1'), DownloadStatus.downloaded);
      expect(await relaunched.statusFor('b1'), DownloadStatus.downloaded);
      expect(a1.existsSync(), isTrue, reason: 'a1.mp3 deleted by the sweep');
      expect(b1.existsSync(), isTrue, reason: 'b1.mp3 deleted by the sweep');
    });
  });
}
