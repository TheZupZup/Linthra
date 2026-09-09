import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/sources/local/android_media_library.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/directory_readability.dart';
import 'package:linthra/core/sources/local/folder_location.dart';
import 'package:linthra/core/sources/local/folder_scan_exception.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/core/sources/local/local_scan_report.dart';
import 'package:linthra/core/sources/local/saf_document_lister.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
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

/// A scanner whose answer can change between scans, so one test can walk a
/// folder that is readable and then lose it.
class _MutableScanner implements AudioFileScanner {
  _MutableScanner({this.files = const <String>[]});

  List<String> files;
  Object? error;

  @override
  Future<List<String>> listFiles(String folder) async {
    final Object? failure = error;
    if (failure != null) {
      throw failure;
    }
    return files;
  }
}

/// A scriptable stand-in for Android's MediaStore seam: the permission answer
/// and the device-audio result (rows, or a thrown failure) are both set by the
/// test, so a switch to device-wide mode can be walked without a device.
class _FakeAndroidMediaLibrary implements AndroidMediaLibrary {
  _FakeAndroidMediaLibrary({
    this.status = AndroidMusicPermissionStatus.allowed,
    this.documents = const <SafAudioDocument>[],
    this.failure,
  });

  AndroidMusicPermissionStatus status;
  List<SafAudioDocument> documents;
  Object? failure;
  int requestCount = 0;

  @override
  Future<AndroidMusicPermissionStatus> permissionStatus() async => status;

  @override
  Future<AndroidMusicPermissionStatus> requestPermission() async {
    requestCount++;
    return status;
  }

  @override
  Future<void> openAppSettings() async {}

  @override
  Future<SafScanResult> listDeviceAudio() async {
    final Object? error = failure;
    if (error != null) {
      throw error;
    }
    return SafScanResult(
      documents: documents,
      filesVisited: documents.length,
    );
  }
}

const SafAudioDocument _deviceSong = SafAudioDocument(
  uri: 'content://media/external/audio/media/7',
  name: 'Device song.mp3',
  mimeType: 'audio/mpeg',
);

/// The desktop access probe, likewise flippable mid-test.
class _MutableReadability implements DirectoryReadability {
  _MutableReadability(this.readable);

  bool readable;

  @override
  Future<bool> canList(String path) async => readable;
}

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

/// What is actually on disk (well, in the in-memory repository) rather than the
/// controller's in-flight state — the distinction the transactional switch is
/// about.
Future<List<String>> folderRepoValues(ProviderContainer container) =>
    container.read(selectedMusicFolderRepositoryProvider).getSelectedFolders();

/// The single selected folder, for the cases that are about one selection.
Future<String?> folderRepoValue(ProviderContainer container) async {
  final List<String> folders = await folderRepoValues(container);
  return folders.isEmpty ? null : folders.first;
}

