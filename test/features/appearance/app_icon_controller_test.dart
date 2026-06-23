import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/app_icon_variant_store_provider.dart';
import 'package:linthra/data/repositories/in_memory_app_icon_variant_store.dart';
import 'package:linthra/features/appearance/app_icon_controller.dart';
import 'package:linthra/features/appearance/app_icon_variant.dart';
import 'package:linthra/features/support/support_actions_provider.dart';

void main() {
  group('AppIconController', () {
    late InMemoryAppIconVariantStore store;

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      String? initial,
    }) async {
      store = InMemoryAppIconVariantStore(initial);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          appIconVariantStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      // A trivial consumer instantiates the controller so its one-shot load runs.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Consumer(
            builder: (_, WidgetRef ref, __) {
              ref.watch(appIconControllerProvider);
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('defaults to Classic with no stored choice', (tester) async {
      final ProviderContainer container = await pump(tester);
      expect(
        container.read(appIconControllerProvider),
        AppIconVariants.classic,
      );
    });

    testWidgets('loads a persisted variant', (tester) async {
      final ProviderContainer container = await pump(tester, initial: 'neon');
      expect(container.read(appIconControllerProvider), AppIconVariants.neon);
    });

    testWidgets('falls back to Classic for an unknown persisted id',
        (tester) async {
      final ProviderContainer container =
          await pump(tester, initial: 'totally-bogus');
      expect(
        container.read(appIconControllerProvider),
        AppIconVariants.classic,
      );
    });

    testWidgets('selecting a variant updates state and persists it',
        (tester) async {
      final ProviderContainer container = await pump(tester);

      await container
          .read(appIconControllerProvider.notifier)
          .select(AppIconVariants.waveform);
      await tester.pumpAndSettle();

      expect(
        container.read(appIconControllerProvider),
        AppIconVariants.waveform,
      );
      expect(await store.read(), 'waveform');
    });

    testWidgets('the cosmetic supporter (gold) variant is selectable here',
        (tester) async {
      final ProviderContainer container = await pump(tester);

      await container
          .read(appIconControllerProvider.notifier)
          .select(AppIconVariants.gold);
      await tester.pumpAndSettle();

      // No gate in the default build: choosing the supporter-tier style works
      // and persists exactly like any free one.
      expect(container.read(appIconControllerProvider), AppIconVariants.gold);
      expect(await store.read(), 'gold');
    });
  });

  group('appIconVariantsFor', () {
    test('offers every variant on every channel — F-Droid included', () {
      for (final SupportDistribution distribution
          in SupportDistribution.values) {
        expect(
          appIconVariantsFor(distribution),
          AppIconVariants.all,
          reason: 'all variants must be available on $distribution',
        );
        // The cosmetic supporter style is offered, never withheld.
        expect(
          appIconVariantsFor(distribution),
          contains(AppIconVariants.gold),
        );
      }
    });
  });
}
