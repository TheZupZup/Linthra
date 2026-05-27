import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/shared_preferences_library_added_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SharedPreferencesLibraryAddedStore', () {
    test('round-trips first-seen timestamps', () async {
      const SharedPreferencesLibraryAddedStore store =
          SharedPreferencesLibraryAddedStore();
      final Map<String, DateTime> addedAt = <String, DateTime>{
        'a': DateTime(2024, 3, 1),
        'b': DateTime(2024, 3, 2),
      };

      await store.save(addedAt);
      final Map<String, DateTime> loaded = await store.load();

      expect(loaded['a'], DateTime(2024, 3, 1));
      expect(loaded['b'], DateTime(2024, 3, 2));
    });

    test('returns empty for no stored value', () async {
      const SharedPreferencesLibraryAddedStore store =
          SharedPreferencesLibraryAddedStore();
      expect(await store.load(), isEmpty);
    });

    test('a corrupt record reads as nothing recorded', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'library_added_v1': 'not json {',
      });
      const SharedPreferencesLibraryAddedStore store =
          SharedPreferencesLibraryAddedStore();
      expect(await store.load(), isEmpty);
    });

    test('stores only ids and timestamps — never a track uri', () async {
      const SharedPreferencesLibraryAddedStore store =
          SharedPreferencesLibraryAddedStore();
      await store.save(<String, DateTime>{'track-1': DateTime(2024, 1, 1)});

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String raw = prefs.getString('library_added_v1') ?? '';
      expect(raw, contains('track-1'));
      expect(raw, isNot(contains('http')));
      expect(raw, isNot(contains('jellyfin:')));
    });
  });
}
