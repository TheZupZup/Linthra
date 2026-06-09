import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/local_scan_report_provider.dart';
import 'package:linthra/features/library/selected_folder_controller.dart';
import 'package:linthra/features/settings/source/local_music_controller.dart';

import '../../library/fake_audio_file_scanner.dart';
import '../../library/fake_folder_picker_service.dart';

ProviderContainer _container({
  required FakeFolderPickerService picker,
  required InMemorySelectedMusicFolderRepository folderRepo,
  required InMemoryMusicLibraryRepository libraryRepo,
  required FakeAudioFileScanner scanner,
}) {
  final container = ProviderContainer(
    overrides: [
      folderPickerServiceProvider.overrideWithValue(picker),
      selectedMusicFolderRepositoryProvider.overrideWithValue(folderRepo),
      musicLibraryRepositoryProvider.overrideWithValue(libraryRepo),
      audioFileScannerProvider.overrideWithValue(scanner),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(LocalScanDiagnostics.reset);
  tearDown(LocalScanDiagnostics.reset);

  group('LocalMusicController', () {
    test('pickFolder scans the chosen folder and imports its audio', () async {
      final libraryRepo = InMemoryMusicLibraryRepository();
      final container = _container(
        picker: FakeFolderPickerService(folder: '/music'),
        folderRepo: InMemorySelectedMusicFolderRepository(),
        libraryRepo: libraryRepo,
        scanner: FakeAudioFileScanner(
          files: const <String>['/music/a.mp3', '/music/cover.jpg'],
        ),
      );

      await container.read(localMusicControllerProvider.notifier).pickFolder();

      final tracks = await libraryRepo.getAllTracks();
      expect(tracks, hasLength(1));
      expect(tracks.single.title, 'a');

      final state = container.read(localMusicControllerProvider);
      expect(state.busy, isFalse);
      expect(state.isError, isFalse);
      expect(state.message, contains('Added 1 track'));

      // The selection was persisted and the scan report recorded.
      expect(
        container.read(selectedFolderControllerProvider).valueOrNull,
        '/music',
      );
      expect(container.read(localScanReportProvider)?.importedTracks, 1);
    });

    test('a cancelled pick changes nothing and says nothing', () async {
      final container = _container(
        picker: FakeFolderPickerService(folder: null),
        folderRepo: InMemorySelectedMusicFolderRepository(),
        libraryRepo: InMemoryMusicLibraryRepository(),
        scanner: FakeAudioFileScanner(),
      );

      await container.read(localMusicControllerProvider.notifier).pickFolder();

      final state = container.read(localMusicControllerProvider);
      expect(state.busy, isFalse);
      expect(state.message, isNull);
      expect(
        container.read(selectedFolderControllerProvider).valueOrNull,
        isNull,
      );
    });

    test('a folder with no audio reports nothing playable, not an error',
        () async {
      final container = _container(
        picker: FakeFolderPickerService(folder: '/music'),
        folderRepo: InMemorySelectedMusicFolderRepository(),
        libraryRepo: InMemoryMusicLibraryRepository(),
        scanner: FakeAudioFileScanner(
          files: const <String>['/music/cover.jpg', '/music/notes.txt'],
        ),
      );

      await container.read(localMusicControllerProvider.notifier).pickFolder();

      final state = container.read(localMusicControllerProvider);
      expect(state.isError, isFalse);
      expect(state.message, contains('No playable audio'));
    });

    test('rescan re-scans the selected folder without opening the picker',
        () async {
      final picker = FakeFolderPickerService(folder: '/music');
      final libraryRepo = InMemoryMusicLibraryRepository();
      final container = _container(
        picker: picker,
        folderRepo:
            InMemorySelectedMusicFolderRepository(initialFolder: '/music'),
        libraryRepo: libraryRepo,
        scanner: FakeAudioFileScanner(files: const <String>['/music/a.mp3']),
      );
      await container.read(selectedFolderControllerProvider.future);

      await container.read(localMusicControllerProvider.notifier).rescan();

      expect(picker.pickCount, 0, reason: 'rescan must not open the chooser');
      expect((await libraryRepo.getAllTracks()), hasLength(1));
      expect(container.read(localMusicControllerProvider).message,
          contains('Added 1 track'));
    });

    test('rescan with no folder selected is a no-op', () async {
      final container = _container(
        picker: FakeFolderPickerService(),
        folderRepo: InMemorySelectedMusicFolderRepository(),
        libraryRepo: InMemoryMusicLibraryRepository(),
        scanner: FakeAudioFileScanner(),
      );
      await container.read(selectedFolderControllerProvider.future);

      await container.read(localMusicControllerProvider.notifier).rescan();

      expect(container.read(localMusicControllerProvider).message, isNull);
    });

    test('forget clears the selection, the local catalog, and the report',
        () async {
      final libraryRepo = InMemoryMusicLibraryRepository();
      final container = _container(
        picker: FakeFolderPickerService(folder: '/music'),
        folderRepo: InMemorySelectedMusicFolderRepository(),
        libraryRepo: libraryRepo,
        scanner: FakeAudioFileScanner(files: const <String>['/music/a.mp3']),
      );

      await container.read(localMusicControllerProvider.notifier).pickFolder();
      expect(await libraryRepo.getAllTracks(), hasLength(1));

      await container.read(localMusicControllerProvider.notifier).forget();

      expect(
        container.read(selectedFolderControllerProvider).valueOrNull,
        isNull,
      );
      expect(await libraryRepo.getAllTracks(), isEmpty);
      expect(container.read(localScanReportProvider), isNull);
      expect(
        container.read(localMusicControllerProvider).message,
        contains('forgotten'),
      );
    });
  });
}
