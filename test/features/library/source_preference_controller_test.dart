import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/source_priority.dart';
import 'package:linthra/data/repositories/in_memory_preferred_source_store.dart';
import 'package:linthra/data/repositories/preferred_source_store_provider.dart';
import 'package:linthra/features/library/source_preference_controller.dart';

ProviderContainer _container(InMemoryPreferredSourceStore store) {
  final container = ProviderContainer(
    overrides: <Override>[
      preferredSourceStoreProvider.overrideWithValue(store),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('SourcePreferenceController', () {
    test('starts at the deterministic fallback default', () {
      final container = _container(InMemoryPreferredSourceStore());
      expect(container.read(librarySourcePriorityProvider),
          SourcePriority.fallback);
    });

    test('loads a persisted order at startup', () async {
      final container = _container(
        InMemoryPreferredSourceStore(<String>['subsonic', 'jellyfin']),
      );
      // Build the controller, then let its fire-and-forget load settle.
      container.read(librarySourcePriorityProvider);
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(librarySourcePriorityProvider).preferredOrder,
        <String>['subsonic', 'jellyfin'],
      );
    });

    test('markPreferred promotes the server and persists it', () async {
      final store = InMemoryPreferredSourceStore();
      final container = _container(store);

      await container
          .read(librarySourcePriorityProvider.notifier)
          .markPreferred('subsonic');

      expect(
        container.read(librarySourcePriorityProvider).preferredOrder.first,
        'subsonic',
      );
      expect(await store.read(), <String>['subsonic']);
    });

    test('the most recent sign-in wins', () async {
      final container = _container(InMemoryPreferredSourceStore());
      final controller = container.read(librarySourcePriorityProvider.notifier);

      await controller.markPreferred('jellyfin');
      await controller.markPreferred('subsonic');

      expect(
        container.read(librarySourcePriorityProvider).preferredOrder,
        <String>['subsonic', 'jellyfin'],
      );
    });
  });
}
