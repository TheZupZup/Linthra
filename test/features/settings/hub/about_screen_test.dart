import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/external_link_launcher_provider.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/app_info.dart';
import 'package:linthra/core/services/external_link_launcher.dart';
import 'package:linthra/features/settings/about/whats_new_section.dart';
import 'package:linthra/features/settings/hub/about_screen.dart';
import 'package:linthra/features/support/support_actions_provider.dart';

class _FakeLinkLauncher implements ExternalLinkLauncher {
  _FakeLinkLauncher({this.result = true});

  final bool result;
  Uri? opened;

  @override
  Future<bool> open(Uri url) async {
    opened = url;
    return result;
  }
}

Future<_FakeLinkLauncher> _pump(
  WidgetTester tester, {
  bool launchResult = true,
}) async {
  final _FakeLinkLauncher launcher = _FakeLinkLauncher(result: launchResult);
  // A tall surface so every card (brand, build info, support, and links) is laid
  // out and hittable — a ListView only builds the rows it can show.
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        externalLinkLauncherProvider.overrideWithValue(launcher),
      ],
      child: const MaterialApp(home: AboutScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return launcher;
}

void main() {
  group('AboutScreen', () {
    testWidgets('shows brand, version, and the link rows', (tester) async {
      await _pump(tester);

      expect(find.text(AppInfo.name), findsOneWidget);
      // The running version is shown verbatim.
      expect(find.text(AppInfo.version), findsOneWidget);
      expect(find.text('Source code'), findsOneWidget);
      expect(find.text('Releases'), findsOneWidget);
      expect(find.text('License (MPL-2.0)'), findsOneWidget);
    });

    testWidgets(
        'composes the support section (bug report + copy info + email + '
        'privacy)', (tester) async {
      await _pump(tester);

      expect(find.text('Report a bug'), findsOneWidget);
      expect(find.text('Copy app info'), findsOneWidget);
      expect(find.text('Email support'), findsOneWidget);
      expect(find.text('support@linthra.ca'), findsOneWidget);
      expect(find.text('Privacy policy'), findsOneWidget);
    });

    testWidgets('composes the "What\'s new" section for the running version',
        (tester) async {
      await _pump(tester);

      expect(find.text("What's new"), findsOneWidget);
      expect(find.text('Version ${AppInfo.version}'), findsOneWidget);
      // The static highlights are shown verbatim.
      expect(find.text(WhatsNewSection.releaseNotes.first), findsOneWidget);
    });

    testWidgets('does not show the tester checklist', (tester) async {
      await _pump(tester);

      // The tester-only checklist (a closed-testing aid) was removed from the
      // public release UI; it must not reappear on the About page.
      expect(find.text('Tester checklist'), findsNothing);
    });

    testWidgets('tapping "Source code" opens the repository', (tester) async {
      final launcher = await _pump(tester);

      await tester.tap(find.text('Source code'));
      await tester.pumpAndSettle();

      expect(
          launcher.opened, Uri.parse('https://github.com/thezupzup/linthra'));
    });

    testWidgets('shows a snackbar when a link cannot be opened',
        (tester) async {
      await _pump(tester, launchResult: false);

      await tester.tap(find.text('Releases'));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't open the link."), findsOneWidget);
    });

    testWidgets('offers a "Support Linthra" entry', (tester) async {
      await _pump(tester);

      expect(find.text('Support Linthra'), findsOneWidget);
      expect(
        find.text('Free and open source — support is optional'),
        findsOneWidget,
      );
    });

    testWidgets(
        'hides the "Support Linthra" entry when support links are disabled',
        (tester) async {
      // A links-disabled build (LINTHRA_SUPPORT_LINKS=off): the donation entry
      // point must disappear, while the help/contact "Support" card stays.
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            externalLinkLauncherProvider.overrideWithValue(_FakeLinkLauncher()),
            supportLinksEnabledProvider.overrideWithValue(false),
          ],
          child: const MaterialApp(home: AboutScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // The donation entry is gone...
      expect(find.text('Support Linthra'), findsNothing);
      expect(
        find.text('Free and open source — support is optional'),
        findsNothing,
      );
      // ...but the help/contact "Support" card is unaffected.
      expect(find.text('Report a bug'), findsOneWidget);
      expect(find.text('Privacy policy'), findsOneWidget);
    });

    testWidgets('tapping "Support Linthra" opens the support screen',
        (tester) async {
      final _FakeLinkLauncher launcher = _FakeLinkLauncher();
      // A tall surface so the support card (mid-page) is laid out and hittable.
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // A minimal router so the tap can be proven to push the support route,
      // standing in the real SupportScreen with a marker leaf.
      final GoRouter router = GoRouter(
        initialLocation: AppRoutes.settingsAbout,
        routes: <RouteBase>[
          GoRoute(
            path: AppRoutes.settingsAbout,
            builder: (_, __) => const AboutScreen(),
          ),
          GoRoute(
            path: AppRoutes.settingsSupport,
            builder: (_, __) => const Scaffold(body: Text('SUPPORT_PAGE')),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            externalLinkLauncherProvider.overrideWithValue(launcher),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Support Linthra'));
      await tester.pumpAndSettle();

      expect(find.text('SUPPORT_PAGE'), findsOneWidget);
    });
  });
}
