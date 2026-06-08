import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/source_priority.dart';
import 'package:linthra/data/repositories/default_provider_store_provider.dart';
import 'package:linthra/data/repositories/in_memory_default_provider_store.dart';
import 'package:linthra/data/repositories/in_memory_preferred_source_store.dart';
import 'package:linthra/data/repositories/preferred_source_store_provider.dart';
import 'package:linthra/features/library/source_preference_controller.dart';

ProviderContainer _container({
  InMemoryPreferredSourceStore? preferred,
  InMemoryDefaultProviderStore? defaultProvider,
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      preferredSourceStoreProvider
          .overrideWithValue(preferred ?? InMemoryPreferredSourceStore()),
      defaultProviderStoreProvider
          .overrideWithValue(defaultProvider ?? InMemoryDefaultProviderStore()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('SourcePreferenceController (automatic order)', () {
    test('starts at the deterministic fallback default', () {
      final container = _container();
      expect(container.read(librarySourcePriorityProvider),
          SourcePriority.fallback);
    });

    test('loads a persisted order at startup', () async {
      final container = _container(
        preferred:
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
      final container = _container(preferred: store);

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
      final container = _container();
      final controller = container.read(librarySourcePriorityProvider.notifier);

      await controller.markPreferred('jellyfin');
      await controller.markPreferred('subsonic');

      expect(
        container.read(librarySourcePriorityProvider).preferredOrder,
        <String>['subsonic', 'jellyfin'],
      );
    });
  });

  group('SourcePreferenceController (explicit default)', () {
    test('an explicit default pins it to the head over the automatic order',
        () async {
      final container = _container(
        preferred: InMemoryPreferredSourceStore(<String>['jellyfin']),
      );
      // Establish the watch and let the automatic order load.
      container.read(librarySourcePriorityProvider);
      await Future<void>.delayed(Duration.zero);

      await container
          .read(defaultProviderControllerProvider.notifier)
          .setDefaultProvider('subsonic');

      expect(
        container.read(librarySourcePriorityProvider).preferredOrder,
        <String>['subsonic', 'jellyfin'],
      );
    });

    test('a sign-in does not override an explicit pin', () async {
      final container = _container();
      container.read(librarySourcePriorityProvider);

      await container
          .read(defaultProviderControllerProvider.notifier)
          .setDefaultProvider('jellyfin');
      await container
          .read(librarySourcePriorityProvider.notifier)
          .markPreferred('subsonic');

      final SourcePriority priority =
          container.read(librarySourcePriorityProvider);
      expect(priority.preferredOrder.first, 'jellyfin');
      expect(priority.preferredOrder, <String>['jellyfin', 'subsonic']);
    });

    test('switching back to Automatic restores the most-recent-sign-in order',
        () async {
      final container = _container();
      container.read(librarySourcePriorityProvider);
      final defaults =
          container.read(defaultProviderControllerProvider.notifier);

      await defaults.setDefaultProvider('jellyfin');
      await container
          .read(librarySourcePriorityProvider.notifier)
          .markPreferred('subsonic');
      await defaults.setDefaultProvider(null);

      expect(
        container.read(librarySourcePriorityProvider).preferredOrder,
        <String>['subsonic'],
      );
    });

    test('an explicit default with no automatic order still pins it', () async {
      final container = _container();

      await container
          .read(defaultProviderControllerProvider.notifier)
          .setDefaultProvider('local');

      expect(
        container.read(librarySourcePriorityProvider).preferredOrder,
        <String>['local'],
      );
    });

    test('a persisted explicit default is loaded and pinned at startup',
        () async {
      final container = _container(
        preferred: InMemoryPreferredSourceStore(<String>['jellyfin']),
        defaultProvider: InMemoryDefaultProviderStore('subsonic'),
      );
      container.read(librarySourcePriorityProvider);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(defaultProviderControllerProvider), 'subsonic');
      expect(
        container.read(librarySourcePriorityProvider).preferredOrder,
        <String>['subsonic', 'jellyfin'],
      );
    });
  });
}
