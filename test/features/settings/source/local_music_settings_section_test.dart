import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/folder_picker_service.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/directory_readability.dart';
import 'package:linthra/core/sources/local/folder_location.dart';
import 'package:linthra/core/sources/local/local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_root_fault.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/core/sources/local/local_scan_report.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/settings/source/local_music_settings_section.dart';

import '../../library/fake_audio_file_scanner.dart';

/// Reports one fixed answer for "can this folder still be listed?", standing in
/// for the real `dart:io` probe so the desktop lost-access state can be driven
/// without a disk.
class _FixedReadability implements DirectoryReadability {
  const _FixedReadability(this.readable, {this.fault = LocalRootFault.missing});

  final bool readable;

  /// Why an unreadable folder is unreadable: the distinction the card's
  /// recovery panel is built on (#414).
  final LocalRootFault fault;

  @override
  Future<LocalRootFault?> inspect(String path) async => readable ? null : fault;
}

/// Reports only the named folders as gone, so a test can unplug one drive and
/// leave the rest of the library readable.
class _MissingFolders implements DirectoryReadability {
  const _MissingFolders(this.missing);

  final Set<String> missing;

  @override
  Future<LocalRootFault?> inspect(String path) async =>
      missing.contains(path) ? LocalRootFault.missing : null;
}

/// A picker whose answer the test sets, so "the user chose that folder" is
/// reachable from a tap.
class _StagedPicker implements FolderPickerService {
  _StagedPicker(this.folder);

  final String? folder;
  int pickCount = 0;

  @override
  Future<String?> pickFolder() async {
    pickCount++;
    return folder;
  }
}

/// A chooser that does not answer until the test says so, so the card can be
/// looked at while a recovery command is still running.
class _BlockingPicker implements FolderPickerService {
  final Completer<String?> _answer = Completer<String?>();
  int pickCount = 0;

  void answer(String? folder) => _answer.complete(folder);

  @override
  Future<String?> pickFolder() {
    pickCount++;
    return _answer.future;
  }
}

const String _safFolder =
    'content://com.android.externalstorage.documents/tree/primary%3AMusic';

const String _deviceLibrary = FolderLocation.androidMediaStoreAudio;

/// Every rendered string on the card, so a test can assert what the whole
/// surface does — and does not — say.
Iterable<String> _renderedText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((Text text) => text.data ?? '');

