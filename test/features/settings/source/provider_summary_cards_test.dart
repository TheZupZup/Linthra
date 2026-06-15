import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/core/sources/local/local_scan_report.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';
import 'package:linthra/features/settings/source/provider_summary_cards.dart';

import '../../../core/sources/jellyfin/fake_jellyfin_client.dart';
import '../jellyfin/fake_jellyfin_authenticator.dart';

const JellyfinSession _session = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-1',
  accessToken: 'secret-token',
  deviceId: 'device-1',
  userName: 'alice',
  serverName: 'Home',
);

const String _safFolder =
    'content://com.android.externalstorage.documents/tree/primary%3AMusic';

Future<void> _pumpJellyfin(
  WidgetTester tester, {
  JellyfinSession? initialSession,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        jellyfinAuthenticatorProvider
            .overrideWithValue(FakeJellyfinAuthenticator()),
        jellyfinSessionStoreProvider.overrideWithValue(
          InMemoryJellyfinSessionStore(initialSession: initialSession),
        ),
        jellyfinClientProvider.overrideWithValue(FakeJellyfinClient()),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: JellyfinProviderCard()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpLocal(
  WidgetTester tester, {
  String? initialFolder,
  LocalScanReport? report,
}) async {
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
        home: Scaffold(
          body: SingleChildScrollView(child: LocalMusicProviderCard()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('JellyfinProviderCard', () {
    testWidgets('disconnected shows a compact "Not connected" card',
        (tester) async {
      await _pumpJellyfin(tester);

      expect(find.text('Jellyfin'), findsOneWidget);
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);
      // The technical form is not on screen until Manage/Connect is tapped.
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Test connection'), findsNothing);
    });

    testWidgets('Connect opens the existing settings in a sheet',
        (tester) async {
      await _pumpJellyfin(tester);

      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();

      // The unchanged Jellyfin section is hosted in the sheet, full form intact.
      expect(find.byType(TextField), findsNWidgets(3));
      expect(find.text('Test connection'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
    });

    testWidgets('connected shows status, Sync now and Manage', (tester) async {
      await _pumpJellyfin(tester, initialSession: _session);

      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Signed in as alice'), findsOneWidget);
      expect(find.text('Sync now'), findsOneWidget);
      expect(find.text('Manage'), findsOneWidget);
    });
  });

  group('LocalMusicProviderCard', () {
    setUp(LocalScanDiagnostics.reset);
    tearDown(LocalScanDiagnostics.reset);

    testWidgets('with no folder invites selecting one', (tester) async {
      await _pumpLocal(tester);

      expect(find.text('Local music'), findsOneWidget);
      expect(find.text('No folder selected'), findsOneWidget);
      expect(find.text('Select a folder'), findsOneWidget);
      expect(find.text('Rescan'), findsNothing);
    });

    testWidgets('with a folder shows the track count, Rescan and Manage',
        (tester) async {
      await _pumpLocal(
        tester,
        initialFolder: _safFolder,
        report: const LocalScanReport(
          folderSelected: true,
          isContentUri: true,
          filesVisited: 10,
          foldersVisited: 2,
          audioCandidates: 8,
          importedTracks: 8,
          skippedUnsupported: 0,
          readFailures: 0,
        ),
      );

      expect(find.text('8 tracks'), findsOneWidget);
      expect(find.text('Rescan'), findsOneWidget);
      expect(find.text('Manage'), findsOneWidget);
    });
  });
}
