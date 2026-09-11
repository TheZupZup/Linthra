// The watcher wired into the app graph (#409): the selection drives what is
// watched, a change drives the incremental scan, and the container's disposal
// releases the watches.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/local_directory_watch.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/local_library_watch_service.dart';
import 'package:linthra/features/library/selected_folder_controller.dart';

import 'fake_folder_picker_service.dart';

/// A filesystem whose contents change between scans, which is the whole point
/// here: the container holds one scanner for its lifetime, so a test that adds
/// a file has to change what that scanner answers rather than swap it out.
class _MutableScanner implements AudioFileScanner {
  _MutableScanner(this.filesByFolder);

  Map<String, List<String>> filesByFolder;

  @override
  Future<List<String>> listFiles(String folder) async =>
      filesByFolder[folder] ?? const <String>[];
}

class _FakeWatchFactory implements DirectoryWatchFactory {
  final Map<String, StreamController<LocalDirectoryChange>> controllers =
      <String, StreamController<LocalDirectoryChange>>{};
  final List<String> cancelled = <String>[];

  @override
  Stream<LocalDirectoryChange> watch(String root) {
    final controller = StreamController<LocalDirectoryChange>(
      onCancel: () => cancelled.add(root),
    );
    controllers[root] = controller;
    return controller.stream;
  }

  void emit(String root, String path) =>
      controllers[root]!.add(LocalDirectoryChange(path));
}

void main() {
  setUp(LocalScanDiagnostics.reset);
  tearDown(LocalScanDiagnostics.reset);

  late _FakeWatchFactory fs;
  late _MutableScanner files;
  late InMemoryMusicLibraryRepository catalog;
  late InMemorySelectedMusicFolderRepository selection;

  ProviderContainer container({
    HostPlatform platform = HostPlatform.linux,
    List<String> roots = const <String>['/music'],
  }) {
    selection = InMemorySelectedMusicFolderRepository(initialFolders: roots);
    return ProviderContainer(
      overrides: <Override>[
        folderPickerServiceProvider
            .overrideWithValue(FakeFolderPickerService()),
        selectedMusicFolderRepositoryProvider.overrideWithValue(selection),
        musicLibraryRepositoryProvider.overrideWithValue(catalog),
        audioFileScannerProvider.overrideWithValue(files),
        directoryWatchFactoryProvider.overrideWithValue(fs),
        hostPlatformProvider.overrideWithValue(platform),
      ],
    );
  }

  setUp(() {
    fs = _FakeWatchFactory();
    catalog = InMemoryMusicLibraryRepository();
    files = _MutableScanner(<String, List<String>>{
      '/music': <String>['/music/a.mp3'],
    });
  });

  /// Waits for the catalog to hold [count] tracks, so a test asserts on the
  /// outcome instead of on a guess at how long a debounce plus a scan takes.
  Future<void> untilCatalogHas(int count) async {
    for (int i = 0; i < 200; i++) {
      if ((await catalog.getAllTracks()).length == count) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    fail('the catalog never reached $count tracks');
  }

  test('watches the folders selected at startup', () async {
    final ProviderContainer c = container();
    addTearDown(c.dispose);
    await c.read(selectedFolderControllerProvider.future);

    c.read(localLibraryWatchServiceProvider);
    await pumpEventQueue();

    expect(
      c.read(localLibraryWatcherProvider).watchedRoots,
      <String>{'/music'},
    );
  });

  test('follows the selection as it changes', () async {
    final ProviderContainer c = container();
    addTearDown(c.dispose);
    await c.read(selectedFolderControllerProvider.future);
    c.read(localLibraryWatchServiceProvider);
    await pumpEventQueue();

    await c
        .read(selectedFolderControllerProvider.notifier)
        .addAndPersist('/media/usb');
    await pumpEventQueue();

    expect(
      c.read(localLibraryWatcherProvider).watchedRoots,
      <String>{'/music', '/media/usb'},
    );
  });

  test('a removed folder is unwatched', () async {
    final ProviderContainer c =
        container(roots: <String>['/music', '/media/usb']);
    addTearDown(c.dispose);
    await c.read(selectedFolderControllerProvider.future);
    c.read(localLibraryWatchServiceProvider);
    await pumpEventQueue();

    await c
        .read(selectedFolderControllerProvider.notifier)
        .removeAndPersist('/media/usb');
    await pumpEventQueue();

    expect(
      c.read(localLibraryWatcherProvider).watchedRoots,
      <String>{'/music'},
    );
    expect(fs.cancelled, contains('/media/usb'));
  });

  test('a new file appears in the library without a manual rescan', () async {
    final ProviderContainer c = container();
    addTearDown(c.dispose);
    await c.read(selectedFolderControllerProvider.future);
    c.read(localLibraryWatchServiceProvider);
    await pumpEventQueue();
    expect(await catalog.getAllTracks(), isEmpty);

    // Someone drops a second file in, and the filesystem says so.
    files.filesByFolder = <String, List<String>>{
      '/music': <String>['/music/a.mp3', '/music/b.mp3'],
    };
    fs.emit('/music', '/music/b.mp3');

    await untilCatalogHas(2);
    expect(
      (await catalog.getAllTracks()).map((Track t) => t.uri).toList()..sort(),
      <String>['/music/a.mp3', '/music/b.mp3'],
    );
  });

  test('a deleted file leaves it, also without a manual rescan', () async {
    final ProviderContainer c = container();
    addTearDown(c.dispose);
    await c.read(selectedFolderControllerProvider.future);
    c.read(localLibraryWatchServiceProvider);
    await pumpEventQueue();

    files.filesByFolder = <String, List<String>>{
      '/music': <String>['/music/a.mp3', '/music/b.mp3'],
    };
    fs.emit('/music', '/music/b.mp3');
    await untilCatalogHas(2);

    files.filesByFolder = <String, List<String>>{
      '/music': <String>['/music/a.mp3'],
    };
    fs.emit('/music', '/music/b.mp3');

    await untilCatalogHas(1);
    expect(
      (await catalog.getAllTracks()).map((Track t) => t.uri),
      <String>['/music/a.mp3'],
    );
  });

  test('Android does not watch anything', () async {
    // Its local library is a SAF tree or a MediaStore query, not a directory,
    // so there is nothing to watch and the unsupported factory refuses.
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        folderPickerServiceProvider
            .overrideWithValue(FakeFolderPickerService()),
        selectedMusicFolderRepositoryProvider.overrideWithValue(
          InMemorySelectedMusicFolderRepository(
            initialFolders: <String>['content://tree/primary%3AMusic'],
          ),
        ),
        musicLibraryRepositoryProvider.overrideWithValue(catalog),
        audioFileScannerProvider.overrideWithValue(files),
        hostPlatformProvider.overrideWithValue(HostPlatform.android),
      ],
    );
    addTearDown(c.dispose);
    await c.read(selectedFolderControllerProvider.future);

    c.read(localLibraryWatchServiceProvider);
    await pumpEventQueue();

    final watcher = c.read(localLibraryWatcherProvider);
    expect(watcher.watchedRoots, isEmpty);
    expect(watcher.isDegraded, isTrue);
  });

  test('disposing the container releases the watches', () async {
    final ProviderContainer c = container();
    await c.read(selectedFolderControllerProvider.future);
    c.read(localLibraryWatchServiceProvider);
    await pumpEventQueue();

    c.dispose();
    await pumpEventQueue();

    expect(fs.cancelled, contains('/music'));
  });
}
