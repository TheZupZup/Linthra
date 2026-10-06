import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/data/repositories/shared_preferences_download_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// Preferences on a disk with no room left: every write reports that it
/// didn't happen, the way `LinuxSharedPreferencesStore` and Android's
/// `commit()` do.
class _FullDisk extends InMemorySharedPreferencesStore {
  _FullDisk(super.data) : super.withData();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

/// Covers the persistence contract *and* the in-memory memoization added to keep
/// the hot playback read-path (the cached-track locator calls [loadDownloads] on
/// every resolve/skip/pre-cache) from re-decoding the whole JSON document each
/// time. The memo must never hand back a stale or shared-mutable set.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SharedPreferencesDownloadStore', () {
    test('round-trips the cached set across separate instances', () async {
      await SharedPreferencesDownloadStore().saveDownloads(<CachedTrack>[
        const CachedTrack(trackId: 'a', fileName: 'a.mp3', sizeBytes: 10),
        const CachedTrack(trackId: 'b'),
      ]);

      // A fresh instance (no shared in-memory state) reads the persisted set
      // through the decode path.
      final List<CachedTrack> loaded =
          await SharedPreferencesDownloadStore().loadDownloads();

      expect(loaded.map((CachedTrack c) => c.trackId), <String>['a', 'b']);
      expect(
        loaded.firstWhere((CachedTrack c) => c.trackId == 'a').fileName,
        'a.mp3',
      );
    });

    test('keeps the server a Plex copy came from across instances', () async {
      // What tells a copy from one Plex server apart from another server's
      // song with the same ratingKey after a restart.
      await SharedPreferencesDownloadStore().saveDownloads(<CachedTrack>[
        const CachedTrack(
          trackId: '101',
          fileName: 'plex_101.flac',
          sourceType: 'plex',
          origin: 'machine-home',
        ),
        const CachedTrack(
            trackId: 'j1', fileName: 'jellyfin_j1.mp3', sourceType: 'jellyfin'),
      ]);

      final List<CachedTrack> loaded =
          await SharedPreferencesDownloadStore().loadDownloads();

      expect(loaded.map((CachedTrack c) => c.origin),
          <String?>['machine-home', null]);
    });

    test('repeated loads return equal but independent, caller-owned lists',
        () async {
      final SharedPreferencesDownloadStore store =
          SharedPreferencesDownloadStore();
      await store.saveDownloads(<CachedTrack>[
        const CachedTrack(trackId: 'a', fileName: 'a.mp3'),
      ]);

      final List<CachedTrack> first = await store.loadDownloads();
      final List<CachedTrack> second = await store.loadDownloads();
      expect(first, equals(second));
      // Not the same instance — a caller can't reach into the memo.
      expect(identical(first, second), isFalse);

      // Mutating a returned list must not corrupt the memoized set.
      first.clear();
      final List<CachedTrack> third = await store.loadDownloads();
      expect(third.map((CachedTrack c) => c.trackId), <String>['a']);
    });

    test('a save is reflected by the very next load (no stale memo)', () async {
      final SharedPreferencesDownloadStore store =
          SharedPreferencesDownloadStore();
      await store.saveDownloads(
        <CachedTrack>[const CachedTrack(trackId: 'a', fileName: 'a.mp3')],
      );
      expect(
        (await store.loadDownloads()).map((CachedTrack c) => c.trackId),
        <String>['a'],
      );

      // A different set writes a different JSON string, so the change is picked
      // up rather than the memo returning the old set.
      await store.saveDownloads(
        <CachedTrack>[const CachedTrack(trackId: 'b', fileName: 'b.mp3')],
      );
      expect(
        (await store.loadDownloads()).map((CachedTrack c) => c.trackId),
        <String>['b'],
      );
    });

    test('an empty store loads as nothing downloaded', () async {
      expect(await SharedPreferencesDownloadStore().loadDownloads(), isEmpty);
    });

    test(
        'a write that did not happen throws, and the next launch reads the '
        'set saved before it (#786)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SharedPreferencesDownloadStore().saveDownloads(<CachedTrack>[
        const CachedTrack(trackId: 'a', fileName: 'a.mp3', sizeBytes: 10),
      ]);
      final SharedPreferences saved = await SharedPreferences.getInstance();
      SharedPreferencesStorePlatform.instance = _FullDisk(<String, Object>{
        'flutter.offline_downloads_v2':
            saved.getString('offline_downloads_v2')!,
      });
      SharedPreferences.resetStatic();
      addTearDown(() {
        SharedPreferencesStorePlatform.instance =
            InMemorySharedPreferencesStore.empty();
        SharedPreferences.resetStatic();
      });

      await expectLater(
        SharedPreferencesDownloadStore().saveDownloads(<CachedTrack>[
          const CachedTrack(trackId: 'a', fileName: 'a.mp3', sizeBytes: 10),
          const CachedTrack(trackId: 'b', fileName: 'b.mp3', sizeBytes: 20),
        ]),
        throwsA(isA<DownloadStoreWriteException>()),
      );

      SharedPreferences.resetStatic();
      final List<CachedTrack> relaunched =
          await SharedPreferencesDownloadStore().loadDownloads();
      expect(relaunched.map((CachedTrack c) => c.trackId), <String>['a']);
    });

    test('a corrupt record reads as nothing downloaded', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'offline_downloads_v2': 'not json at all',
      });
      expect(await SharedPreferencesDownloadStore().loadDownloads(), isEmpty);
    });
  });
}
