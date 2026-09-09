import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/library_controller.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/local_scan_report_provider.dart';
import 'package:linthra/features/library/selected_folder_controller.dart';
import 'package:linthra/features/settings/source/local_music_controller.dart';

import 'fake_audio_file_scanner.dart';
import 'fake_folder_picker_service.dart';

/// The whole desktop multi-folder path, wired the way the app wires it: the
/// Settings actions, the selection store, the scan, and the catalog.
ProviderContainer _container({
  required InMemorySelectedMusicFolderRepository folderRepo,
  required InMemoryMusicLibraryRepository libraryRepo,
  required FakeAudioFileScanner scanner,
  FakeFolderPickerService? picker,
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      folderPickerServiceProvider
          .overrideWithValue(picker ?? FakeFolderPickerService()),
      selectedMusicFolderRepositoryProvider.overrideWithValue(folderRepo),
      musicLibraryRepositoryProvider.overrideWithValue(libraryRepo),
      audioFileScannerProvider.overrideWithValue(scanner),
      hostPlatformProvider.overrideWithValue(HostPlatform.linux),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<List<String>> _catalogUris(
  InMemoryMusicLibraryRepository repository,
) async {
  final List<Track> tracks = await repository.getAllTracks();
  return tracks.map((Track track) => track.uri).toList()..sort();
}

void main() {
  setUp(LocalScanDiagnostics.reset);
  tearDown(LocalScanDiagnostics.reset);

  group('a library spread over several folders', () {
    test('scans every selected folder into one catalog', () async {
      final libraryRepo = InMemoryMusicLibraryRepository();
      final container = _container(
        folderRepo: InMemorySelectedMusicFolderRepository(
          initialFolders: <String>['/music', '/media/usb'],
        ),
        libraryRepo: libraryRepo,
        scanner: FakeAudioFileScanner(
          filesByFolder: <String, List<String>>{
            '/music': <String>['/music/a.mp3'],
            '/media/usb': <String>['/media/usb/b.mp3'],
          },
        ),
      );
      await container.read(selectedFolderControllerProvider.future);

      await container.read(localMusicControllerProvider.notifier).rescan();

      expect(
        await _catalogUris(libraryRepo),
        <String>['/media/usb/b.mp3', '/music/a.mp3'],
      );
      expect(container.read(localScanReportProvider)?.importedTracks, 2);
      expect(container.read(localScanReportProvider)?.rootsScanned, 2);
    });

    test('adding a folder keeps the music already indexed', () async {
      final libraryRepo = InMemoryMusicLibraryRepository();
      final folderRepo =
          InMemorySelectedMusicFolderRepository(initialFolder: '/music');
      final container = _container(
        folderRepo: folderRepo,
        libraryRepo: libraryRepo,
        picker: FakeFolderPickerService(folder: '/media/usb'),
        scanner: FakeAudioFileScanner(
          filesByFolder: <String, List<String>>{
            '/music': <String>['/music/a.mp3'],
            '/media/usb': <String>['/media/usb/b.mp3'],
          },
        ),
      );
      await container.read(selectedFolderControllerProvider.future);
      final local = container.read(localMusicControllerProvider.notifier);
      await local.rescan();

      await local.addFolder();

      expect(
        await folderRepo.getSelectedFolders(),
        <String>['/music', '/media/usb'],
      );
      expect(
        await _catalogUris(libraryRepo),
        <String>['/media/usb/b.mp3', '/music/a.mp3'],
      );
    });

    test('a folder inside a selected one imports nothing twice', () async {
      final libraryRepo = InMemoryMusicLibraryRepository();
      final scanner = FakeAudioFileScanner(
        filesByFolder: <String, List<String>>{
          '/music': <String>['/music/live/a.mp3', '/music/b.mp3'],
          '/music/live': <String>['/music/live/a.mp3'],
        },
      );
      final container = _container(
        folderRepo: InMemorySelectedMusicFolderRepository(
          initialFolders: <String>['/music', '/music/live'],
        ),
        libraryRepo: libraryRepo,
        scanner: scanner,
      );
      await container.read(selectedFolderControllerProvider.future);

      await container.read(localMusicControllerProvider.notifier).rescan();

      expect(scanner.requestedFolders, <String>['/music']);
      expect(
        await _catalogUris(libraryRepo),
        <String>['/music/b.mp3', '/music/live/a.mp3'],
      );
    });

    test('removing one folder removes only its tracks', () async {
      final libraryRepo = InMemoryMusicLibraryRepository();
      final folderRepo = InMemorySelectedMusicFolderRepository(
        initialFolders: <String>['/music', '/media/usb'],
      );
      final container = _container(
        folderRepo: folderRepo,
        libraryRepo: libraryRepo,
        scanner: FakeAudioFileScanner(
          filesByFolder: <String, List<String>>{
            '/music': <String>['/music/a.mp3'],
            '/media/usb': <String>['/media/usb/b.mp3'],
          },
        ),
      );
      await container.read(selectedFolderControllerProvider.future);
      final local = container.read(localMusicControllerProvider.notifier);
      await local.rescan();

      await local.removeFolder('/media/usb');

      expect(await folderRepo.getSelectedFolders(), <String>['/music']);
      expect(await _catalogUris(libraryRepo), <String>['/music/a.mp3']);
    });

    test('removing the last folder empties the local catalog', () async {
      final libraryRepo = InMemoryMusicLibraryRepository();
      final folderRepo =
          InMemorySelectedMusicFolderRepository(initialFolder: '/music');
      final container = _container(
        folderRepo: folderRepo,
        libraryRepo: libraryRepo,
        scanner: FakeAudioFileScanner(
          filesByFolder: <String, List<String>>{
            '/music': <String>['/music/a.mp3'],
          },
        ),
      );
      await container.read(selectedFolderControllerProvider.future);
      final local = container.read(localMusicControllerProvider.notifier);
      await local.rescan();

      await local.removeFolder('/music');

      expect(await folderRepo.getSelectedFolders(), isEmpty);
      expect(await libraryRepo.getAllTracks(), isEmpty);
    });

    test('an unplugged drive keeps its music while the rest refreshes',
        () async {
      final libraryRepo = InMemoryMusicLibraryRepository();
      final container = _container(
        folderRepo: InMemorySelectedMusicFolderRepository(
          initialFolders: <String>['/music', '/media/usb'],
        ),
        libraryRepo: libraryRepo,
        scanner: FakeAudioFileScanner(
          filesByFolder: <String, List<String>>{
            '/music': <String>['/music/a.mp3'],
            '/media/usb': <String>['/media/usb/b.mp3'],
          },
        ),
      );
      await container.read(selectedFolderControllerProvider.future);
      await container.read(localMusicControllerProvider.notifier).rescan();

      // The drive goes away, a new file lands in the folder that is still
      // there, and the user rescans.
      final offline = _container(
        folderRepo: InMemorySelectedMusicFolderRepository(
          initialFolders: <String>['/music', '/media/usb'],
        ),
        libraryRepo: libraryRepo,
        scanner: FakeAudioFileScanner(
          filesByFolder: <String, List<String>>{
            '/music': <String>['/music/a.mp3', '/music/new.mp3'],
          },
          unavailable: <String>{'/media/usb'},
        ),
      );
      await offline.read(selectedFolderControllerProvider.future);
      await offline.read(localMusicControllerProvider.notifier).rescan();

      expect(
        await _catalogUris(libraryRepo),
        <String>['/media/usb/b.mp3', '/music/a.mp3', '/music/new.mp3'],
      );
      final report = offline.read(localScanReportProvider);
      expect(report?.isPartial, isTrue);
      expect(report?.rootsUnavailable, 1);
      expect(report?.hadError, isFalse);
      expect(
        offline.read(localMusicControllerProvider).message,
        contains('could not be read'),
      );
    });

    test('every folder being unreachable leaves the catalog untouched',
        () async {
      final libraryRepo = InMemoryMusicLibraryRepository();
      final container = _container(
        folderRepo: InMemorySelectedMusicFolderRepository(
          initialFolders: <String>['/music', '/media/usb'],
        ),
        libraryRepo: libraryRepo,
        scanner: FakeAudioFileScanner(
          filesByFolder: <String, List<String>>{
            '/music': <String>['/music/a.mp3'],
            '/media/usb': <String>['/media/usb/b.mp3'],
          },
        ),
      );
      await container.read(selectedFolderControllerProvider.future);
      await container.read(localMusicControllerProvider.notifier).rescan();

      final offline = _container(
        folderRepo: InMemorySelectedMusicFolderRepository(
          initialFolders: <String>['/music', '/media/usb'],
        ),
        libraryRepo: libraryRepo,
        scanner: FakeAudioFileScanner(
          unavailable: <String>{'/music', '/media/usb'},
        ),
      );
      await offline.read(selectedFolderControllerProvider.future);
      await offline.read(localMusicControllerProvider.notifier).rescan();

      expect(
        await _catalogUris(libraryRepo),
        <String>['/media/usb/b.mp3', '/music/a.mp3'],
      );
      expect(offline.read(localScanReportProvider)?.hadError, isTrue);
      expect(offline.read(localMusicControllerProvider).isError, isTrue);
    });

    test('the selection survives a restart', () async {
      final folderRepo = InMemorySelectedMusicFolderRepository(
        initialFolders: <String>['/music', '/media/usb'],
      );
      final first = _container(
        folderRepo: folderRepo,
        libraryRepo: InMemoryMusicLibraryRepository(),
        scanner: FakeAudioFileScanner(),
      );
      await first.read(selectedFolderControllerProvider.future);

      // A second container over the same store is what a restart looks like.
      final restarted = _container(
        folderRepo: folderRepo,
        libraryRepo: InMemoryMusicLibraryRepository(),
        scanner: FakeAudioFileScanner(),
      );

      expect(
        await restarted.read(selectedFolderControllerProvider.future),
        <String>['/music', '/media/usb'],
      );
    });

    test('a rescan drops a file deleted from a readable folder', () async {
      final libraryRepo = InMemoryMusicLibraryRepository();
      final container = _container(
        folderRepo: InMemorySelectedMusicFolderRepository(
          initialFolders: <String>['/music', '/media/usb'],
        ),
        libraryRepo: libraryRepo,
        scanner: FakeAudioFileScanner(
          filesByFolder: <String, List<String>>{
            '/music': <String>['/music/a.mp3', '/music/gone.mp3'],
            '/media/usb': <String>['/media/usb/b.mp3'],
          },
        ),
      );
      await container.read(selectedFolderControllerProvider.future);
      await container.read(localMusicControllerProvider.notifier).rescan();

      final rescanned = _container(
        folderRepo: InMemorySelectedMusicFolderRepository(
          initialFolders: <String>['/music', '/media/usb'],
        ),
        libraryRepo: libraryRepo,
        scanner: FakeAudioFileScanner(
          filesByFolder: <String, List<String>>{
            '/music': <String>['/music/a.mp3'],
            '/media/usb': <String>['/media/usb/b.mp3'],
          },
        ),
      );
      await rescanned.read(selectedFolderControllerProvider.future);
      await rescanned.read(localMusicControllerProvider.notifier).rescan();

      expect(
        await _catalogUris(libraryRepo),
        <String>['/media/usb/b.mp3', '/music/a.mp3'],
      );
    });

    test('the library screen keeps working with one folder', () async {
      // The single-folder path is what every existing install has; it must not
      // change behavior just because the plumbing now takes a list.
      final libraryRepo = InMemoryMusicLibraryRepository();
      final container = _container(
        folderRepo: InMemorySelectedMusicFolderRepository(),
        libraryRepo: libraryRepo,
        picker: FakeFolderPickerService(folder: '/music'),
        scanner: FakeAudioFileScanner(
          filesByFolder: <String, List<String>>{
            '/music': <String>['/music/a.mp3'],
          },
        ),
      );
      await container.read(selectedFolderControllerProvider.future);

      await container.read(localMusicControllerProvider.notifier).pickFolder();

      expect(await _catalogUris(libraryRepo), <String>['/music/a.mp3']);
      expect(container.read(localScanReportProvider)?.rootsScanned, 1);
      expect(container.read(localScanReportProvider)?.isPartial, isFalse);
      expect(container.read(libraryControllerProvider).tracks, hasLength(1));
    });
  });
}
