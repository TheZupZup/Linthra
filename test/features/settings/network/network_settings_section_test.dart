import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/repositories/download_preferences.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/features/settings/network/network_settings_section.dart';

import '../../downloads/fake_download_repository.dart';

void main() {
  group('NetworkSettingsSection', () {
    late InMemoryDownloadPreferences preferences;
    late FakeDownloadRepository downloads;

    Future<void> pump(WidgetTester tester, {TargetPlatform? platform}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            downloadPreferencesProvider.overrideWithValue(preferences),
            downloadRepositoryProvider.overrideWithValue(downloads),
          ],
          child: MaterialApp(
            theme: platform == null ? null : ThemeData(platform: platform),
            home: const Scaffold(body: NetworkSettingsSection()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    setUp(() {
      preferences = InMemoryDownloadPreferences();
      downloads = FakeDownloadRepository();
    });

    testWidgets('a new choice asks again for downloads held for the network',
        (tester) async {
      // Downloads queued because mobile data wasn't allowed may run now.
      await pump(tester);

      await tester.tap(find.text('Mobile data usage'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unlimited plan'));
      await tester.pumpAndSettle();

      expect(downloads.retryHeldCount, 1);
    });

    testWidgets('cancelling the dialog asks for nothing', (tester) async {
      await pump(tester);

      await tester.tap(find.text('Mobile data usage'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(downloads.retryHeldCount, 0);
    });

    testWidgets('a desktop names it for metered connections', (tester) async {
      // A desktop has no mobile data plan; what it meets is a connection the
      // system marks as metered, like a phone hotspot.
      await pump(tester, platform: TargetPlatform.linux);

      expect(find.text('Metered connections'), findsOneWidget);
      expect(find.text('Downloads on metered connections'), findsOneWidget);
      expect(find.text('Unmetered only'), findsOneWidget);
      expect(find.textContaining('mobile data'), findsNothing);
      expect(find.textContaining('Mobile data'), findsNothing);
    });

    testWidgets('a desktop offers the same three choices in its own words',
        (tester) async {
      await pump(tester, platform: TargetPlatform.linux);

      await tester.tap(find.text('Downloads on metered connections'));
      await tester.pumpAndSettle();
      expect(find.text('Unmetered only'), findsNWidgets(2));
      expect(find.text('Save data'), findsOneWidget);
      await tester.tap(find.text('Unlimited'));
      await tester.pumpAndSettle();

      expect(
        await preferences.mobileDataProfile(),
        MobileDataProfile.unlimited,
      );
      expect(
        find.text(
            'Downloads and smart pre-cache may use a metered connection.'),
        findsOneWidget,
      );
      expect(downloads.retryHeldCount, 1);
    });

    testWidgets('shows Wi-Fi only as the safe default', (tester) async {
      await pump(tester);

      expect(find.text('Wi-Fi & mobile data'), findsOneWidget);
      expect(find.text('Mobile data usage'), findsOneWidget);
      expect(find.text('Wi-Fi only'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsNothing);
      expect(
        await preferences.mobileDataProfile(),
        MobileDataProfile.wifiOnly,
      );
    });

    testWidgets('opens the three mobile-data choices', (tester) async {
      await pump(tester);

      await tester.tap(find.text('Mobile data usage'));
      await tester.pumpAndSettle();

      expect(find.text('Wi-Fi only'), findsNWidgets(2));
      expect(find.text('Save data'), findsOneWidget);
      expect(find.text('Unlimited plan'), findsOneWidget);
    });

    testWidgets(
      'save-data choice persists and updates the tile',
      (tester) async {
        await pump(tester);

        await tester.tap(find.text('Mobile data usage'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save data'));
        await tester.pumpAndSettle();

        expect(
          await preferences.mobileDataProfile(),
          MobileDataProfile.saveData,
        );
        expect(find.text('Save data'), findsOneWidget);
        expect(
          find.textContaining('Smart pre-cache is paused'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'unlimited choice permits full metered-network use',
      (tester) async {
        await pump(tester);

        await tester.tap(find.text('Mobile data usage'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Unlimited plan'));
        await tester.pumpAndSettle();

        expect(
          await preferences.mobileDataProfile(),
          MobileDataProfile.unlimited,
        );
        expect(find.text('Unlimited plan'), findsOneWidget);
        expect(
          find.textContaining('smart pre-cache may use mobile data'),
          findsOneWidget,
        );
      },
    );

    testWidgets('cancel keeps the existing choice', (tester) async {
      preferences = InMemoryDownloadPreferences(
        mobileDataProfile: MobileDataProfile.saveData,
      );
      await pump(tester);

      await tester.tap(find.text('Mobile data usage'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(
        await preferences.mobileDataProfile(),
        MobileDataProfile.saveData,
      );
      expect(find.text('Save data'), findsOneWidget);
    });
  });
}
