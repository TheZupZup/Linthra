import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/sources/local/directory_readability.dart';
import 'package:linthra/core/sources/local/folder_location.dart';
import 'package:linthra/core/sources/local/local_file_stat.dart';
import 'package:linthra/core/sources/local/local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_root_fault.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/library_screen.dart';

import 'fake_audio_file_scanner.dart';
import 'fake_folder_picker_service.dart';
import 'fake_music_library_repository.dart';

Future<void> _pumpScreen(
  WidgetTester tester,
  FakeMusicLibraryRepository repository,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        musicLibraryRepositoryProvider.overrideWithValue(repository),
      ],
      child: const MaterialApp(home: LibraryScreen()),
    ),
  );
}

void main() {
  group('LibraryScreen', () {
    testWidgets('shows a spinner while loading', (tester) async {
      await _pumpScreen(tester, FakeMusicLibraryRepository());

      // Before the async load settles, the loading indicator is visible.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpAndSettle();
    });

    testWidgets('prompts to select a folder when none is chosen', (
      tester,
    ) async {
      await _pumpScreen(tester, FakeMusicLibraryRepository());
      await tester.pumpAndSettle();

      expect(find.text('No music folder selected'), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, 'Select a folder'),
        findsOneWidget,
      );
    });

    testWidgets('lists tracks with title and subtitle', (tester) async {
      await _pumpScreen(
        tester,
        FakeMusicLibraryRepository(
          tracks: <Track>[
            const Track(
              id: '1',
              title: 'Song One',
              uri: 'file:///song1.mp3',
              artistName: 'Artist A',
              albumName: 'Album X',
            ),
            const Track(id: '2', title: 'Song Two', uri: 'file:///song2.mp3'),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Song One'), findsOneWidget);
      expect(find.text('Artist A • Album X'), findsOneWidget);
      // No metadata: falls back to the uri/path.
      expect(find.text('Song Two'), findsOneWidget);
      expect(find.text('file:///song2.mp3'), findsOneWidget);
    });

    testWidgets('shows an error state with a retry action', (tester) async {
      await _pumpScreen(
        tester,
        FakeMusicLibraryRepository(error: Exception('disk on fire')),
      );
      await tester.pumpAndSettle();

      expect(find.text("Couldn't load your library"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('picking a folder scans it and populates the list', (
      tester,
    ) async {
      final scanner = FakeAudioFileScanner(
        files: <String>['/music/Hello.mp3', '/music/notes.txt'],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            musicLibraryRepositoryProvider.overrideWithValue(
              InMemoryMusicLibraryRepository(),
            ),
            audioFileScannerProvider.overrideWithValue(scanner),
            folderPickerServiceProvider.overrideWithValue(
              FakeFolderPickerService(folder: '/music'),
            ),
            // The scanner's paths are fictional, so let the reader be inert
            // rather than have this widget test touch the real filesystem.
            // Reading tags is genuinely asynchronous (it has to be, or a scan
            // starves the event loop), and pumpAndSettle drives a fake clock
            // that real I/O never completes against. The reader's own
            // behaviour is covered in
            // test/core/sources/local/filesystem_local_metadata_reader_test.dart.
            localMetadataReaderProvider.overrideWithValue(
              const UnsupportedLocalMetadataReader(),
            ),
            // Same reason, for the stat an incremental scan does before it
            // decides whether to parse: FileStat.stat on a fictional path is
            // real asynchronous I/O, and pumpAndSettle's fake clock never sees
            // it finish. Answering nothing means every file is parsed, which
            // is what this test wants anyway. The incremental behaviour has
            // its own tests.
            localFileStatReaderProvider.overrideWithValue(
              const UnsupportedLocalFileStatReader(),
            ),
          ],
          child: const MaterialApp(home: LibraryScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No music folder selected'), findsOneWidget);

      // Tap the empty state's own action: the fake picker returns '/music',
      // which is then scanned. Adding a folder from a header action is the
      // Folders screen's job now; what an empty Library still offers is the
      // obvious next step out of having nothing.
      await tester.tap(find.widgetWithText(FilledButton, 'Select a folder'));
      await tester.pumpAndSettle();

      expect(scanner.requestedFolder, '/music');
      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('No music folder selected'), findsNothing);
    });

    testWidgets('cancelling the picker leaves the empty state untouched', (
      tester,
    ) async {
      final picker = FakeFolderPickerService(folder: null);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            musicLibraryRepositoryProvider.overrideWithValue(
              InMemoryMusicLibraryRepository(),
            ),
            folderPickerServiceProvider.overrideWithValue(picker),
          ],
          child: const MaterialApp(home: LibraryScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Select a folder'));
      await tester.pumpAndSettle();

      expect(picker.pickCount, 1);
      expect(find.text('No music folder selected'), findsOneWidget);
    });

    testWidgets('the header carries no folder action', (tester) async {
      // Managing local music folders moved to Folders, which is what the
      // action was always about; Library is for browsing and searching. The
      // catalog is non-empty here so the tabs are showing: the
      // Songs/Albums/Artists header, the one that used to carry it.
      await _pumpScreen(
        tester,
        FakeMusicLibraryRepository(
          tracks: <Track>[
            const Track(id: '1', title: 'Song One', uri: 'file:///song1.mp3'),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Songs'), findsOneWidget);
      expect(find.byTooltip('Select music folder'), findsNothing);
      expect(find.byIcon(Icons.create_new_folder_outlined), findsNothing);
    });

    testWidgets('an empty device-wide library never points at a folder', (
      tester,
    ) async {
      // Android's MediaStore sentinel is not a filesystem path and not a folder
      // the user can reselect (#550). An empty result there has to read as "the
      // device reported no music", not as a folder that needs re-picking.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            musicLibraryRepositoryProvider.overrideWithValue(
              InMemoryMusicLibraryRepository(),
            ),
            selectedMusicFolderRepositoryProvider.overrideWithValue(
              InMemorySelectedMusicFolderRepository(
                initialFolder: FolderLocation.androidMediaStoreAudio,
              ),
            ),
          ],
          child: const MaterialApp(home: LibraryScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('reported no audio on this device'),
        findsOneWidget,
      );
      expect(find.text('Rescan this device'), findsOneWidget);
      expect(find.text('Use a folder instead'), findsOneWidget);
      expect(find.text('Rescan folder'), findsNothing);
      expect(find.text('Change folder'), findsNothing);
      expect(find.text('Choose the folder again so Linthra can read it.'),
          findsNothing);
      expect(find.textContaining('mediastore://'), findsNothing);
    });

    testWidgets('a folder it cannot read is explained, not shown as empty', (
      tester,
    ) async {
      // The heart of #414. An empty library and an unplugged drive look
      // identical until somebody says which it is, and the fixes are different.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            musicLibraryRepositoryProvider.overrideWithValue(
              InMemoryMusicLibraryRepository(),
            ),
            selectedMusicFolderRepositoryProvider.overrideWithValue(
              InMemorySelectedMusicFolderRepository(
                initialFolder: '/media/usb/Music',
              ),
            ),
            hostPlatformProvider.overrideWithValue(HostPlatform.linux),
            directoryReadabilityProvider
                .overrideWithValue(const _Unreadable(LocalRootFault.missing)),
          ],
          child: const MaterialApp(home: LibraryScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text("Your music folder isn't available"), findsOneWidget);
      expect(find.text('Folder not found'), findsOneWidget);
      expect(find.text('/media/usb/Music'), findsOneWidget);
      // The two non-destructive fixes are here; the one that throws a source
      // away stays on the Settings card.
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Select folder again'), findsOneWidget);
      expect(find.text('Remove folder'), findsNothing);
      // And none of the "you have no music" wording.
      expect(find.text('No music found'), findsNothing);
      expect(find.text('No music folder selected'), findsNothing);
    });

    testWidgets('a permission problem is not described as a missing folder', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            musicLibraryRepositoryProvider.overrideWithValue(
              InMemoryMusicLibraryRepository(),
            ),
            selectedMusicFolderRepositoryProvider.overrideWithValue(
              InMemorySelectedMusicFolderRepository(
                initialFolder: '/home/me/Music',
              ),
            ),
            hostPlatformProvider.overrideWithValue(HostPlatform.linux),
            directoryReadabilityProvider.overrideWithValue(
              const _Unreadable(LocalRootFault.permissionDenied),
            ),
          ],
          child: const MaterialApp(home: LibraryScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Permission denied'), findsOneWidget);
      expect(find.text('Folder not found'), findsNothing);
    });
  });
}

/// Reports every folder as unreadable for one fixed reason, so the screen's
/// recovery state can be staged without a drive to unplug.
class _Unreadable implements DirectoryReadability {
  const _Unreadable(this.fault);

  final LocalRootFault fault;

  @override
  Future<LocalRootFault?> inspect(String path) async => fault;
}
