import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/launcher_icon_service.dart';
import 'package:linthra/data/repositories/app_icon_variant_store_provider.dart';
import 'package:linthra/data/repositories/in_memory_app_icon_variant_store.dart';
import 'package:linthra/data/repositories/launcher_icon_service_provider.dart';
import 'package:linthra/features/appearance/app_icon_controller.dart';
import 'package:linthra/features/appearance/app_icon_variant.dart';
import 'package:linthra/features/support/support_actions_provider.dart';
import 'package:linthra/features/support/supporter_entitlement.dart';

void main() {
  group('AppIconController', () {
    late InMemoryAppIconVariantStore store;
    late FakeLauncherIconService launcher;

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      String? initial,
      bool launcherThrows = false,
      SupporterEntitlement entitlement = SupporterEntitlement.included,
    }) async {
      store = InMemoryAppIconVariantStore(initial);
      launcher = FakeLauncherIconService(throws: launcherThrows);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          appIconVariantStoreProvider.overrideWithValue(store),
          launcherIconServiceProvider.overrideWithValue(launcher),
          supporterEntitlementProvider.overrideWithValue(entitlement),
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

      final bool selected = await container
          .read(appIconControllerProvider.notifier)
          .select(AppIconVariants.neon);
      await tester.pumpAndSettle();

      expect(selected, isTrue);
      expect(
        container.read(appIconControllerProvider),
        AppIconVariants.neon,
      );
      expect(await store.read(), 'neon');
    });

    testWidgets('supporter styles remain selectable when included',
        (tester) async {
      final ProviderContainer container = await pump(tester);

      final bool selected = await container
          .read(appIconControllerProvider.notifier)
          .select(AppIconVariants.gold);
      await tester.pumpAndSettle();

      expect(selected, isTrue);
      expect(container.read(appIconControllerProvider), AppIconVariants.gold);
      expect(await store.read(), 'gold');
    });

    testWidgets('locked supporter style is rejected without side effects',
        (tester) async {
      final ProviderContainer container = await pump(
        tester,
        entitlement: SupporterEntitlement.locked,
      );

      final bool selected = await container
          .read(appIconControllerProvider.notifier)
          .select(AppIconVariants.gold);
      await tester.pumpAndSettle();

      expect(selected, isFalse);
      expect(
        container.read(appIconControllerProvider),
        AppIconVariants.classic,
      );
      expect(await store.read(), isNull);
      expect(launcher.applied, isNot(contains('gold')));
    });

    testWidgets('locked persisted supporter style reconciles to Classic',
        (tester) async {
      final ProviderContainer container = await pump(
        tester,
        initial: 'gold',
        entitlement: SupporterEntitlement.locked,
      );

      expect(
        container.read(appIconControllerProvider),
        AppIconVariants.classic,
      );
      expect(await store.read(), 'classic');
      expect(launcher.applied, contains('classic'));
      expect(launcher.applied, isNot(contains('gold')));
    });

    testWidgets('selecting a variant switches the real launcher icon',
        (tester) async {
      final ProviderContainer container = await pump(tester);

      await container
          .read(appIconControllerProvider.notifier)
          .select(AppIconVariants.neon);
      await tester.pumpAndSettle();

      // The launcher icon was switched to the same variant that was selected.
      expect(launcher.applied.last, 'neon');
    });

    testWidgets('re-asserts the launcher icon for the stored choice on startup',
        (tester) async {
      // A cold start with a persisted choice must restore that launcher icon,
      // not just the in-app mark.
      await pump(tester, initial: 'neon');
      expect(launcher.applied, contains('neon'));
    });

    testWidgets('reconciles to Classic on startup with no stored choice',
        (tester) async {
      await pump(tester);
      expect(launcher.applied, contains('classic'));
    });

    testWidgets('a launcher-switch failure never breaks selection',
        (tester) async {
      final ProviderContainer container =
          await pump(tester, launcherThrows: true);

      // Even though every launcher call throws, selection still updates and
      // persists — launcher switching is strictly best-effort.
      await container
          .read(appIconControllerProvider.notifier)
          .select(AppIconVariants.gold);
      await tester.pumpAndSettle();

      expect(container.read(appIconControllerProvider), AppIconVariants.gold);
      expect(await store.read(), 'gold');
    });
  });

  group('appIconVariantsFor', () {
    test('displays every variant on every channel — F-Droid included', () {
      for (final SupportDistribution distribution
          in SupportDistribution.values) {
        expect(
          appIconVariantsFor(distribution),
          AppIconVariants.all,
          reason: 'all variants must be visible on $distribution',
        );
        expect(
          appIconVariantsFor(distribution),
          contains(AppIconVariants.gold),
        );
      }
    });
  });
}

/// Records the variant ids the controller asks to switch the launcher icon to,
/// and can be made to fail to prove switching is best-effort. Stands in for the
/// platform [LauncherIconService] so these tests stay free of method channels.
class FakeLauncherIconService implements LauncherIconService {
  FakeLauncherIconService({this.throws = false});

  final bool throws;
  final List<String> applied = <String>[];

  @override
  bool get isSupported => true;

  @override
  Future<bool> applyVariant(String variantId) async {
    if (throws) {
      throw StateError('launcher switching unavailable');
    }
    applied.add(variantId);
    return true;
  }
}
