import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/external_link_launcher_provider.dart';
import 'package:linthra/core/app_info.dart';
import 'package:linthra/core/services/external_link_launcher.dart';
import 'package:linthra/features/settings/about/app_info_report.dart';
import 'package:linthra/features/settings/about/bug_report_email.dart';
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
      expect(find.text('Report a bug'), findsOneWidget);
      expect(find.text('Copy app info'), findsOneWidget);
      expect(find.text('Email support'), findsOneWidget);
      expect(find.text('support@linthra.ca'), findsOneWidget);
      expect(find.text('Privacy policy'), findsOneWidget);
    });

    testWidgets('tapping "Report a bug" opens a prefilled mailto draft',
        (tester) async {
      final _FakeLinkLauncher launcher = await _pump(tester);

      await tester.tap(find.text('Report a bug'));
      await tester.pumpAndSettle();

      final Uri? opened = launcher.opened;
      expect(opened, isNotNull);
      expect(opened!.scheme, 'mailto');
      expect(opened.path, 'support@linthra.ca');
      expect(opened.queryParameters['subject'], 'Linthra bug report');
      expect(opened.queryParameters['body'], BugReportEmail.body);
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

    testWidgets(
        'tapping "Copy app info" copies the app-info block and confirms with '
        'a snackbar', (tester) async {
      final List<MethodCall> clipboardCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardCalls.add(call);
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await _pump(tester);

      await tester.tap(find.text('Copy app info'));
      await tester.pump();
      await tester.pump();

      expect(clipboardCalls, hasLength(1));
      final Map<dynamic, dynamic> args =
          clipboardCalls.single.arguments as Map<dynamic, dynamic>;
      final String copied = args['text'] as String;

      // The widget copies exactly what the pure helper builds for this host
      // (a test runs off-Android, so the Android version stays a blank prompt).
      expect(copied, AppInfoReport.build(linthraVersion: AppInfo.version));
      expect(copied, startsWith('Linthra app info'));
      expect(copied, contains('Linthra version: ${AppInfo.version}'));
      expect(
        copied,
        contains('Music source used: Local / Jellyfin / Navidrome / Subsonic'),
      );
      expect(copied, contains('Issue summary:'));
      // No server URL, credential, or username leaks into the copied block.
      expect(copied, isNot(contains('://')));
      expect(copied, isNot(contains('@')));

      // The confirmation SnackBar appears.
      expect(find.textContaining('App info copied'), findsOneWidget);

      // Let the SnackBar's auto-dismiss timer fire so no timers are pending.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });
}
