import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/shared_preferences_library_song_sort_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SharedPreferencesLibrarySongSortStore', () {
    const SharedPreferencesLibrarySongSortStore store =
        SharedPreferencesLibrarySongSortStore();

    test('round-trips the order name', () async {
      await store.write('newestAdded');

      expect(await store.read(), 'newestAdded');
    });

    test('reads nothing when nothing was stored', () async {
      expect(await store.read(), isNull);
    });

    test('an empty stored value reads as no choice', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'library_song_sort_v1': '',
      });

      expect(await store.read(), isNull);
    });

    test('writing null clears the choice', () async {
      await store.write('albumDescending');
      await store.write(null);

      expect(await store.read(), isNull);
    });
  });
}
