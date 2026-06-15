import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/app_info.dart';
import 'package:linthra/features/settings/settings_screen.dart';

/// The hub renders into a router whose category routes resolve to simple markers,
/// so a tap can be proven to navigate to the right page without pulling in the
/// provider-heavy real category screens.
GoRouter _router() {
  GoRoute leaf(String path, String marker) => GoRoute(
        path: path,
        builder: (_, __) => Scaffold(body: Text(marker)),
      );
  return GoRouter(
    initialLocation: AppRoutes.settings,
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.settings,
        builder: (_, __) => const SettingsScreen(),
      ),
      leaf(AppRoutes.settingsConnections, 'CONNECTIONS_PAGE'),
      leaf(AppRoutes.settingsPlayback, 'PLAYBACK_PAGE'),
      leaf(AppRoutes.settingsCache, 'CACHE_PAGE'),
      leaf(AppRoutes.settingsDownloads, 'DOWNLOADS_PAGE'),
      leaf(AppRoutes.settingsDiagnostics, 'DIAGNOSTICS_PAGE'),
      leaf(AppRoutes.settingsAbout, 'ABOUT_PAGE'),
    ],
  );
}

Future<void> _pump(WidgetTester tester) async {
  // A tall surface so the whole list of categories is laid out (a ListView
  // only builds on-screen rows) and every tile is hittable.
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp.router(routerConfig: _router()));
  await tester.pumpAndSettle();
}

void main() {
  group('SettingsScreen (hub)', () {
    testWidgets('shows the brand header and every category', (tester) async {
      await _pump(tester);

      // Brand stays present on the hub.
      expect(find.text(AppInfo.name), findsOneWidget);
      expect(find.text(AppInfo.tagline), findsOneWidget);

      // The six categories of the Master Settings Hub.
      expect(find.text('Connections'), findsOneWidget);
      expect(find.text('Music & playback'), findsOneWidget);
      expect(find.text('Cache & data'), findsOneWidget);
      expect(find.text('Offline & downloads'), findsOneWidget);
      expect(find.text('Diagnostics & support'), findsOneWidget);
      expect(find.text('About'), findsOneWidget);
    });

    testWidgets('each category opens its page', (tester) async {
      const cases = <(String, String)>[
        ('Connections', 'CONNECTIONS_PAGE'),
        ('Music & playback', 'PLAYBACK_PAGE'),
        ('Cache & data', 'CACHE_PAGE'),
        ('Offline & downloads', 'DOWNLOADS_PAGE'),
        ('Diagnostics & support', 'DIAGNOSTICS_PAGE'),
        ('About', 'ABOUT_PAGE'),
      ];

      for (final (String title, String marker) in cases) {
        await _pump(tester);
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
        expect(find.text(marker), findsOneWidget,
            reason: 'tapping "$title" should open its page');
      }
    });
  });
}
