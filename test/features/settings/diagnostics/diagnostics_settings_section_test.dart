import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/text_file_saver_provider.dart';
import 'package:linthra/core/services/text_file_saver.dart';
import 'package:linthra/features/settings/diagnostics/diagnostics_collector.dart';
import 'package:linthra/features/settings/diagnostics/diagnostics_settings_section.dart';

const String _fakeReport = 'Linthra diagnostics\n'
    'App version: 0.1.0-test\n'
    'Jellyfin host: music.example.com\n'
    'Last error: none';

/// A save that ends as [result], recording what it was asked to save.
class _FakeSaver implements TextFileSaver {
  _FakeSaver(this.result);

  final TextFileSaveResult result;
  final List<({String suggestedName, String contents})> saves =
      <({String suggestedName, String contents})>[];

  @override
  Future<TextFileSaveResult> save({
    required String suggestedName,
    required String contents,
    required String dialogTitle,
  }) async {
    saves.add((suggestedName: suggestedName, contents: contents));
    return result;
  }
}

Future<void> _pumpSection(WidgetTester tester, {TextFileSaver? saver}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        diagnosticsReportBuilderProvider.overrideWithValue(
          () async => _fakeReport,
        ),
        if (saver != null) textFileSaverProvider.overrideWithValue(saver),
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

    // #748: on Linux the place comes from the desktop's save dialog, and
    // closing it is not an error.
    testWidgets('Save writes the snapshot and names only the file',
        (tester) async {
      final _FakeSaver saver =
          _FakeSaver(const TextFileSaved('/home/me/linthra-diagnostics.txt'));
      await _pumpSection(tester, saver: saver);

      await tester.tap(find.text('Save diagnostics'));
      await tester.pump();
      await tester.pump();

      expect(saver.saves.single.suggestedName, 'linthra-diagnostics.txt');
      expect(saver.saves.single.contents, _fakeReport);
      expect(find.text('Saved to …/linthra-diagnostics.txt.'), findsOneWidget);
    });

    testWidgets('a closed save dialog says nothing at all', (tester) async {
      final _FakeSaver saver = _FakeSaver(const TextFileSaveCancelled());
      await _pumpSection(tester, saver: saver);

      await tester.tap(find.text('Save diagnostics'));
      await tester.pump();
      await tester.pump();

      expect(saver.saves, hasLength(1));
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a failed save points at Copy', (tester) async {
      await _pumpSection(tester, saver: _FakeSaver(const TextFileSaveFailed()));

      await tester.tap(find.text('Save diagnostics'));
      await tester.pump();
      await tester.pump();

      expect(find.text("Couldn't save diagnostics. Try Copy instead."),
          findsOneWidget);
    });
  });
}
