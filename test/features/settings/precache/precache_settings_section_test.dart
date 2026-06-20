import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/repositories/download_preferences.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/features/downloads/download_providers.dart';
import 'package:linthra/features/settings/precache/precache_settings_section.dart';

void main() {
  group('PrecacheSettingsSection', () {
    late InMemoryDownloadPreferences preferences;

    Future<ProviderContainer> pump(WidgetTester tester) async {
      preferences = InMemoryDownloadPreferences();
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
            home: Scaffold(body: PrecacheSettingsSection()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('shows the smart pre-cache copy and the current count',
        (tester) async {
      await pump(tester);

      expect(find.text('Smart pre-cache'), findsOneWidget);
      expect(find.text('Pre-cache upcoming tracks'), findsOneWidget);
      expect(find.text('Songs to pre-cache'), findsOneWidget);
      // The automatic/evictable vs. Keep offline (protected) distinction.
      expect(find.textContaining('removed automatically'), findsWidgets);
      expect(find.textContaining('Keep offline'), findsOneWidget);
      // The default count (3) is shown, and there's a control to change it.
      expect(find.text('3 upcoming tracks'), findsOneWidget);
      expect(find.text('Change'), findsOneWidget);
    });

    testWidgets('toggling smart pre-cache off persists the choice',
        (tester) async {
      final container = await pump(tester);
      expect(await preferences.preloadEnabled(), isTrue);

      await tester.tap(find.text('Pre-cache upcoming tracks'));
      await tester.pumpAndSettle();

      expect(await preferences.preloadEnabled(), isFalse);
      expect(container.read(smartPrecacheEnabledProvider).valueOrNull, isFalse);
    });

    testWidgets('the dialog offers all presets including the new larger ones',
        (tester) async {
      await pump(tester);

      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();

      for (final int option in kPrecacheCountOptions) {
        expect(find.text('$option'), findsOneWidget);
      }
      // The larger options the user asked for are present.
      expect(find.text('20'), findsOneWidget);
      expect(find.text('50'), findsOneWidget);
      expect(find.text('Custom'), findsOneWidget);
    });

    testWidgets('choosing a larger preset (50) persists the new value',
        (tester) async {
      final container = await pump(tester);
      expect(await preferences.precacheCount(), kDefaultPrecacheCount);

      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('50'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(await preferences.precacheCount(), 50);
      expect(container.read(precacheCountProvider).valueOrNull, 50);
    });

    testWidgets('entering a custom value persists it', (tester) async {
      final container = await pump(tester);

      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '42');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(await preferences.precacheCount(), 42);
      expect(container.read(precacheCountProvider).valueOrNull, 42);
    });

    testWidgets('an out-of-range custom value is clamped to the max on save',
        (tester) async {
      await pump(tester);

      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '9999');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Never thousands of downloads: capped at the safe maximum.
      expect(await preferences.precacheCount(), kMaxPrecacheCount);
    });

    testWidgets('the Change button is disabled while pre-cache is off',
        (tester) async {
      await pump(tester);

      // Turn smart pre-cache off, then try to open the picker.
      await tester.tap(find.text('Pre-cache upcoming tracks'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();

      // No dialog opened (no Save action), and the count is unchanged.
      expect(find.text('Save'), findsNothing);
      expect(await preferences.precacheCount(), kDefaultPrecacheCount);
    });
  });
}
