import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/repositories/local_store_write_exception.dart';
import 'package:linthra/core/repositories/pending_track_move_store.dart';
import 'package:linthra/data/repositories/shared_preferences_library_added_store.dart';
import 'package:linthra/data/repositories/shared_preferences_pending_track_move_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// Preferences that save but refuse to remove anything.
class _NoRemoving extends InMemorySharedPreferencesStore {
  _NoRemoving(super.data) : super.withData();

  @override
  Future<bool> remove(String key) async => false;
}

class _FullDisk extends InMemorySharedPreferencesStore {
  _FullDisk() : super.empty();
  _FullDisk.holding(super.data) : super.withData();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;

  @override
  Future<bool> remove(String key) async => false;
}

/// Preferences the platform fails to hand over at all.
class _UnreadableDisk extends InMemorySharedPreferencesStore {
  _UnreadableDisk() : super.empty();

  @override
  Future<Map<String, Object>> getAll() async => throw StateError('io');

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async =>
      throw StateError('io');
}

const PendingTrackMoveJournalFault _corrupt =
    PendingTrackMoveJournalFault.corrupt;
const PendingTrackMoveJournalFault _readFailed =
    PendingTrackMoveJournalFault.readFailed;

Matcher _unreadable(PendingTrackMoveJournalFault fault) =>
    isA<PendingTrackMoveJournalUnreadable>().having(
      (PendingTrackMoveJournalUnreadable e) => e.fault,
      'fault',
      fault,
    );

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

  test('no record at all is nothing pending', () async {
    expect(await store.load(), isEmpty);
  });

  test('an empty list is nothing pending too', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'pending_track_moves_v1': '[]',
    });

    expect(await store.load(), isEmpty);
  });

  test('nothing pending leaves no record at all', () async {
    await store.save(const <PendingTrackMove>[_move]);
    await store.save(const <PendingTrackMove>[]);

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('pending_track_moves_v1'), isFalse);
    expect(await store.load(), isEmpty);
  });

  group('a record that cannot be read is never taken for an empty one', () {
    const Map<String, String> broken = <String, String>{
      'not JSON': '{this is broken',
      'cut short': '[{"f":"/a","t":"/b"',
      'empty': '',
      'not a list': '{"f": "/a", "t": "/b", "s": ["playlists"]}',
      'a bad entry among good ones':
          '[{"f": "/a", "t": "/b", "s": ["playlists"]},'
              '{"garbage": true},'
              '{"f": "/c", "t": "/d", "s": ["favorites"]}]',
      'an entry with no stores': '[{"f": "/a", "t": "/b", "s": []}]',
      'an entry that moves nowhere': '[{"f": "/a", "t": "/a", "s": ["x"]}]',
      'an entry with a number for a path': '[{"f": 3, "t": "/b", "s": ["x"]}]',
      'an entry with a blank store': '[{"f": "/a", "t": "/b", "s": [""]}]',
      'an entry that is not an object': '["junk"]',
    };
    for (final MapEntry<String, String> record in broken.entries) {
      test(record.key, () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'pending_track_moves_v1': record.value,
        });

        await expectLater(store.load(), throwsA(_unreadable(_corrupt)));

        // Left exactly as it was found.
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('pending_track_moves_v1'), record.value);
      });
    }

    test('a value of another type', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'pending_track_moves_v1': 42,
      });

      await expectLater(store.load(), throwsA(_unreadable(_corrupt)));
    });

    test('preferences the platform cannot read', () async {
      SharedPreferencesStorePlatform.instance = _UnreadableDisk();
      SharedPreferences.resetStatic();
      addTearDown(() {
        SharedPreferencesStorePlatform.instance =
            InMemorySharedPreferencesStore.empty();
        SharedPreferences.resetStatic();
      });

      await expectLater(store.load(), throwsA(_unreadable(_readFailed)));
    });
  });

  group('a record that cannot be read is set aside', () {
    Future<Map<String, Object?>> onDisk() async {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return <String, Object?>{
        'record': prefs.get('pending_track_moves_v1'),
        'aside': prefs.get('pending_track_moves_v1_unreadable'),
      };
    }

    for (final Object broken in <Object>[
      '{this is broken',
      '[{"f":"/a","t":"/b"',
      '[{"f": "/a", "t": "/b", "s": ["playlists"]}, {"garbage": true}]',
      42,
    ]) {
      test('exactly as it is ($broken), leaving room for a new one', () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'pending_track_moves_v1': broken,
        });

        expect(await store.setAside(), isTrue);

        expect(await onDisk(), <String, Object?>{
          'record': null,
          'aside': broken,
        });
        expect(await store.load(), isEmpty);
      });
    }

    test('never over one set aside before', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'pending_track_moves_v1': '{this is broken',
        'pending_track_moves_v1_unreadable': 'older',
      });

      expect(await store.setAside(), isFalse);

      expect(await onDisk(), <String, Object?>{
        'record': '{this is broken',
        'aside': 'older',
      });
    });

    test('again, after a try that copied it but could not clear it', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'pending_track_moves_v1': '{this is broken',
        'pending_track_moves_v1_unreadable': '{this is broken',
      });

      expect(await store.setAside(), isTrue);
      expect(await onDisk(), <String, Object?>{
        'record': null,
        'aside': '{this is broken',
      });
    });

    test('and, when it cannot be cleared, is still there to be found',
        () async {
      SharedPreferencesStorePlatform.instance = _NoRemoving(
        <String, Object>{'flutter.pending_track_moves_v1': '{this is broken'},
      );
      SharedPreferences.resetStatic();
      addTearDown(() {
        SharedPreferencesStorePlatform.instance =
            InMemorySharedPreferencesStore.empty();
        SharedPreferences.resetStatic();
      });

      expect(await store.setAside(), isFalse);

      // Not "nothing pending" for the rest of this run either.
      await expectLater(store.load(), throwsA(_unreadable(_corrupt)));
      SharedPreferences.resetStatic();
      await expectLater(store.load(), throwsA(_unreadable(_corrupt)));
    });

    test('but never one that reads fine', () async {
      await store.save(const <PendingTrackMove>[_move]);

      expect(await store.setAside(), isFalse);
      expect(await store.load(), const <PendingTrackMove>[_move]);
    });
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

    test('a refused save leaves what was saved before, also in memory',
        () async {
      SharedPreferencesStorePlatform.instance = _FullDisk.holding(
        <String, Object>{
          'flutter.pending_track_moves_v1':
              '[{"f": "/a", "t": "/b", "s": ["playlists"]}]',
        },
      );
      SharedPreferences.resetStatic();
      const List<PendingTrackMove> before = <PendingTrackMove>[
        PendingTrackMove(from: '/a', to: '/b', targets: <String>{'playlists'}),
      ];

      await expectLater(
        store.save(const <PendingTrackMove>[_move]),
        throwsA(isA<LocalStoreWriteException>()),
      );
      expect(await store.load(), before);

      await expectLater(
        store.save(const <PendingTrackMove>[]),
        throwsA(isA<LocalStoreWriteException>()),
      );
      expect(await store.load(), before);
    });

    test('a broken record is left where it is', () async {
      SharedPreferencesStorePlatform.instance = _FullDisk.holding(
        <String, Object>{'flutter.pending_track_moves_v1': '{this is broken'},
      );
      SharedPreferences.resetStatic();

      expect(await store.setAside(), isFalse);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.get('pending_track_moves_v1'), '{this is broken');
      expect(prefs.get('pending_track_moves_v1_unreadable'), isNull);
    });

    test('an "added on" save refused leaves the times saved before', () async {
      SharedPreferencesStorePlatform.instance = _FullDisk.holding(
        <String, Object>{'flutter.library_added_v1': '{"/a.flac": 1000}'},
      );
      SharedPreferences.resetStatic();
      const SharedPreferencesLibraryAddedStore added =
          SharedPreferencesLibraryAddedStore();

      await expectLater(
        added.save(<String, DateTime>{'/b.flac': DateTime.utc(2026)}),
        throwsA(isA<LocalStoreWriteException>()),
      );

      expect(
        (await added.load()).keys,
        <String>['/a.flac'],
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
