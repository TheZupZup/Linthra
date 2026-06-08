import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/default_provider_store_provider.dart';
import 'package:linthra/data/repositories/in_memory_default_provider_store.dart';
import 'package:linthra/features/library/source_preference_controller.dart';
import 'package:linthra/features/settings/source/default_provider_section.dart';

void main() {
  group('DefaultProviderSettingsSection', () {
    late InMemoryDefaultProviderStore store;

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      String? initial,
    }) async {
      store = InMemoryDefaultProviderStore(initial);
      final container = ProviderContainer(
        overrides: <Override>[
          defaultProviderStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: DefaultProviderSettingsSection()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('shows the default-source options', (tester) async {
      await pump(tester);

      expect(find.text('Default source'), findsOneWidget);
      expect(find.text('Automatic'), findsOneWidget);
      expect(find.text('Jellyfin'), findsOneWidget);
      expect(find.text('Navidrome / Subsonic'), findsOneWidget);
      expect(find.text('Local files'), findsOneWidget);
    });

    testWidgets('defaults to Automatic', (tester) async {
      final container = await pump(tester);
      expect(container.read(defaultProviderControllerProvider), isNull);
    });

    testWidgets('choosing a provider persists it and pins it to the head',
        (tester) async {
      final container = await pump(tester);

      await tester.tap(find.text('Jellyfin'));
      await tester.pumpAndSettle();

      expect(container.read(defaultProviderControllerProvider), 'jellyfin');
      expect(await store.read(), 'jellyfin');
      expect(
        container.read(librarySourcePriorityProvider).preferredOrder.first,
        'jellyfin',
      );
    });

    testWidgets('reflects a persisted choice', (tester) async {
      final container = await pump(tester, initial: 'subsonic');

      expect(container.read(defaultProviderControllerProvider), 'subsonic');
      final RadioListTile<String?> tile = tester.widget(
        find.byWidgetPredicate(
          (Widget w) => w is RadioListTile<String?> && w.value == 'subsonic',
        ),
      );
      expect(tile.groupValue, 'subsonic');
    });
  });
}
