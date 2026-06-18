import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/external_link_launcher_provider.dart';
import 'package:linthra/core/app_info.dart';
import 'package:linthra/core/services/external_link_launcher.dart';
import 'package:linthra/features/settings/hub/about_screen.dart';

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

    testWidgets('composes the support section (bug report + email + privacy)',
        (tester) async {
      await _pump(tester);

      expect(find.text('Report a bug'), findsOneWidget);
      expect(find.text('Email support'), findsOneWidget);
      expect(find.text('support@linthra.ca'), findsOneWidget);
      expect(find.text('Privacy policy'), findsOneWidget);
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
  });
}
