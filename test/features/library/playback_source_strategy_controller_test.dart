import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/source_strategy.dart';
import 'package:linthra/data/repositories/in_memory_playback_source_strategy_store.dart';
import 'package:linthra/data/repositories/playback_source_strategy_store_provider.dart';
import 'package:linthra/features/library/playback_source_strategy_controller.dart';

ProviderContainer _container(InMemoryPlaybackSourceStrategyStore store) {
  final container = ProviderContainer(
    overrides: <Override>[
      playbackSourceStrategyStoreProvider.overrideWithValue(store),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('PlaybackSourceStrategyController', () {
    test('defaults to preferDefault before the async load lands', () {
      final container = _container(InMemoryPlaybackSourceStrategyStore());
      expect(container.read(playbackSourceStrategyProvider),
          PlaybackSourceStrategy.preferDefault);
    });

    test('loads a persisted strategy', () async {
      final container =
          _container(InMemoryPlaybackSourceStrategyStore('preferLowerData'));
      // Reading starts build() + the async load.
      container.read(playbackSourceStrategyProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(playbackSourceStrategyProvider),
          PlaybackSourceStrategy.preferLowerData);
    });

    test('an unrecognised stored value falls back to the default', () async {
      final container =
          _container(InMemoryPlaybackSourceStrategyStore('garbage'));
      container.read(playbackSourceStrategyProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(playbackSourceStrategyProvider),
          PlaybackSourceStrategy.preferDefault);
    });

    test('setStrategy updates state and persists the enum name', () async {
      final store = InMemoryPlaybackSourceStrategyStore();
      final container = _container(store);

      await container
          .read(playbackSourceStrategyProvider.notifier)
          .setStrategy(PlaybackSourceStrategy.preferHighestQuality);

      expect(container.read(playbackSourceStrategyProvider),
          PlaybackSourceStrategy.preferHighestQuality);
      expect(await store.read(), 'preferHighestQuality');
    });

    test('setStrategy to the current value is a no-op', () async {
      final store = InMemoryPlaybackSourceStrategyStore();
      final container = _container(store);

      await container
          .read(playbackSourceStrategyProvider.notifier)
          .setStrategy(PlaybackSourceStrategy.preferDefault);

      // Nothing persisted for the unchanged default.
      expect(await store.read(), isNull);
    });
  });
}
