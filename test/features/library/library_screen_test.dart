import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
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
          ],
          child: const MaterialApp(home: LibraryScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No music folder selected'), findsOneWidget);

      // Tap the folder action: the fake picker returns '/music', which is then
      // scanned.
      await tester.tap(find.byTooltip('Select music folder'));
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

      await tester.tap(find.byTooltip('Select music folder'));
      await tester.pumpAndSettle();

      expect(picker.pickCount, 1);
      expect(find.text('No music folder selected'), findsOneWidget);
    });
  });
}
