import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/repositories/local_store_write_exception.dart';
import 'package:linthra/core/repositories/pending_track_move_store.dart';
import 'package:linthra/data/repositories/shared_preferences_library_added_store.dart';
import 'package:linthra/data/repositories/shared_preferences_pending_track_move_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _FullDisk extends InMemorySharedPreferencesStore {
  _FullDisk() : super.empty();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;

  @override
  Future<bool> remove(String key) async => false;
}

const PendingTrackMove _move = PendingTrackMove(
  from: '/music/inbox/a.flac',
  to: '/music/Bon Iver/05.flac',
  targets: <String>{'playlists', 'favorites'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  const SharedPreferencesPendingTrackMoveStore store =
      SharedPreferencesPendingTrackMoveStore();

  test('kept moves survive a restart, in order', () async {
    const PendingTrackMove later = PendingTrackMove(
      from: '/music/Bon Iver/05.flac',
      to: '/music/Bon Iver/Bon Iver/05.flac',
      targets: <String>{'playlists'},
    );
    await store.save(const <PendingTrackMove>[_move, later]);

    SharedPreferences.resetStatic();
    expect(await store.load(), const <PendingTrackMove>[_move, later]);
  });

  test('nothing pending leaves no record at all', () async {
    await store.save(const <PendingTrackMove>[_move]);
    await store.save(const <PendingTrackMove>[]);

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('pending_track_moves_v1'), isFalse);
    expect(await store.load(), isEmpty);
  });

  test('an entry that cannot be read drops only itself', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'pending_track_moves_v1': '[{"f": "/a", "t": "/b", "s": ["playlists"]},'
          '{"f": 3, "t": "/c", "s": ["playlists"]},'
          '{"f": "/d", "t": "/d", "s": ["playlists"]},'
          '{"f": "/e", "t": "/f", "s": []},'
          '"junk"]',
    });

    expect(await store.load(), const <PendingTrackMove>[
      PendingTrackMove(from: '/a', to: '/b', targets: <String>{'playlists'}),
    ]);
  });

  group('on a full disk', () {
    setUp(() {
      SharedPreferencesStorePlatform.instance = _FullDisk();
      SharedPreferences.resetStatic();
    });
    tearDown(() {
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.empty();
      SharedPreferences.resetStatic();
    });

    test('a kept move that was not saved says so', () async {
      await expectLater(
        store.save(const <PendingTrackMove>[_move]),
        throwsA(isA<LocalStoreWriteException>()),
      );
      await expectLater(
        store.save(const <PendingTrackMove>[]),
        throwsA(isA<LocalStoreWriteException>()),
      );
    });

    test('an "added on" time that was not saved says so', () async {
      await expectLater(
        const SharedPreferencesLibraryAddedStore().save(<String, DateTime>{
          '/music/a.flac': DateTime.utc(2021),
        }),
        throwsA(
          isA<LocalStoreWriteException>().having(
            (LocalStoreWriteException e) => e.area,
            'area',
            LocalStoreArea.libraryAdded,
          ),
        ),
      );
    });
  });
}
