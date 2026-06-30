import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/external_link_launcher_provider.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/app_info.dart';
import 'package:linthra/core/services/external_link_launcher.dart';
import 'package:linthra/core/services/share_service.dart';
import 'package:linthra/data/repositories/share_service_provider.dart';
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

class _FakeShareService implements ShareService {
  _FakeShareService({this.isSupported = true, this.result = true});

  @override
  final bool isSupported;
  final bool result;
  String? shared;

  @override
  Future<bool> share(String text) async {
    shared = text;
    return result;
  }
}

/// The fakes wired into a pumped About screen, returned together so a test can
/// assert against either the browser launcher or the share sheet.
class _Fakes {
  _Fakes(this.launcher, this.share);

  final _FakeLinkLauncher launcher;
  final _FakeShareService share;
}

Future<_Fakes> _pump(
  WidgetTester tester, {
  bool launchResult = true,
  bool shareSupported = true,
  bool shareResult = true,
}) async {
  final _FakeLinkLauncher launcher = _FakeLinkLauncher(result: launchResult);
  final _FakeShareService share =
      _FakeShareService(isSupported: shareSupported, result: shareResult);
  // A tall surface so every card (brand, build info, support, community, and
  // links) is laid out and hittable — a ListView only builds the rows it can
  // show.
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        externalLinkLauncherProvider.overrideWithValue(launcher),
        shareServiceProvider.overrideWithValue(share),
      ],
      child: const MaterialApp(home: AboutScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return _Fakes(launcher, share);
}

void main() {
  group('AboutScreen', () {
    testWidgets('shows brand, version, and the link rows', (tester) async {
      await _pump(tester);

      expect(find.text(AppInfo.name), findsOneWidget);
      // The running version is shown verbatim.
      expect(find.text(AppInfo.version), findsOneWidget);
      // The release channel is derived from the version: 0.1.8 is stable, so it
      // must read "Stable" and never the old hardcoded "Alpha".
      expect(find.text('Release channel'), findsOneWidget);
      expect(find.text(AppInfo.releaseChannel), findsOneWidget);
      expect(find.text('Stable'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
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
      final _Fakes fakes = await _pump(tester);

      await tester.tap(find.text('Source code'));
      await tester.pumpAndSettle();

      expect(fakes.launcher.opened,
          Uri.parse('https://github.com/thezupzup/linthra'));
    });

    testWidgets('shows the community rows and opens each link', (tester) async {
      final _Fakes fakes = await _pump(tester);

      expect(find.text('Join the community'), findsOneWidget);
      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('Latest release'), findsOneWidget);

      await tester.tap(find.text('Join the community'));
      await tester.pumpAndSettle();
      expect(fakes.launcher.opened, Uri.parse('https://reddit.com/r/Linthra'));

      await tester.tap(find.text('GitHub'));
      await tester.pumpAndSettle();
      expect(fakes.launcher.opened,
          Uri.parse('https://github.com/TheZupZup/Linthra'));

      await tester.tap(find.text('Latest release'));
      await tester.pumpAndSettle();
      expect(fakes.launcher.opened,
          Uri.parse('https://github.com/TheZupZup/Linthra/releases/latest'));
    });

    testWidgets('shows "Share Linthra" and shares via the share sheet',
        (tester) async {
      final _Fakes fakes = await _pump(tester);

      expect(find.text('Share Linthra'), findsOneWidget);

      await tester.tap(find.text('Share Linthra'));
      await tester.pumpAndSettle();

      expect(fakes.share.shared, isNotNull);
      expect(fakes.share.shared, contains('Linthra'));
      expect(
        fakes.share.shared,
        contains('https://github.com/TheZupZup/Linthra'),
      );
    });

    testWidgets('hides "Share Linthra" when no share sheet is available',
        (tester) async {
      // Off Android (or any host without a native share sheet) the row is
      // omitted rather than offering an action that can't run.
      await _pump(tester, shareSupported: false);

      expect(find.text('Share Linthra'), findsNothing);
      // The browser-based community rows are unaffected.
      expect(find.text('Join the community'), findsOneWidget);
      expect(find.text('GitHub'), findsOneWidget);
    });

    testWidgets('shows a snackbar when the share sheet cannot open',
        (tester) async {
      await _pump(tester, shareResult: false);

      await tester.tap(find.text('Share Linthra'));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't open the share sheet."), findsOneWidget);
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
