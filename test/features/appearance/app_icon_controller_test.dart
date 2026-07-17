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

void main() {
  group('AppIconController', () {
    late InMemoryAppIconVariantStore store;
    late FakeLauncherIconService launcher;

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      String? initial,
      bool launcherThrows = false,
    }) async {
      store = InMemoryAppIconVariantStore(initial);
      launcher = FakeLauncherIconService(throws: launcherThrows);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          appIconVariantStoreProvider.overrideWithValue(store),
          launcherIconServiceProvider.overrideWithValue(launcher),
        ],
      );
      addTearDown(container.dispose);
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
          .select(AppIconVariants.neon);
      await tester.pumpAndSettle();

      expect(
        container.read(appIconControllerProvider),
        AppIconVariants.neon,
      );
      expect(await store.read(), 'neon');
    });

    testWidgets('the gold variant is selectable here', (tester) async {
      final ProviderContainer container = await pump(tester);

      await container
          .read(appIconControllerProvider.notifier)
          .select(AppIconVariants.gold);
      await tester.pumpAndSettle();

      expect(container.read(appIconControllerProvider), AppIconVariants.gold);
      expect(await store.read(), 'gold');
    });

    testWidgets('selecting a variant switches the real launcher icon',
        (tester) async {
      final ProviderContainer container = await pump(tester);

      await container
          .read(appIconControllerProvider.notifier)
          .select(AppIconVariants.neon);
      await tester.pumpAndSettle();

      expect(launcher.applied.last, 'neon');
    });

    testWidgets('re-asserts the launcher icon for the stored choice on startup',
        (tester) async {
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

      await container
          .read(appIconControllerProvider.notifier)
          .select(AppIconVariants.gold);
      await tester.pumpAndSettle();

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
        expect(
          appIconVariantsFor(distribution),
          contains(AppIconVariants.gold),
        );
      }
    });
  });
}

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
