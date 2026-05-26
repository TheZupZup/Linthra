import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/features/settings/network/network_settings_section.dart';

void main() {
  group('NetworkSettingsSection', () {
    late InMemoryDownloadPreferences preferences;

    Future<ProviderContainer> pump(WidgetTester tester) async {
      final container = ProviderContainer(
        overrides: [
          downloadPreferencesProvider.overrideWithValue(preferences),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: NetworkSettingsSection()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    setUp(() => preferences = InMemoryDownloadPreferences());

    testWidgets('shows the toggle off by default with helper text',
        (tester) async {
      await pump(tester);

      expect(find.text('Downloads & network'), findsOneWidget);
      expect(
        find.text('Allow mobile data for downloads'),
        findsOneWidget,
      );
      expect(find.textContaining('may use a lot of data'), findsOneWidget);
      final SwitchListTile tile =
          tester.widget(find.byType(SwitchListTile));
      expect(tile.value, isFalse);
    });

    testWidgets('enabling asks for confirmation and persists when allowed',
        (tester) async {
      await pump(tester);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      // The confirmation dialog appears before anything is persisted.
      expect(find.text('Use mobile data for downloads?'), findsOneWidget);
      expect(await preferences.allowMobileData(), isFalse);

      await tester.tap(find.text('Allow mobile data'));
      await tester.pumpAndSettle();

      expect(await preferences.allowMobileData(), isTrue);
      final SwitchListTile tile =
          tester.widget(find.byType(SwitchListTile));
      expect(tile.value, isTrue);
    });

    testWidgets('cancelling the confirmation leaves the toggle off',
        (tester) async {
      await pump(tester);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(await preferences.allowMobileData(), isFalse);
      final SwitchListTile tile =
          tester.widget(find.byType(SwitchListTile));
      expect(tile.value, isFalse);
    });

    testWidgets('turning it off applies immediately without a dialog',
        (tester) async {
      preferences = InMemoryDownloadPreferences(allowMobileData: true);
      await pump(tester);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      // No confirmation when turning the switch off.
      expect(find.text('Use mobile data for downloads?'), findsNothing);
      expect(await preferences.allowMobileData(), isFalse);
    });
  });
}
