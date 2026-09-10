import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/desktop_density.dart';
import 'package:linthra/core/repositories/desktop_density_store.dart';
import 'package:linthra/data/repositories/desktop_density_store_provider.dart';
import 'package:linthra/data/repositories/in_memory_desktop_density_store.dart';
import 'package:linthra/features/appearance/desktop_density_controller.dart';

/// A store whose reads and writes always fail, standing in for a plugin hiccup
/// or unreadable preferences.
class _ThrowingDesktopDensityStore implements DesktopDensityStore {
  @override
  Future<DesktopDensity?> read() async => throw StateError('read failed');

  @override
  Future<void> write(DesktopDensity density) async =>
      throw StateError('write failed');
}

void main() {
  group('DesktopDensity', () {
    test('defaults to compact, which is what desktop already looked like', () {
      expect(DesktopDensity.fallback, DesktopDensity.compact);
    });

    test('round-trips every value through its storage id', () {
      for (final DesktopDensity density in DesktopDensity.values) {
        expect(
          DesktopDensity.fromStorageId(density.storageId),
          density,
          reason: '${density.name} must survive a storage round-trip',
        );
      }
    });

    test('storage ids are stable strings, not enum indices', () {
      // Indices would silently remap if the enum is ever reordered, turning a
      // stored "compact" into "comfortable" on update.
      expect(DesktopDensity.compact.storageId, 'compact');
      expect(DesktopDensity.comfortable.storageId, 'comfortable');
    });

    test('an unknown, empty, or absent id falls back to compact', () {
      expect(DesktopDensity.fromStorageId(null), DesktopDensity.compact);
      expect(DesktopDensity.fromStorageId(''), DesktopDensity.compact);
      expect(DesktopDensity.fromStorageId('roomy'), DesktopDensity.compact);
    });

    test('maps onto Material densities, not Linthra numbers', () {
      expect(DesktopDensity.compact.visualDensity, VisualDensity.compact);
      expect(
        DesktopDensity.comfortable.visualDensity,
        VisualDensity.comfortable,
      );
    });

    test('comfortable is roomier than compact but still under touch', () {
      final double compact =
          DesktopDensity.compact.visualDensity.baseSizeAdjustment.dy;
      final double comfortable =
          DesktopDensity.comfortable.visualDensity.baseSizeAdjustment.dy;
      expect(comfortable, greaterThan(compact));
      expect(
        comfortable,
        lessThan(VisualDensity.standard.baseSizeAdjustment.dy),
        reason: 'a desktop window must never become a stretched phone',
      );
    });

    test('every value has a label, an icon and an explanation', () {
      for (final DesktopDensity density in DesktopDensity.values) {
        expect(density.label, isNotEmpty);
        expect(density.description, isNotEmpty);
        expect(density.icon, isNotNull);
      }
    });
  });

  group('DesktopDensityController', () {
    ProviderContainer containerWith({
      DesktopDensityStore? store,
      DesktopDensity? seed,
    }) {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          if (store != null)
            desktopDensityStoreProvider.overrideWithValue(store),
          if (seed != null)
            initialDesktopDensityProvider.overrideWithValue(seed),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('starts on compact when nothing has been seeded', () {
      expect(
        containerWith().read(desktopDensityControllerProvider),
        DesktopDensity.compact,
      );
    });

    test('starts on the density read from storage before the first frame', () {
      final ProviderContainer container =
          containerWith(seed: DesktopDensity.comfortable);
      expect(
        container.read(desktopDensityControllerProvider),
        DesktopDensity.comfortable,
      );
    });

    test('a choice is applied immediately and persisted', () async {
      final InMemoryDesktopDensityStore store = InMemoryDesktopDensityStore();
      final ProviderContainer container = containerWith(store: store);

      await container
          .read(desktopDensityControllerProvider.notifier)
          .select(DesktopDensity.comfortable);

      expect(
        container.read(desktopDensityControllerProvider),
        DesktopDensity.comfortable,
      );
      expect(store.density, DesktopDensity.comfortable);
    });

    test('re-picking the current density writes nothing', () async {
      final InMemoryDesktopDensityStore store = InMemoryDesktopDensityStore();
      final ProviderContainer container = containerWith(store: store);

      await container
          .read(desktopDensityControllerProvider.notifier)
          .select(DesktopDensity.compact);

      expect(store.density, isNull);
    });

    test('a storage failure never undoes the visible choice', () async {
      final ProviderContainer container =
          containerWith(store: _ThrowingDesktopDensityStore());

      await container
          .read(desktopDensityControllerProvider.notifier)
          .select(DesktopDensity.comfortable);

      expect(
        container.read(desktopDensityControllerProvider),
        DesktopDensity.comfortable,
      );
    });

    test('a store that throws on read still boots on the default', () async {
      expect(
        await readStoredDesktopDensity(_ThrowingDesktopDensityStore()),
        DesktopDensity.fallback,
      );
    });

    test('an empty store reads as the default rather than null', () async {
      expect(
        await readStoredDesktopDensity(InMemoryDesktopDensityStore()),
        DesktopDensity.fallback,
      );
    });

    test('a stored density is read back before the first frame', () async {
      expect(
        await readStoredDesktopDensity(
          InMemoryDesktopDensityStore(DesktopDensity.comfortable),
        ),
        DesktopDensity.comfortable,
      );
    });
  });
}
