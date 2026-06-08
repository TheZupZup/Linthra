import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/shared_preferences_preferred_source_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('SharedPreferencesPreferredSourceStore', () {
    test('reads an empty order when nothing is stored', () async {
      expect(await SharedPreferencesPreferredSourceStore().read(), isEmpty);
    });

    test('round-trips the order across separate instances', () async {
      await SharedPreferencesPreferredSourceStore()
          .write(<String>['subsonic', 'jellyfin', 'local']);

      expect(
        await SharedPreferencesPreferredSourceStore().read(),
        <String>['subsonic', 'jellyfin', 'local'],
      );
    });

    test('a corrupt value reads as no preference rather than throwing',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'preferred_source_order_v1': 'not-json',
      });
      expect(await SharedPreferencesPreferredSourceStore().read(), isEmpty);
    });
  });
}