void main() {
  setUp(LocalScanDiagnostics.reset);
  tearDown(LocalScanDiagnostics.reset);

  group('LocalMusicController', () {
    test('losing access to a desktop folder is noticed on the next scan',
        () async {
      // Access is lost while the app runs — a drive unplugged, a Flatpak portal
      // document revoked — and the *selection* never changes when that happens.
      // A rescan is the user's natural way to find out, so the access line has
      // to be re-probed then rather than staying on the answer cached when the
      // folder was first picked.
      final scanner = _MutableScanner(files: const <String>['/music/a.mp3']);
      final readability = _MutableReadability(true);
      final container = ProviderContainer(
        overrides: [
          folderPickerServiceProvider
              .overrideWithValue(FakeFolderPickerService(folder: '/music')),
          selectedMusicFolderRepositoryProvider
              .overrideWithValue(InMemorySelectedMusicFolderRepository()),
          musicLibraryRepositoryProvider
              .overrideWithValue(InMemoryMusicLibraryRepository()),
          audioFileScannerProvider.overrideWithValue(scanner),
          directoryReadabilityProvider.overrideWithValue(readability),
          hostPlatformProvider.overrideWithValue(HostPlatform.linux),
        ],
      );
      addTearDown(container.dispose);

      await container.read(localMusicControllerProvider.notifier).pickFolder();
      expect(
        await container.read(localFolderAccessProvider.future),
        <String, bool>{'/music': true},
      );

      // The folder goes away, then the user hits Rescan.
      readability.readable = false;
      scanner.error = const FolderScanException(
        "Linthra couldn't find the selected folder.",
      );
      await container.read(localMusicControllerProvider.notifier).rescan();

      expect(
        container.read(localScanReportProvider)?.error,
        LocalScanError.folderUnavailable,
      );
      // The card's lost-access line now shows, instead of the folder still
      // reading as healthy.
      expect(
        await container.read(localFolderAccessProvider.future),
        <String, bool>{'/music': false},
      );
    });

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
        <String>['/music'],
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
        isEmpty,
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

    // Switching an existing folder user to device-wide mode has to be all or
    // nothing (#550): the catalog is deliberately preserved when a scan fails,
    // so persisting the MediaStore sentinel before the first scan succeeded
    // would leave the app configured for MediaStore while still showing the old
    // folder's tracks — with the folder reference needed to rescan them gone.
    group('switching to device-wide music', () {
      ProviderContainer androidContainer({
        required _FakeAndroidMediaLibrary media,
        required InMemorySelectedMusicFolderRepository folderRepo,
        required InMemoryMusicLibraryRepository libraryRepo,
        FakeAudioFileScanner? scanner,
      }) {
        final container = ProviderContainer(
          overrides: [
            hostPlatformProvider.overrideWithValue(HostPlatform.android),
            androidMediaLibraryProvider.overrideWithValue(media),
            selectedMusicFolderRepositoryProvider.overrideWithValue(folderRepo),
            musicLibraryRepositoryProvider.overrideWithValue(libraryRepo),
            audioFileScannerProvider
                .overrideWithValue(scanner ?? FakeAudioFileScanner()),
            folderPickerServiceProvider
                .overrideWithValue(FakeFolderPickerService()),
          ],
        );
        addTearDown(container.dispose);
        return container;
      }

      test('a successful first scan persists the MediaStore selection',
          () async {
        final libraryRepo = InMemoryMusicLibraryRepository();
        final container = androidContainer(
          media: _FakeAndroidMediaLibrary(
            documents: const <SafAudioDocument>[_deviceSong],
          ),
          folderRepo:
              InMemorySelectedMusicFolderRepository(initialFolder: '/music'),
          libraryRepo: libraryRepo,
        );
        await container.read(selectedFolderControllerProvider.future);

        await container
            .read(localMusicControllerProvider.notifier)
            .useAllDeviceMusic();

        expect(
          container.read(selectedFolderControllerProvider).valueOrNull,
          <String>[FolderLocation.androidMediaStoreAudio],
        );
        expect(await folderRepoValue(container), 'mediastore://audio');
        expect(await libraryRepo.getAllTracks(), hasLength(1));
        expect(
          container.read(localMusicControllerProvider).message,
          contains('from this device'),
        );
      });

      test('a failed first scan leaves the previous folder selected', () async {
        final container = androidContainer(
          media: _FakeAndroidMediaLibrary(
            failure: const FolderScanException(
              "Couldn't read Android's shared music library.",
              code: 'media_store_failed',
            ),
          ),
          folderRepo:
              InMemorySelectedMusicFolderRepository(initialFolder: '/music'),
          libraryRepo: InMemoryMusicLibraryRepository(),
        );
        await container.read(selectedFolderControllerProvider.future);

        await container
            .read(localMusicControllerProvider.notifier)
            .useAllDeviceMusic();

        expect(
          container.read(selectedFolderControllerProvider).valueOrNull,
          <String>['/music'],
          reason: 'the folder must survive a failed switch',
        );
        expect(await folderRepoValue(container), '/music');
        // A provider fault is not a permission problem, and says so.
        expect(
          container.read(localScanReportProvider)?.error,
          LocalScanError.unexpected,
        );
        expect(container.read(localMusicControllerProvider).isError, isTrue);
      });

      test('a failed first scan preserves the already indexed catalog',
          () async {
        final libraryRepo = InMemoryMusicLibraryRepository();
        final container = androidContainer(
          media: _FakeAndroidMediaLibrary(
            failure: const FolderScanException(
              "Couldn't read Android's shared music library.",
              code: 'media_store_failed',
            ),
          ),
          folderRepo: InMemorySelectedMusicFolderRepository(),
          libraryRepo: libraryRepo,
          scanner: FakeAudioFileScanner(files: const <String>['/music/a.mp3']),
        );
        // Index a folder the normal way first, then attempt the switch.
        await container
            .read(selectedFolderControllerProvider.notifier)
            .setAndPersist('/music');
        await container.read(localMusicControllerProvider.notifier).rescan();
        expect(await libraryRepo.getAllTracks(), hasLength(1));

        await container
            .read(localMusicControllerProvider.notifier)
            .useAllDeviceMusic();

        expect(
          await libraryRepo.getAllTracks(),
          hasLength(1),
          reason: 'a failed switch must not touch the indexed music',
        );
        expect(
          container.read(selectedFolderControllerProvider).valueOrNull,
          <String>['/music'],
        );
      });

      test('with no previous folder, a successful scan still selects it',
          () async {
        final container = androidContainer(
          media: _FakeAndroidMediaLibrary(
            documents: const <SafAudioDocument>[_deviceSong],
          ),
          folderRepo: InMemorySelectedMusicFolderRepository(),
          libraryRepo: InMemoryMusicLibraryRepository(),
        );
        await container.read(selectedFolderControllerProvider.future);

        await container
            .read(localMusicControllerProvider.notifier)
            .useAllDeviceMusic();

        expect(
          container.read(selectedFolderControllerProvider).valueOrNull,
          <String>[FolderLocation.androidMediaStoreAudio],
        );
      });

      test('a denied permission never changes the selected source', () async {
        final media = _FakeAndroidMediaLibrary(
          status: AndroidMusicPermissionStatus.denied,
        );
        final container = androidContainer(
          media: media,
          folderRepo:
              InMemorySelectedMusicFolderRepository(initialFolder: '/music'),
          libraryRepo: InMemoryMusicLibraryRepository(),
        );
        await container.read(selectedFolderControllerProvider.future);

        await container
            .read(localMusicControllerProvider.notifier)
            .useAllDeviceMusic();

        expect(media.requestCount, 1);
        expect(
          container.read(selectedFolderControllerProvider).valueOrNull,
          <String>['/music'],
        );
        expect(await folderRepoValue(container), '/music');
        expect(
          container.read(localMusicControllerProvider).message,
          contains('was not granted'),
        );
      });
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
        isEmpty,
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
