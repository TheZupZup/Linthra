import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/external_link_launcher_provider.dart';
import 'package:linthra/core/services/external_link_launcher.dart';
import 'package:linthra/features/settings/about/support_section.dart';

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
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        externalLinkLauncherProvider.overrideWithValue(launcher),
      ],
      child: const MaterialApp(home: Scaffold(body: SupportSection())),
    ),
  );
  await tester.pumpAndSettle();
  return launcher;
}

void main() {
  group('SupportSection', () {
    testWidgets('shows the description, support email, and privacy policy',
        (tester) async {
      await _pump(tester);

      expect(
        find.text(
          'Open-source music player for local and self-hosted libraries.',
        ),
        findsOneWidget,
      );
      expect(find.text('Email support'), findsOneWidget);
      expect(find.text('support@linthra.ca'), findsOneWidget);
      expect(find.text('Privacy policy'), findsOneWidget);
    });

    testWidgets('tapping "Email support" opens a mailto link', (tester) async {
      final _FakeLinkLauncher launcher = await _pump(tester);

      await tester.tap(find.text('Email support'));
      await tester.pumpAndSettle();

      expect(
        launcher.opened,
        Uri(scheme: 'mailto', path: 'support@linthra.ca'),
      );
    });

    testWidgets('tapping "Privacy policy" opens the policy URL',
        (tester) async {
      final _FakeLinkLauncher launcher = await _pump(tester);

      await tester.tap(find.text('Privacy policy'));
      await tester.pumpAndSettle();

      expect(
        launcher.opened,
        Uri.parse('https://github.com/thezupzup/linthra/blob/main/PRIVACY.md'),
      );
    });

    testWidgets('shows a snackbar when a link cannot be opened',
        (tester) async {
      await _pump(tester, launchResult: false);

      await tester.tap(find.text('Privacy policy'));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't open the link."), findsOneWidget);
    });
  });
}
