import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/app_icon_variant_store_provider.dart';
import 'package:linthra/data/repositories/in_memory_app_icon_variant_store.dart';
import 'package:linthra/features/appearance/app_icon_controller.dart';
import 'package:linthra/features/appearance/app_icon_variant.dart';
import 'package:linthra/features/appearance/appearance_settings_screen.dart';
import 'package:linthra/features/settings/hub/about_screen.dart';
import 'package:linthra/features/appearance/linthra_logo_mark.dart';

void main() {
  group('AppearanceSettingsScreen', () {
    late InMemoryAppIconVariantStore store;

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      String? initial,
    }) async {
      store = InMemoryAppIconVariantStore(initial);
      // A tall surface so the whole variant grid lays out and every tile is
      // hittable.
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          appIconVariantStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: AppearanceSettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('lists every built-in variant', (tester) async {
      await pump(tester);
      for (final AppIconVariant variant in AppIconVariants.all) {
        expect(
          find.text(variant.label),
          findsOneWidget,
          reason: '${variant.label} tile should render',
        );
      }
    });

    testWidgets('defaults to Classic', (tester) async {
      final ProviderContainer container = await pump(tester);
      expect(
        container.read(appIconControllerProvider),
        AppIconVariants.classic,
      );
    });

    testWidgets('tapping a variant selects and persists it', (tester) async {
      final ProviderContainer container = await pump(tester);

      await tester.tap(find.text('Neon'));
      await tester.pumpAndSettle();

      expect(container.read(appIconControllerProvider), AppIconVariants.neon);
      expect(await store.read(), 'neon');
    });

    testWidgets('the gold variant is selectable with no "Preview" badge',
        (tester) async {
      final ProviderContainer container = await pump(tester);

      // Gold is a free variant now — no Preview badge appears anywhere.
      expect(find.text('Preview'), findsNothing);

      await tester.tap(find.text('Gold'));
      await tester.pumpAndSettle();

      expect(container.read(appIconControllerProvider), AppIconVariants.gold);
      expect(await store.read(), 'gold');
    });

    testWidgets('shows no premium / locking / purchase wording',
        (tester) async {
      await pump(tester);

      final Iterable<String> texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((Text t) => (t.data ?? '').toLowerCase());
      const List<String> forbidden = <String>[
        'premium',
        'locked',
        'unlock',
        'upgrade',
        'buy',
        'supporter-only',
        'supporter only',
      ];
      for (final String word in forbidden) {
        expect(
          texts.any((String s) => s.contains(word)),
          isFalse,
          reason: '"$word" must not appear in the default build',
        );
      }
    });
  });

  group('Selected branding in About', () {
    testWidgets('About renders the mark in the selected variant',
        (tester) async {
      final InMemoryAppIconVariantStore store =
          InMemoryAppIconVariantStore('neon');
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appIconVariantStoreProvider.overrideWithValue(store),
          ],
          child: const MaterialApp(home: AboutScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final LinthraLogoMark mark =
          tester.widget<LinthraLogoMark>(find.byType(LinthraLogoMark));
      expect(mark.gradient, AppIconVariants.neon.gradient);
      expect(mark.bars, AppIconVariants.neon.bars);
    });
  });
}
