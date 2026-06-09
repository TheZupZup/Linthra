import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/core/sources/local/local_scan_report.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/settings/source/local_music_settings_section.dart';

const String _safFolder =
    'content://com.android.externalstorage.documents/tree/primary%3AMusic';

Future<void> _pump(
  WidgetTester tester, {
  String? initialFolder,
  LocalScanReport? report,
}) async {
  // The card reads the last scan reactively from localScanReportProvider, which
  // seeds itself from LocalScanDiagnostics.last — so recording here is how a
  // test stages "the last scan looked like this".
  if (report != null) {
    LocalScanDiagnostics.record(report);
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        selectedMusicFolderRepositoryProvider.overrideWithValue(
          InMemorySelectedMusicFolderRepository(initialFolder: initialFolder),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: LocalMusicSettingsSection()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // Keep one test's recorded scan from leaking into the next (the diagnostics
  // store is a process-wide static).
  setUp(LocalScanDiagnostics.reset);
  tearDown(LocalScanDiagnostics.reset);

  group('LocalMusicSettingsSection', () {
    testWidgets('with no folder, invites the user to select one',
        (tester) async {
      await _pump(tester);

      expect(find.text('Local music'), findsOneWidget);
      expect(find.text('No folder selected yet.'), findsOneWidget);
      expect(find.text('Select a folder'), findsOneWidget);
      // No rescan/forget actions until a folder exists.
      expect(find.text('Rescan'), findsNothing);
      expect(find.text('Forget folder'), findsNothing);
    });

    testWidgets('with a SAF folder, shows a friendly label and the actions',
        (tester) async {
      await _pump(
        tester,
        initialFolder: 'content://com.android.externalstorage.documents/tree/'
            'primary%3AMusic%2Fmusi5',
      );

      // The opaque content:// URI is reduced to a recognizable folder label.
      expect(find.text('primary:Music/musi5'), findsOneWidget);
      expect(find.text('Rescan'), findsOneWidget);
      expect(find.text('Change'), findsOneWidget);
      expect(find.text('Forget folder'), findsOneWidget);
    });

    testWidgets('after a successful scan, shows a clear summary with counts',
        (tester) async {
      await _pump(
        tester,
        initialFolder: _safFolder,
        report: const LocalScanReport(
          folderSelected: true,
          isContentUri: true,
          filesVisited: 12,
          foldersVisited: 4,
          audioCandidates: 9,
          importedTracks: 8,
          skippedUnsupported: 3,
          readFailures: 0,
        ),
      );

      // Headline states what the user cares about: tracks added.
      expect(find.textContaining('8 tracks added'), findsOneWidget);
      // Secret-free breakdown of the safe counters.
      expect(find.textContaining('4 folders'), findsOneWidget);
      expect(find.textContaining('12 files'), findsOneWidget);
      expect(find.textContaining('9 audio'), findsOneWidget);
      expect(find.textContaining('3 skipped'), findsOneWidget);
      // A successful scan shows no "try again" hint.
      expect(find.textContaining("Android's folder chooser"), findsNothing);
    });

    testWidgets('a single imported track is summarized in the singular',
        (tester) async {
      await _pump(
        tester,
        initialFolder: _safFolder,
        report: const LocalScanReport(
          folderSelected: true,
          isContentUri: true,
          filesVisited: 1,
          foldersVisited: 1,
          audioCandidates: 1,
          importedTracks: 1,
          skippedUnsupported: 0,
          readFailures: 0,
        ),
      );

      expect(find.textContaining('1 track added'), findsOneWidget);
      expect(find.textContaining('1 folder'), findsOneWidget);
      expect(find.textContaining('1 file'), findsOneWidget);
    });

    testWidgets(
        'when no audio is found, suggests supported files and reselecting '
        'without blaming the user', (tester) async {
      await _pump(
        tester,
        initialFolder: _safFolder,
        report: const LocalScanReport(
          folderSelected: true,
          isContentUri: true,
          filesVisited: 5,
          foldersVisited: 2,
          audioCandidates: 0,
          importedTracks: 0,
          skippedUnsupported: 5,
          readFailures: 0,
        ),
      );

      expect(find.textContaining('no tracks found'), findsOneWidget);
      // Helpful, actionable guidance — both requested suggestions.
      expect(find.textContaining('supported audio files'), findsOneWidget);
      expect(find.textContaining("Android's folder chooser"), findsOneWidget);
    });

    testWidgets(
        'when the folder cannot be read, suggests reselecting to restore '
        'access', (tester) async {
      await _pump(
        tester,
        initialFolder: _safFolder,
        report: const LocalScanReport(
          folderSelected: true,
          isContentUri: true,
          filesVisited: 0,
          foldersVisited: 0,
          audioCandidates: 0,
          importedTracks: 0,
          skippedUnsupported: 0,
          readFailures: 3,
        ),
      );

      expect(find.textContaining('no tracks found'), findsOneWidget);
      expect(find.textContaining("couldn't read this folder"), findsOneWidget);
      expect(find.textContaining('restore access'), findsOneWidget);
    });

    testWidgets('a failed scan shows a gentle status and a reselect hint',
        (tester) async {
      await _pump(
        tester,
        initialFolder: _safFolder,
        report: const LocalScanReport.failure(
          folderSelected: true,
          isContentUri: true,
          error: LocalScanError.safTraversal,
        ),
      );

      expect(find.textContaining("couldn't finish"), findsOneWidget);
      expect(find.textContaining("Android's folder chooser"), findsOneWidget);
    });

    testWidgets('the scan recap never shows a path, URI, or file name',
        (tester) async {
      await _pump(
        tester,
        initialFolder: _safFolder,
        report: const LocalScanReport(
          folderSelected: true,
          isContentUri: true,
          filesVisited: 5,
          foldersVisited: 2,
          audioCandidates: 0,
          importedTracks: 0,
          skippedUnsupported: 5,
          readFailures: 0,
        ),
      );

      // Walk every rendered string and assert nothing path-shaped leaks.
      for (final Text text in tester.widgetList<Text>(find.byType(Text))) {
        final String value = text.data ?? '';
        expect(value, isNot(contains('content://')));
        expect(value, isNot(contains('/storage/')));
        expect(value.toLowerCase(), isNot(contains('.mp3')));
      }
    });
  });
}
