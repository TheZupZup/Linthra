import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/in_memory_playback_source_strategy_store.dart';
import 'package:linthra/data/repositories/shared_preferences_playback_source_strategy_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InMemoryPlaybackSourceStrategyStore', () {
    test('defaults to null (the default strategy) and round-trips', () async {
      final store = InMemoryPlaybackSourceStrategyStore();
      expect(await store.read(), isNull);

      await store.write('preferLocalCache');
      expect(await store.read(), 'preferLocalCache');

      await store.write(null);
      expect(await store.read(), isNull);
    });

    test('honours an initial value', () async {
      final store = InMemoryPlaybackSourceStrategyStore('preferLowerData');
      expect(await store.read(), 'preferLowerData');
    });
  });

  group('SharedPreferencesPlaybackSourceStrategyStore', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('reads null (the default) when nothing is stored', () async {
      expect(
        await const SharedPreferencesPlaybackSourceStrategyStore().read(),
        isNull,
      );
    });

    test('round-trips the choice across separate instances', () async {
      await const SharedPreferencesPlaybackSourceStrategyStore()
          .write('automaticBalanced');

      expect(
        await const SharedPreferencesPlaybackSourceStrategyStore().read(),
        'automaticBalanced',
      );
    });

    test('writing null clears a stored choice', () async {
      await const SharedPreferencesPlaybackSourceStrategyStore()
          .write('preferHighestQuality');
      await const SharedPreferencesPlaybackSourceStrategyStore().write(null);

      expect(
        await const SharedPreferencesPlaybackSourceStrategyStore().read(),
        isNull,
      );
    });
  });
}
