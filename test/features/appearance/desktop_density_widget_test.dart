import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/brand_theme.dart';
import 'package:linthra/app/theme.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/desktop_density.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/data/repositories/desktop_density_store_provider.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_desktop_density_store.dart';
import 'package:linthra/features/appearance/desktop_density_card.dart';
import 'package:linthra/features/appearance/desktop_density_controller.dart';
import 'package:linthra/features/library/widgets/artist_grid.dart';
import 'package:linthra/features/library/widgets/artist_tile.dart';

/// Desktop density (#395): the Compact/Comfortable preference selects one of
/// Material's own [VisualDensity] values, so every widget that already reads
/// `Theme.of(context).visualDensity` follows it without a change of its own.

final List<Artist> _artists = <Artist>[
  for (int i = 0; i < 12; i++)
    Artist(id: '$i', name: 'Artist $i', albumCount: 2, trackCount: 9),
];

/// Runs [body] as if Linthra were on [platform].
///
/// The override has to be cleared inside the test body rather than in a
/// tearDown: the framework asserts that no foundation debug variable is still
/// set when the body returns.
Future<void> _onPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// A miniature of what `LinthraApp` does: watch the density and rebuild the
/// theme from it, so a change relayouts without a restart.
class _DensityHost extends ConsumerWidget {
  const _DensityHost({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final VisualDensity? density = ref.watch(hostPlatformProvider).isDesktop
        ? ref.watch(desktopDensityControllerProvider).visualDensity
        : null;
    return MaterialApp(
      theme: AppTheme.dark(BrandPalettes.classic, density: density),
      home: Scaffold(body: child),
    );
  }
}

Future<ProviderContainer> _pumpHost(
  WidgetTester tester, {
  required HostPlatform host,
  required Widget child,
  DesktopDensity? seed,
  InMemoryDesktopDensityStore? store,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 900);
  addTearDown(tester.view.reset);

  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      hostPlatformProvider.overrideWithValue(host),
      if (seed != null) initialDesktopDensityProvider.overrideWithValue(seed),
      if (store != null) desktopDensityStoreProvider.overrideWithValue(store),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: _DensityHost(child: child),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

double _rowHeight(WidgetTester tester) =>
    tester.getRect(find.byType(ArtistTile).first).height;

void main() {
  group('the theme carries the density', () {
    test('no override keeps the adaptive value #384 shipped', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(
        AppTheme.dark(BrandPalettes.classic).visualDensity,
        VisualDensity.compact,
      );

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(
        AppTheme.dark(BrandPalettes.classic).visualDensity,
        VisualDensity.standard,
      );
    });

    test('an override wins in both light and dark', () {
      for (final DesktopDensity density in DesktopDensity.values) {
        expect(
          AppTheme.dark(BrandPalettes.classic, density: density.visualDensity)
              .visualDensity,
          density.visualDensity,
        );
        expect(
          AppTheme.light(BrandPalettes.classic, density: density.visualDensity)
              .visualDensity,
          density.visualDensity,
        );
      }
    });
  });

  group('library rows follow the preference', () {
    testWidgets('comfortable gives a taller row than compact', (tester) async {
      await _onPlatform(TargetPlatform.linux, () async {
        await _pumpHost(
          tester,
          host: HostPlatform.linux,
          seed: DesktopDensity.compact,
          child: ArtistGrid(artists: _artists, onOpen: (_) {}),
        );
        final double compact = _rowHeight(tester);

        await _pumpHost(
          tester,
          host: HostPlatform.linux,
          seed: DesktopDensity.comfortable,
          child: ArtistGrid(artists: _artists, onOpen: (_) {}),
        );
        final double comfortable = _rowHeight(tester);

        expect(comfortable, greaterThan(compact));
        // Density buys back padding, never the row: still clickable at either
        // setting.
        expect(compact, greaterThanOrEqualTo(48));
      });
    });

    testWidgets('changing the preference relayouts without a restart',
        (tester) async {
      await _onPlatform(TargetPlatform.linux, () async {
        final ProviderContainer container = await _pumpHost(
          tester,
          host: HostPlatform.linux,
          seed: DesktopDensity.compact,
          child: ArtistGrid(artists: _artists, onOpen: (_) {}),
        );
        final double before = _rowHeight(tester);

        await container
            .read(desktopDensityControllerProvider.notifier)
            .select(DesktopDensity.comfortable);
        await tester.pumpAndSettle();

        expect(_rowHeight(tester), greaterThan(before));
      });
    });

    testWidgets('a touch build ignores the preference entirely',
        (tester) async {
      await _onPlatform(TargetPlatform.android, () async {
        await _pumpHost(
          tester,
          host: HostPlatform.android,
          seed: DesktopDensity.compact,
          child: ArtistGrid(artists: _artists, onOpen: (_) {}),
        );
        // 72 is the two-line ListTile height touch has always had. A desktop
        // "compact" preference must not reach it.
        expect(_rowHeight(tester), 72);
      });
    });
  });

  group('hit targets survive both densities', () {
    for (final DesktopDensity density in DesktopDensity.values) {
      testWidgets('a row control stays clickable when ${density.name}',
          (tester) async {
        await _onPlatform(TargetPlatform.linux, () async {
          await _pumpHost(
            tester,
            host: HostPlatform.linux,
            seed: density,
            child: ListTile(
              title: const Text('Song One'),
              trailing: IconButton(
                onPressed: () {},
                icon: const Icon(Icons.more_vert),
              ),
            ),
          );

          final Size button = tester.getSize(find.byType(IconButton));
          expect(button.width, greaterThanOrEqualTo(40));
          expect(button.height, greaterThanOrEqualTo(40));
          expect(
            tester.getSize(find.byType(ListTile)).height,
            greaterThanOrEqualTo(48),
          );
        });
      });
    }
  });

  group('the settings card', () {
    testWidgets('is offered on desktop and writes the choice', (tester) async {
      final InMemoryDesktopDensityStore store = InMemoryDesktopDensityStore();
      await _onPlatform(TargetPlatform.linux, () async {
        final ProviderContainer container = await _pumpHost(
          tester,
          host: HostPlatform.linux,
          store: store,
          child: const SingleChildScrollView(child: DesktopDensityCard()),
        );

        expect(find.text('Density'), findsOneWidget);
        await tester.tap(find.text('Comfortable'));
        await tester.pumpAndSettle();

        expect(
          container.read(desktopDensityControllerProvider),
          DesktopDensity.comfortable,
        );
        expect(store.density, DesktopDensity.comfortable);
      });
    });

    testWidgets('is not shown on a touch build', (tester) async {
      await _onPlatform(TargetPlatform.android, () async {
        await _pumpHost(
          tester,
          host: HostPlatform.android,
          child: const SingleChildScrollView(child: DesktopDensityCard()),
        );
        expect(find.text('Density'), findsNothing);
        expect(find.byType(SegmentedButton<DesktopDensity>), findsNothing);
      });
    });
  });
}
