import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/in_memory_default_provider_store.dart';
import 'package:linthra/data/repositories/shared_preferences_default_provider_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InMemoryDefaultProviderStore', () {
    test('defaults to Automatic (null) and round-trips', () async {
      final store = InMemoryDefaultProviderStore();
      expect(await store.read(), isNull);

      await store.write('jellyfin');
      expect(await store.read(), 'jellyfin');

      await store.write(null);
      expect(await store.read(), isNull);
    });

    test('honours an initial value', () async {
      final store = InMemoryDefaultProviderStore('subsonic');
      expect(await store.read(), 'subsonic');
    });
  });

  group('SharedPreferencesDefaultProviderStore', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('reads Automatic (null) when nothing is stored', () async {
      expect(
        await const SharedPreferencesDefaultProviderStore().read(),
        isNull,
      );
    });

    test('round-trips the choice across separate instances', () async {
      await const SharedPreferencesDefaultProviderStore().write('subsonic');

      expect(
        await const SharedPreferencesDefaultProviderStore().read(),
        'subsonic',
      );
    });

    test('writing null clears a stored choice', () async {
      await const SharedPreferencesDefaultProviderStore().write('jellyfin');
      await const SharedPreferencesDefaultProviderStore().write(null);

      expect(
        await const SharedPreferencesDefaultProviderStore().read(),
        isNull,
      );
    });
  });
}
