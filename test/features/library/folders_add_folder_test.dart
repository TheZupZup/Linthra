import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/folder_browsable_music_source.dart';
import 'package:linthra/core/sources/local/local_file_stat.dart';
import 'package:linthra/core/sources/local/local_metadata_reader.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/folder_browser_providers.dart';
import 'package:linthra/features/library/folders_screen.dart';
import 'package:linthra/features/library/library_providers.dart';

import 'fake_audio_file_scanner.dart';
import 'fake_folder_picker_service.dart';

/// Hands back a different folder on each pick, so a test can add a second one
/// to a library that already has one.
class _SequencedFolderPicker extends FakeFolderPickerService {
  _SequencedFolderPicker(this._folders);

  final List<String> _folders;

  @override
  Future<String?> pickFolder() async {
    await super.pickFolder();
    if (_folders.isEmpty) return null;
    return _folders.removeAt(0);
  }
}

/// A picker that never answers until the test says so, standing in for a folder
/// dialog the user has open.
class _PendingFolderPicker extends FakeFolderPickerService {
  final Completer<String?> pending = Completer<String?>();

  @override
  Future<String?> pickFolder() async {
    await super.pickFolder();
    return pending.future;
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required FakeFolderPickerService picker,
  required InMemorySelectedMusicFolderRepository folderRepo,
  FakeAudioFileScanner? scanner,
  HostPlatform host = HostPlatform.linux,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        // No server connected: this screen's local half has to stand on its own.
        folderBrowsableSourcesProvider
            .overrideWithValue(const <FolderBrowsableMusicSource>[]),
        folderPickerServiceProvider.overrideWithValue(picker),
        selectedMusicFolderRepositoryProvider.overrideWithValue(folderRepo),
        musicLibraryRepositoryProvider
            .overrideWithValue(InMemoryMusicLibraryRepository()),
        audioFileScannerProvider.overrideWithValue(
          scanner ?? FakeAudioFileScanner(),
        ),
        hostPlatformProvider.overrideWithValue(host),
        // The scanned paths are fictional, so keep the tag reader and the stat
        // reader off the real file system: their I/O never completes against
        // pumpAndSettle's fake clock. Both have their own tests.
        localMetadataReaderProvider
            .overrideWithValue(const UnsupportedLocalMetadataReader()),
        localFileStatReaderProvider
            .overrideWithValue(const UnsupportedLocalFileStatReader()),
      ],
      child: const MaterialApp(home: FoldersScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

/// Settles the frame *and* lets the outcome snack bar time out, so no timer
/// outlives the test.
Future<void> _settleWithSnackBar(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pumpAndSettle(const Duration(seconds: 5));
}

/// Adding a music folder belongs to Folders, next to the folders already
/// configured. Library browses and searches the catalog and nothing else.
///
/// What these pin is the placement and the wiring behind it: the header action
/// and the empty state are the *same* command, and that command is the existing
/// `LocalMusicController` + folder picker rather than a second folder-management
/// path living on this screen. Persisting and scanning are covered by
/// multi_folder_library_test.dart; what matters here is that Folders drives them
/// and shows the result.
void main() {
  group('Folders ▸ Add folder', () {
    testWidgets('the header offers it, and says so out loud', (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await _pump(
        tester,
        picker: FakeFolderPickerService(),
        folderRepo: InMemorySelectedMusicFolderRepository(),
      );

      final Finder action = find.byKey(const Key('folders_add_folder'));
      expect(action, findsOneWidget);

      // Icon-only, so the tooltip is the action's only name: it has to reach a
      // pointer hovering it and a screen reader alike.
      expect(find.byTooltip('Add music folder'), findsOneWidget);
      final SemanticsData data = tester.getSemantics(action).getSemanticsData();
      expect('${data.label} ${data.tooltip}', contains('Add music folder'));

      semantics.dispose();
    });

    testWidgets('it runs the existing picker and scans what was chosen',
        (tester) async {
      final picker = FakeFolderPickerService(folder: '/music');
      final scanner = FakeAudioFileScanner(files: <String>['/music/a.mp3']);
      final folderRepo = InMemorySelectedMusicFolderRepository();
      await _pump(
        tester,
        picker: picker,
        folderRepo: folderRepo,
        scanner: scanner,
      );

      await tester.tap(find.byKey(const Key('folders_add_folder')));
      await _settleWithSnackBar(tester);

      expect(picker.pickCount, 1);
      expect(scanner.requestedFolders, <String>['/music']);
      expect(await folderRepo.getSelectedFolders(), <String>['/music']);
    });

    testWidgets('the view lists the folder that was just added',
        (tester) async {
      await _pump(
        tester,
        picker: FakeFolderPickerService(folder: '/music'),
        folderRepo: InMemorySelectedMusicFolderRepository(),
        scanner: FakeAudioFileScanner(files: <String>['/music/a.mp3']),
      );
      expect(find.text('No music folders yet'), findsOneWidget);

      await tester.tap(find.byKey(const Key('folders_add_folder')));
      await _settleWithSnackBar(tester);

      expect(find.text('On this device'), findsOneWidget);
      expect(find.text('/music'), findsOneWidget);
      expect(find.text('No music folders yet'), findsNothing);
    });

    testWidgets('the empty state offers the same action', (tester) async {
      final picker = FakeFolderPickerService(folder: '/music');
      final folderRepo = InMemorySelectedMusicFolderRepository();
      await _pump(tester, picker: picker, folderRepo: folderRepo);

      final Finder emptyAction =
          find.byKey(const Key('folders_empty_add_folder'));
      expect(emptyAction, findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Add folder'), findsOneWidget);

      await tester.tap(emptyAction);
      await _settleWithSnackBar(tester);

      // Same picker, same selection, same listing as the header action: one
      // command with two ways in, not two paths.
      expect(picker.pickCount, 1);
      expect(await folderRepo.getSelectedFolders(), <String>['/music']);
      expect(find.text('/music'), findsOneWidget);
    });

    testWidgets('cancelling the picker changes nothing', (tester) async {
      final picker = FakeFolderPickerService();
      final folderRepo =
          InMemorySelectedMusicFolderRepository(initialFolder: '/music');
      final scanner = FakeAudioFileScanner();
      await _pump(
        tester,
        picker: picker,
        folderRepo: folderRepo,
        scanner: scanner,
      );

      await tester.tap(find.byKey(const Key('folders_add_folder')));
      await _settleWithSnackBar(tester);

      expect(picker.pickCount, 1);
      expect(scanner.requestedFolders, isEmpty);
      expect(await folderRepo.getSelectedFolders(), <String>['/music']);
      expect(find.text('/music'), findsOneWidget);
    });

    testWidgets('the folders already configured are left where they are',
        (tester) async {
      final folderRepo =
          InMemorySelectedMusicFolderRepository(initialFolder: '/music');
      await _pump(
        tester,
        picker: _SequencedFolderPicker(<String>['/media/usb']),
        folderRepo: folderRepo,
        scanner: FakeAudioFileScanner(
          filesByFolder: <String, List<String>>{
            '/music': <String>['/music/a.mp3'],
            '/media/usb': <String>['/media/usb/b.mp3'],
          },
        ),
      );
      expect(find.text('/music'), findsOneWidget);

      await tester.tap(find.byKey(const Key('folders_add_folder')));
      await _settleWithSnackBar(tester);

      expect(
        await folderRepo.getSelectedFolders(),
        <String>['/music', '/media/usb'],
      );
      expect(find.text('/music'), findsOneWidget);
      expect(find.text('/media/usb'), findsOneWidget);
    });

    testWidgets('Android still holds a single grant at a time', (tester) async {
      // Android's local access is one SAF grant (or the device-wide mode), and
      // this entry point does not get to change that: the command it calls is
      // the same one Settings runs, which replaces the selection there.
      final folderRepo =
          InMemorySelectedMusicFolderRepository(initialFolder: '/sdcard/Music');
      await _pump(
        tester,
        picker: FakeFolderPickerService(folder: '/sdcard/Podcasts'),
        folderRepo: folderRepo,
        scanner: FakeAudioFileScanner(
          filesByFolder: <String, List<String>>{
            '/sdcard/Podcasts': <String>['/sdcard/Podcasts/a.mp3'],
          },
        ),
        host: HostPlatform.android,
      );

      await tester.tap(find.byKey(const Key('folders_add_folder')));
      await _settleWithSnackBar(tester);

      expect(
        await folderRepo.getSelectedFolders(),
        <String>['/sdcard/Podcasts'],
      );
      expect(find.text('/sdcard/Music'), findsNothing);
    });

    testWidgets('a configured folder is listed even with no server connected',
        (tester) async {
      // The local half of this screen stands alone: a desktop library with no
      // Jellyfin or Navidrome behind it still has folders to show.
      await _pump(
        tester,
        picker: FakeFolderPickerService(),
        folderRepo: InMemorySelectedMusicFolderRepository(
          initialFolders: <String>['/music', '/media/usb'],
        ),
      );

      expect(find.text('On this device'), findsOneWidget);
      expect(find.text('/music'), findsOneWidget);
      expect(find.text('/media/usb'), findsOneWidget);
      expect(find.text('No music folders yet'), findsNothing);
    });

    testWidgets('the action is greyed out while a pick is in flight',
        (tester) async {
      // One local-music command at a time, and "busy" is the controller's own
      // state rather than a second copy kept here, so a second tap cannot
      // open a second folder dialog on top of the first.
      final picker = _PendingFolderPicker();
      await _pump(
        tester,
        picker: picker,
        folderRepo: InMemorySelectedMusicFolderRepository(),
      );

      await tester.tap(find.byKey(const Key('folders_add_folder')));
      await tester.pump();

      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('folders_add_folder')))
            .onPressed,
        isNull,
      );

      picker.pending.complete(null);
      await _settleWithSnackBar(tester);

      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('folders_add_folder')))
            .onPressed,
        isNotNull,
      );
    });
  });
}