Future<void> _pump(
  WidgetTester tester, {
  String? initialFolder,
  List<String>? initialFolders,
  LocalScanReport? report,
  HostPlatform? host,
  DirectoryReadability? readability,
  FolderPickerService? picker,
  InMemorySelectedMusicFolderRepository? folderRepo,
  AudioFileScanner? scanner,
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
          folderRepo ??
              InMemorySelectedMusicFolderRepository(
                initialFolder: initialFolder,
                initialFolders: initialFolders,
              ),
        ),
        musicLibraryRepositoryProvider
            .overrideWithValue(InMemoryMusicLibraryRepository()),
        if (host != null) hostPlatformProvider.overrideWithValue(host),
        if (readability != null)
          directoryReadabilityProvider.overrideWithValue(readability),
        if (picker != null)
          folderPickerServiceProvider.overrideWithValue(picker),
        if (scanner != null) ...<Override>[
          audioFileScannerProvider.overrideWithValue(scanner),
          // A scan driven from a widget test runs on fake async time, so the
          // real tag reader's disk work would outlive pumpAndSettle's clock.
          // The tags are not what these tests are about.
          localMetadataReaderProvider
              .overrideWithValue(const UnsupportedLocalMetadataReader()),
        ],
      ],
      child: const MaterialApp(
        // The card ships inside the scrollable provider sheet, so scroll here
        // too: the Android variant is taller than the test surface once the
        // privacy panel and a scan hint are on screen.
        home: Scaffold(
          body: SingleChildScrollView(child: LocalMusicSettingsSection()),
        ),
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
    testWidgets('on Linux, a folder Linthra cannot reach says so', (
      tester,
    ) async {
      // The Flatpak/desktop half of the lost-access state (#438): the portal
      // document was revoked, the drive was unplugged, or the folder is gone.
      // The card has to say that plainly, and promise the library is still
      // there, instead of quietly showing an empty local source.
      await _pump(
        tester,
        initialFolder: '/home/me/Music',
        host: HostPlatform.linux,
        readability: const _FixedReadability(false),
      );

      expect(find.text('Folder not found'), findsOneWidget);
      expect(
        find.textContaining('Its music stays in your library'),
        findsOneWidget,
      );
      // Recoverable, not destructive: all three ways out are on the row, and
      // the card's own actions are untouched.
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Select folder again'), findsOneWidget);
      expect(find.text('Remove folder'), findsOneWidget);
      expect(find.text('Add a folder'), findsOneWidget);
      expect(find.text('Forget local music'), findsOneWidget);
    });

    testWidgets('a folder whose permissions changed is not called missing', (
      tester,
    ) async {
      // The three ways a folder stops being readable have three different
      // fixes, and telling them apart is what #414 is for. This one is still
      // exactly where it was, and telling the user to reconnect a drive would
      // send them looking for a problem they do not have.
      await _pump(
        tester,
        initialFolder: '/home/me/Music',
        host: HostPlatform.linux,
        readability: const _FixedReadability(
          false,
          fault: LocalRootFault.permissionDenied,
        ),
      );

      expect(find.text('Permission denied'), findsOneWidget);
      expect(find.text('Folder not found'), findsNothing);
      expect(find.textContaining('permissions'), findsWidgets);
    });

    testWidgets('a drive that stopped answering reads as temporary', (
      tester,
    ) async {
      await _pump(
        tester,
        initialFolder: '/media/usb/Music',
        host: HostPlatform.linux,
        readability: const _FixedReadability(
          false,
          fault: LocalRootFault.unavailable,
        ),
      );

      expect(find.text("Storage isn't responding"), findsOneWidget);
      expect(
        find.textContaining('Nothing about your setup changed'),
        findsOneWidget,
      );
    });

    testWidgets('the recovery panel never shows a raw OS error', (
      tester,
    ) async {
      // Diagnostics stay internal; what reaches the card is a kind and the
      // words written for it.
      await _pump(
        tester,
        initialFolder: '/home/me/Music',
        host: HostPlatform.linux,
        readability: const _FixedReadability(
          false,
          fault: LocalRootFault.unknown,
        ),
      );

      final Iterable<String> rendered = _renderedText(tester);
      expect(rendered.any((String text) => text.contains('errno')), isFalse);
      expect(
        rendered.any((String text) => text.contains('OS Error')),
        isFalse,
      );
      expect(
        rendered.any((String text) => text.contains('FileSystemException')),
        isFalse,
      );
      expect(find.text("Folder can't be read"), findsOneWidget);
    });

    testWidgets('Select folder again opens the chooser for that folder', (
      tester,
    ) async {
      // Reselect is the one way a configured path ever changes, and it always
      // goes through the system chooser: nothing picks a folder on the user's
      // behalf.
      final picker = _StagedPicker('/media/usb2/Music');
      final folderRepo = InMemorySelectedMusicFolderRepository(
        initialFolders: <String>['/home/me/Music', '/media/usb/Music'],
      );
      await _pump(
        tester,
        folderRepo: folderRepo,
        host: HostPlatform.linux,
        readability: const _MissingFolders(<String>{'/media/usb/Music'}),
        picker: picker,
        scanner: FakeAudioFileScanner(
          unavailable: <String>{'/media/usb/Music'},
        ),
      );

      await tester.tap(find.text('Select folder again'));
      await tester.pumpAndSettle();

      expect(picker.pickCount, 1);
      // Only the folder the panel belonged to moved.
      expect(await folderRepo.getSelectedFolders(), <String>[
        '/home/me/Music',
        '/media/usb2/Music',
      ]);
    });

    testWidgets('Remove folder takes out only that folder, and no files', (
      tester,
    ) async {
      final folderRepo = InMemorySelectedMusicFolderRepository(
        initialFolders: <String>['/home/me/Music', '/media/usb/Music'],
      );
      await _pump(
        tester,
        folderRepo: folderRepo,
        host: HostPlatform.linux,
        readability: const _MissingFolders(<String>{'/media/usb/Music'}),
        scanner: FakeAudioFileScanner(
          unavailable: <String>{'/media/usb/Music'},
        ),
      );

      // Said before the tap, because "Remove" next to a folder that just broke
      // is exactly where a user fears the worst.
      expect(
        find.textContaining('Your files are\nnever deleted.'),
        findsNothing,
      );
      expect(
        find.textContaining('Your files are never deleted'),
        findsOneWidget,
      );

      await tester.tap(find.text('Remove folder'));
      await tester.pumpAndSettle();

      expect(await folderRepo.getSelectedFolders(), <String>['/home/me/Music']);
    });

    testWidgets('a command in flight takes the recovery actions with it', (
      tester,
    ) async {
      // The card already swaps its own actions for a spinner while something
      // is running. The panel's have to go the same way: a second chooser, a
      // second Retry or a Remove landing on top of the first would race it,
      // and the loser would still be the one reporting.
      final picker = _BlockingPicker();
      await _pump(
        tester,
        initialFolder: '/media/usb/Music',
        host: HostPlatform.linux,
        readability: const _FixedReadability(false),
        picker: picker,
      );

      expect(find.text('Select folder again'), findsOneWidget);

      await tester.tap(find.text('Select folder again'));
      await tester.pump();

      expect(picker.pickCount, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // The problem is still described. Only the ways to act on it are gone,
      // because one of them is already happening.
      expect(find.text('Folder not found'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('Select folder again'), findsNothing);
      expect(find.text('Remove folder'), findsNothing);

      // Cancelled: the folder is still selected and the actions come back.
      picker.answer(null);
      await tester.pumpAndSettle();

      expect(picker.pickCount, 1);
      expect(find.text('Select folder again'), findsOneWidget);
    });

    testWidgets('Retry is offered for every kind of problem', (tester) async {
      for (final LocalRootFault fault in LocalRootFault.values) {
        await _pump(
          tester,
          initialFolder: '/home/me/Music',
          host: HostPlatform.linux,
          readability: _FixedReadability(false, fault: fault),
        );

        expect(find.text('Retry'), findsOneWidget, reason: '$fault');
      }
    });

    testWidgets('on Linux, a reachable folder says nothing about access', (
      tester,
    ) async {
      await _pump(
        tester,
        initialFolder: '/home/me/Music',
        host: HostPlatform.linux,
        readability: const _FixedReadability(true),
      );

      expect(find.text('/home/me/Music'), findsOneWidget);
      expect(
        find.textContaining('Its music stays in your library'),
        findsNothing,
      );
    });

    testWidgets('on Linux, the blurb describes the desktop file chooser', (
      tester,
    ) async {
      // The Android copy ("Android's folder access") is wrong on a desktop,
      // where the same promise — only the folder you chose, no broad
      // permission — is kept by the system file chooser (the portal, in a
      // Flatpak).
      await _pump(tester, host: HostPlatform.linux);

      expect(
        find.textContaining('the system file chooser'),
        findsOneWidget,
      );
      expect(find.textContaining("Android's folder access"), findsNothing);
    });

    testWidgets('with no folder, invites the user to select one',
        (tester) async {
      await _pump(tester);

      expect(find.text('Local music'), findsOneWidget);
      expect(find.text('No local music source selected yet.'), findsOneWidget);
      expect(find.text('Select a folder'), findsOneWidget);
      // No rescan/forget actions until a folder exists.
      expect(find.text('Rescan'), findsNothing);
      expect(find.text('Forget local music'), findsNothing);
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
      expect(find.text('Add a folder'), findsOneWidget);
      expect(find.text('Forget local music'), findsOneWidget);
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
        // A SAF folder is an Android selection, and the hint names Android's
        // chooser — asserted with an injected host so it holds on any machine.
        host: HostPlatform.android,
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

    testWidgets(
        'on Linux, an unreadable folder points at the system chooser, not '
        "Android's", (tester) async {
      // The Flatpak case this has to get right: a portal folder that was
      // revoked or unplugged. Access is reported as fine here so the only
      // recovery text on screen is the scan hint itself.
      await _pump(
        tester,
        host: HostPlatform.linux,
        readability: const _FixedReadability(true),
        initialFolder: '/home/me/Music',
        report: const LocalScanReport.failure(
          folderSelected: true,
          isContentUri: false,
          error: LocalScanError.folderUnavailable,
        ),
      );

      expect(find.textContaining("Android's folder chooser"), findsNothing);
      // Still a clear way back: reselect the folder in the chooser Linux has.
      expect(find.textContaining("couldn't read this folder"), findsOneWidget);
      expect(
        find.textContaining(
          'Select it again with the system folder chooser',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('restore access'), findsOneWidget);
      // The SD-card aside is an Android storage note; a desktop path is not it.
      expect(find.textContaining('SD cards'), findsNothing);
    });

    testWidgets(
        'on Linux, an empty scan suggests reselecting in the system chooser',
        (tester) async {
      await _pump(
        tester,
        host: HostPlatform.linux,
        readability: const _FixedReadability(true),
        initialFolder: '/home/me/Music',
        report: const LocalScanReport(
          folderSelected: true,
          isContentUri: false,
          filesVisited: 5,
          audioCandidates: 0,
          importedTracks: 0,
          skippedUnsupported: 5,
          readFailures: 0,
        ),
      );

      expect(find.textContaining("Android's folder chooser"), findsNothing);
      expect(find.textContaining('supported audio files'), findsOneWidget);
      expect(
        find.textContaining(
          'select the folder again with the system folder chooser',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a failed scan shows a gentle status and a reselect hint',
        (tester) async {
      await _pump(
        tester,
        // A SAF selection, so the Android wording is the right one here.
        host: HostPlatform.android,
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

    // The device-wide MediaStore mode has no folder behind it. Any outcome that
    // falls back to folder wording sends the user to Android's folder chooser
    // for a library that is not a folder — the two states below (nothing found,
    // and a provider failure) are exactly where that used to happen.
    testWidgets('device-wide mode with no music says so without folder wording',
        (tester) async {
      await _pump(
        tester,
        host: HostPlatform.android,
        initialFolder: _deviceLibrary,
        report: const LocalScanReport(
          folderSelected: true,
          isContentUri: false,
          isDeviceLibrary: true,
          filesVisited: 0,
          foldersVisited: 0,
          audioCandidates: 0,
          importedTracks: 0,
          skippedUnsupported: 0,
          readFailures: 0,
        ),
      );

      expect(find.textContaining('no music on this device'), findsOneWidget);
      expect(
        find.textContaining('reported no audio on this device'),
        findsOneWidget,
      );
      for (final String text in _renderedText(tester)) {
        expect(text, isNot(contains('folder chooser')));
        expect(text, isNot(contains('this folder')));
        expect(text, isNot(contains('that folder')));
      }
    });

    testWidgets('a MediaStore provider failure keeps device-library wording',
        (tester) async {
      // `media_store_failed` (a null cursor, a provider fault) is classified as
      // `unexpected`, not `mediaPermission` — permission may well still be
      // granted. It must not be described as an unreadable folder.
      await _pump(
        tester,
        host: HostPlatform.android,
        initialFolder: _deviceLibrary,
        report: const LocalScanReport.failure(
          folderSelected: true,
          isContentUri: false,
          isDeviceLibrary: true,
          error: LocalScanError.unexpected,
        ),
      );

      expect(find.textContaining("couldn't finish"), findsOneWidget);
      expect(
        find.textContaining("couldn't read Android's shared music library"),
        findsOneWidget,
      );
      for (final String text in _renderedText(tester)) {
        expect(text, isNot(contains('folder chooser')));
        expect(text, isNot(contains('Select it again')));
      }
    });

    testWidgets('a revoked permission still routes to Android settings',
        (tester) async {
      // The one MediaStore failure that *is* about permission keeps the
      // permission-specific recovery path.
      await _pump(
        tester,
        host: HostPlatform.android,
        initialFolder: _deviceLibrary,
        report: const LocalScanReport.failure(
          folderSelected: true,
          isContentUri: false,
          isDeviceLibrary: true,
          error: LocalScanError.mediaPermission,
        ),
      );

      expect(
        find.textContaining('Re-enable it in Android settings'),
        findsOneWidget,
      );
      for (final String text in _renderedText(tester)) {
        expect(text, isNot(contains('folder chooser')));
      }
    });

    testWidgets('a SAF folder still gets folder-specific recovery text',
        (tester) async {
      // The folder half of the same branch: real folder sources keep pointing
      // at the folder chooser.
      await _pump(
        tester,
        host: HostPlatform.android,
        initialFolder: _safFolder,
        report: const LocalScanReport.failure(
          folderSelected: true,
          isContentUri: true,
          error: LocalScanError.safTraversal,
        ),
      );

      expect(find.textContaining("Android's folder chooser"), findsOneWidget);
      expect(
        find.textContaining("shared music library"),
        findsNothing,
      );
    });

    testWidgets('a failed trial of device mode is not blamed on the folder', (
      tester,
    ) async {
      // The transactional switch keeps the folder selected when the first
      // MediaStore scan fails, so the newest report describes a source that is
      // not the selected one. The recap follows the report: the folder was
      // never scanned, so telling the user to reselect it would be nonsense.
      await _pump(
        tester,
        host: HostPlatform.android,
        initialFolder: _safFolder,
        report: const LocalScanReport.failure(
          folderSelected: true,
          isContentUri: false,
          isDeviceLibrary: true,
          error: LocalScanError.unexpected,
        ),
      );

      // Still a folder user: the selection and its label are untouched.
      expect(find.text('primary:Music'), findsOneWidget);
      expect(
        find.textContaining("couldn't read Android's shared music library"),
        findsOneWidget,
      );
      for (final String text in _renderedText(tester)) {
        expect(text, isNot(contains('folder chooser')));
        expect(text, isNot(contains('Select it again')));
      }
    });

    testWidgets('lists every selected folder with its own remove action',
        (tester) async {
      await _pump(
        tester,
        initialFolders: <String>['/home/me/Music', '/media/usb'],
        host: HostPlatform.linux,
        readability: const _FixedReadability(true),
      );

      expect(find.text('2 folders'), findsOneWidget);
      expect(find.text('/home/me/Music'), findsOneWidget);
      expect(find.text('/media/usb'), findsOneWidget);
      expect(find.byTooltip('Remove this folder'), findsNWidgets(2));
      expect(find.text('Add a folder'), findsOneWidget);
    });

    testWidgets('flags only the folder that is offline', (tester) async {
      await _pump(
        tester,
        initialFolders: <String>['/home/me/Music', '/media/usb'],
        host: HostPlatform.linux,
        readability: const _MissingFolders(<String>{'/media/usb'}),
      );

      // One recovery panel, attached to the folder it is about — the rest of
      // the library is fine, and its row keeps the plain remove affordance.
      expect(find.text('Folder not found'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byTooltip('Remove this folder'), findsOneWidget);
    });

    testWidgets('a partial scan says the offline folder kept its music',
        (tester) async {
      await _pump(
        tester,
        initialFolders: <String>['/home/me/Music', '/media/usb'],
        host: HostPlatform.linux,
        readability: const _FixedReadability(true),
        report: const LocalScanReport(
          folderSelected: true,
          isContentUri: false,
          filesVisited: 4,
          foldersVisited: 2,
          audioCandidates: 3,
          importedTracks: 3,
          skippedUnsupported: 1,
          readFailures: 0,
          rootsScanned: 2,
          rootsUnavailable: 1,
        ),
      );

      expect(find.textContaining('1/2 folders read'), findsOneWidget);
      expect(
        find.textContaining("1 of 2 folders couldn't be read"),
        findsOneWidget,
      );
      expect(
        find.textContaining('Their music stays in your library'),
        findsOneWidget,
      );
    });

    testWidgets('on Android the folder list has no remove action',
        (tester) async {
      // Android holds one local grant at a time; "Forget local music" is the
      // way out, and a per-folder remove would imply a list it cannot have.
      await _pump(
        tester,
        initialFolder: _safFolder,
        host: HostPlatform.android,
      );

      expect(find.byTooltip('Remove this folder'), findsNothing);
      expect(find.text('Add a folder'), findsNothing);
      expect(find.text('Use a folder'), findsOneWidget);
    });
  });
}
