import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/settings/diagnostics/diagnostics_collector.dart';
import 'package:linthra/features/settings/diagnostics/diagnostics_settings_section.dart';

const String _fakeReport = 'Linthra diagnostics\n'
    'App version: 0.1.0-test\n'
    'Jellyfin host: music.example.com\n'
    'Last error: none';

Future<void> _pumpSection(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        diagnosticsReportBuilderProvider.overrideWithValue(
          () async => _fakeReport,
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: DiagnosticsSettingsSection()),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('DiagnosticsSettingsSection', () {
    testWidgets('shows the Copy and Save actions', (tester) async {
      await _pumpSection(tester);
      expect(find.text('Diagnostics'), findsOneWidget);
      expect(find.text('Copy diagnostics'), findsOneWidget);
      expect(find.text('Save diagnostics'), findsOneWidget);
    });

    testWidgets('Copy puts the secret-free report on the clipboard',
        (tester) async {
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

      await _pumpSection(tester);

      await tester.tap(find.text('Copy diagnostics'));
      await tester.pump();
      await tester.pump();

      expect(clipboardCalls, hasLength(1));
      final Map<dynamic, dynamic> args =
          clipboardCalls.single.arguments as Map<dynamic, dynamic>;
      final String copied = args['text'] as String;
      expect(copied, _fakeReport);
      expect(copied, contains('App version:'));
      expect(copied, isNot(contains('api_key')));

      // The confirmation SnackBar appears.
      expect(
        find.textContaining('Diagnostics copied'),
        findsOneWidget,
      );

      // Let the SnackBar's auto-dismiss timer fire so no timers are pending.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });
}
