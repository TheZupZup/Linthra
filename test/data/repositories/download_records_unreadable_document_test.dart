// A downloads document that can't be read must not cost the files it named.
//
// When the saved download records can't be read at all (a write cut short, a
// document from another version), the cache loads as "nothing downloaded" and
// that launch's sweep (#747) only takes temp files, since the files on disk
// may be the ones the document names. The next save used to write the new
// records over that document, so the launch after it saw a record list that
// named none of the older files, and its sweep deleted every one of them.
// The unreadable document is now set aside before anything is written over
// it, and while it is kept aside the sweep keeps to temp files. The same goes
// for a document with one record that can't be read: the sweep used to take
// that record's file on the very first launch.
//
// Staged with the real preferences-backed store and the real file store over
// a temp folder, so each "launch" runs the real load and sweep.
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
import 'package:linthra/data/repositories/shared_preferences_download_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

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

/// Preferences that refuse to write the set-aside copy (a disk filling up
/// right then), and take every other write.
class _NoRoomForTheCopy extends InMemorySharedPreferencesStore {
  _NoRoomForTheCopy(super.data) : super.withData();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.${_key}_unreadable') return false;
    return super.setValue(valueType, key, value);
  }
}

const String _key = 'offline_downloads_v2';

/// A records document cut short in the middle of its first record.
const String _unreadable = '[{"trackId":"a1","fileName":"a1.mp3"';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('linthra_unreadable_doc_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
  });

  CacheDownloadRepository launch() {
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: SharedPreferencesDownloadStore(),
      files: FileSystemOfflineFileStore(directory: () async => dir),
      downloader: _InstantDownloader(),
      connectivity: _Wifi(),
      preferences: InMemoryDownloadPreferences(),
    );
    addTearDown(repository.dispose);
    return repository;
  }

  /// A cache file downloaded on an earlier day, so a launch's sweep may take
  /// it if it is free to.
  File downloadedEarlier(String name) {
    final File file = File('${dir.path}/$name')
      ..writeAsBytesSync(<int>[1, 2, 3, 4]);
    file.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 1)));
    return file;
  }

  test(
      'the files an unreadable document named survive a new download and the '
      'launch after it', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{_key: _unreadable});
    final File a1 = downloadedEarlier('a1.mp3');

    final CacheDownloadRepository repository = launch();
    await repository.statusFor('a1');
    expect(a1.existsSync(), isTrue, reason: 'the first launch keeps it');

    await repository.requestDownload(
      const Track(id: 'c1', title: 'New', uri: 'jellyfin:c1'),
    );

    SharedPreferences.resetStatic();
    final CacheDownloadRepository relaunched = launch();
    expect(await relaunched.statusFor('c1'), DownloadStatus.downloaded);
    expect(a1.existsSync(), isTrue, reason: 'a1.mp3 deleted by the sweep');
  });

  test('the unreadable document is kept aside, exactly as it was', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{_key: _unreadable});
    final CacheDownloadRepository repository = launch();

    await repository.requestDownload(
      const Track(id: 'c1', title: 'New', uri: 'jellyfin:c1'),
    );

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('${_key}_unreadable'), _unreadable);
    // The live document holds what was saved since.
    expect(prefs.getString(_key), contains('"trackId":"c1"'));
  });

  test('a record that cannot be read keeps its file, on every launch',
      () async {
    // The rest of the document reads, so the downloads it names stay; the
    // one record that doesn't may still name a file.
    SharedPreferences.setMockInitialValues(<String, Object>{
      _key: '[{"trackId":"c1","fileName":"c1.mp3","sourceType":"jellyfin",'
          '"sizeBytes":4,"cachedAt":1700000000000},'
          '{"trackId":42,"fileName":"d1.mp3"}]',
    });
    downloadedEarlier('c1.mp3');
    final File d1 = downloadedEarlier('d1.mp3');

    final CacheDownloadRepository repository = launch();
    expect(await repository.statusFor('c1'), DownloadStatus.downloaded);
    expect(d1.existsSync(), isTrue, reason: 'd1.mp3 deleted by the sweep');

    await repository.requestDownload(
      const Track(id: 'e1', title: 'New', uri: 'jellyfin:e1'),
    );
    SharedPreferences.resetStatic();
    final CacheDownloadRepository relaunched = launch();
    expect(await relaunched.statusFor('e1'), DownloadStatus.downloaded);
    expect(d1.existsSync(), isTrue, reason: 'd1.mp3 deleted by the sweep');
  });

  test('a save that cannot keep the copy aside leaves the document as it was',
      () async {
    SharedPreferencesStorePlatform.instance = _NoRoomForTheCopy(
      <String, Object>{'flutter.$_key': _unreadable},
    );
    SharedPreferences.resetStatic();
    addTearDown(() {
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.empty();
      SharedPreferences.resetStatic();
    });

    await expectLater(
      SharedPreferencesDownloadStore().saveDownloads(<CachedTrack>[
        const CachedTrack(trackId: 'c1', fileName: 'c1.mp3'),
      ]),
      throwsA(isA<DownloadStoreWriteException>()),
    );

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(_key), _unreadable);
    // Nor does this run take a copy that was never written for one that was.
    expect(prefs.get('${_key}_unreadable'), isNull);
  });

  test('a readable document still lets the sweep take abandoned files',
      () async {
    // The guard is for a document that couldn't be read; a normal one keeps
    // the sweep that clears a file no record names (#747).
    SharedPreferences.setMockInitialValues(<String, Object>{
      _key: '[{"trackId":"c1","fileName":"c1.mp3","sourceType":"jellyfin",'
          '"sizeBytes":4,"cachedAt":1700000000000}]',
    });
    downloadedEarlier('c1.mp3');
    final File orphan = downloadedEarlier('orphan.mp3');

    final CacheDownloadRepository repository = launch();
    expect(await repository.statusFor('c1'), DownloadStatus.downloaded);

    expect(orphan.existsSync(), isFalse);
  });
}
