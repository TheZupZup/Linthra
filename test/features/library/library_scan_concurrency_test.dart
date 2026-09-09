import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/sources/local/android_media_library.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/folder_location.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/core/sources/local/saf_document_lister.dart';
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

import '../../core/sources/local/fake_saf_document_lister.dart';
import 'fake_audio_file_scanner.dart';

class _DeferredScanner implements AudioFileScanner {
  final requests = <String, Completer<List<String>>>{};

  @override
  Future<List<String>> listFiles(String folder) =>
      (requests[folder] ??= Completer<List<String>>()).future;
}

/// Delays the first nonempty local write, then performs it only when released.
/// This exposes the race between a started upsert and a later forget/switch.
class _DeferredWriteRepository extends InMemoryMusicLibraryRepository {
  final writeStarted = Completer<void>();
  final releaseWrite = Completer<void>();
  bool _delayed = false;

  @override
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  }) async {
    if (sourceId == 'local' && tracks.isNotEmpty && !_delayed) {
      _delayed = true;
      writeStarted.complete();
      await releaseWrite.future;
    }
    await super.upsertCatalog(
      sourceId: sourceId,
      tracks: tracks,
      albums: albums,
      artists: artists,
    );
  }
}

class _DeferredMediaLibrary implements AndroidMediaLibrary {
  final started = Completer<void>();
  final result = Completer<SafScanResult>();

  @override
  Future<AndroidMusicPermissionStatus> permissionStatus() async =>
      AndroidMusicPermissionStatus.allowed;

  @override
  Future<AndroidMusicPermissionStatus> requestPermission() async =>
      AndroidMusicPermissionStatus.allowed;

  @override
  Future<void> openAppSettings() async {}

  @override
  Future<SafScanResult> listDeviceAudio() {
    if (!started.isCompleted) started.complete();
    return result.future;
  }
}

ProviderContainer _container({
  required InMemoryMusicLibraryRepository library,
  required AudioFileScanner scanner,
  InMemorySelectedMusicFolderRepository? selected,
  List<Override> extra = const [],
}) {
  final container = ProviderContainer(overrides: [
    musicLibraryRepositoryProvider.overrideWithValue(library),
    audioFileScannerProvider.overrideWithValue(scanner),
    selectedMusicFolderRepositoryProvider.overrideWithValue(
      selected ?? InMemorySelectedMusicFolderRepository(),
    ),
    ...extra,
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(LocalScanDiagnostics.reset);
  tearDown(LocalScanDiagnostics.reset);

  test('abandoning a source stops the native walk, not just its result',
      () async {
    // Forgetting the folder or switching to the device library never starts
    // another scan, so nothing supersedes the walk in flight. Without an
    // explicit cancel it runs to completion opening a metadata retriever per
    // file, for a result the generation guard is going to throw away.
    final library = InMemoryMusicLibraryRepository();
    final lister = FakeSafDocumentLister();
    final container = _container(
      library: library,
      scanner: _DeferredScanner(),
      extra: [safDocumentListerProvider.overrideWithValue(lister)],
    );
    final controller = container.read(libraryControllerProvider.notifier);

    controller.invalidatePendingScans();

    expect(lister.cancellations, 1);
  });

  test('starting a MediaStore scan stops the SAF walk it supersedes', () async {
    // Switching to the device library never calls listAudioDocuments, so
    // nothing supersedes the SAF walk natively. Without cancelling here it
    // keeps doing metadata and artwork I/O for the whole MediaStore traversal.
    final library = InMemoryMusicLibraryRepository();
    final lister = FakeSafDocumentLister();
    final container = _container(
      library: library,
      scanner: _DeferredScanner(),
      extra: [safDocumentListerProvider.overrideWithValue(lister)],
    );
    final controller = container.read(libraryControllerProvider.notifier);

    await controller.scanFolderWithReport(
      FolderLocation.androidMediaStoreAudio,
    );

    expect(lister.cancellations, 1);
    expect(lister.requestedTreeUri, isNull);
  });

  test('clearing the local catalog also stops the walk feeding it', () async {
    final library = InMemoryMusicLibraryRepository();
    final lister = FakeSafDocumentLister();
    final container = _container(
      library: library,
      scanner: _DeferredScanner(),
      extra: [safDocumentListerProvider.overrideWithValue(lister)],
    );
    final controller = container.read(libraryControllerProvider.notifier);

    await controller.clearLocalCatalog();

    expect(lister.cancellations, 1);
  });

  test('a plain refresh does not cancel an unrelated scan', () async {
    // refresh() reloads the shared catalog; it is not a source change and must
    // leave a running local scan alone.
    final library = InMemoryMusicLibraryRepository();
    final lister = FakeSafDocumentLister();
    final container = _container(
      library: library,
      scanner: _DeferredScanner(),
      extra: [safDocumentListerProvider.overrideWithValue(lister)],
    );
    final controller = container.read(libraryControllerProvider.notifier);

    await controller.refresh();

    expect(lister.cancellations, 0);
  });

  test('a superseded scan returns null, not the previous successful report',
      () async {
    final library = InMemoryMusicLibraryRepository();
    final scanner = _DeferredScanner();
    final container = _container(library: library, scanner: scanner);
    final controller = container.read(libraryControllerProvider.notifier);

    final first = controller.scanFolderWithReport('/first');
    scanner.requests['/first']!.complete(['/first/First.mp3']);
    final previous = await first;
    expect(previous?.importedTracks, 1);

    final stale = controller.scanFolderWithReport('/stale');
    controller.invalidatePendingScans();
    scanner.requests['/stale']!.complete(['/stale/Stale.mp3']);
    expect(await stale, isNull);
    expect(container.read(localScanReportProvider), same(previous));
    expect((await library.getAllTracks()).single.title, 'First');
  });

  test('forget invalidates a walk before it can enqueue a catalog write',
      () async {
    final library = InMemoryMusicLibraryRepository();
    final scanner = _DeferredScanner();
    final selected =
        InMemorySelectedMusicFolderRepository(initialFolder: '/music');
    final container = _container(
      library: library,
      scanner: scanner,
      selected: selected,
    );
    await container.read(selectedFolderControllerProvider.future);
    final controller = container.read(libraryControllerProvider.notifier);

    final scan = controller.scanFolderWithReport('/music');
    await container.read(localMusicControllerProvider.notifier).forget();
    scanner.requests['/music']!.complete(['/music/ShouldNotReturn.mp3']);
    expect(await scan, isNull);
    expect(await library.getAllTracks(), isEmpty);
    expect(container.read(localScanReportProvider), isNull);
    expect(await selected.getSelectedFolders(), isEmpty);
  });

  test('forget waits for a started write and clears it without resurrection',
      () async {
    final library = _DeferredWriteRepository();
    final scanner = FakeAudioFileScanner(files: ['/music/Old.mp3']);
    final selected =
        InMemorySelectedMusicFolderRepository(initialFolder: '/music');
    final container = _container(
      library: library,
      scanner: scanner,
      selected: selected,
    );
    await container.read(selectedFolderControllerProvider.future);
    final controller = container.read(libraryControllerProvider.notifier);

    final scan = controller.scanFolderWithReport('/music');
    await library.writeStarted.future;
    final forget =
        container.read(localMusicControllerProvider.notifier).forget();
    await Future<void>.delayed(Duration.zero);
    expect(library.releaseWrite.isCompleted, isFalse);
    library.releaseWrite.complete();
    expect(await scan, isNull);
    await forget;

    expect(await library.getAllTracks(), isEmpty);
    expect(container.read(localScanReportProvider), isNull);
    expect(await selected.getSelectedFolders(), isEmpty);
  });

  test('a source change waits for an already-started local write', () async {
    final library = _DeferredWriteRepository();
    final selected =
        InMemorySelectedMusicFolderRepository(initialFolder: '/old');
    final container = _container(
      library: library,
      scanner: FakeAudioFileScanner(files: ['/old/Old.mp3']),
      selected: selected,
    );
    await container.read(selectedFolderControllerProvider.future);
    final controller = container.read(libraryControllerProvider.notifier);

    final scan = controller.scanFolderWithReport('/old');
    await library.writeStarted.future;
    final change = container
        .read(selectedFolderControllerProvider.notifier)
        .setAndPersist('/new');
    await Future<void>.delayed(Duration.zero);
    expect(await selected.getSelectedFolders(), <String>['/old']);
    library.releaseWrite.complete();
    expect(await scan, isNull);
    await change;
    expect(await selected.getSelectedFolders(), <String>['/new']);
  });

  test('a canceled MediaStore switch cannot reuse an old report', () async {
    final library = InMemoryMusicLibraryRepository();
    final media = _DeferredMediaLibrary();
    final selected =
        InMemorySelectedMusicFolderRepository(initialFolder: '/old');
    final container = _container(
      library: library,
      scanner: FakeAudioFileScanner(files: ['/old/Old.mp3']),
      selected: selected,
      extra: [
        hostPlatformProvider.overrideWithValue(HostPlatform.android),
        androidMediaLibraryProvider.overrideWithValue(media),
      ],
    );
    await container.read(selectedFolderControllerProvider.future);
    final controller = container.read(libraryControllerProvider.notifier);
    final previous = await controller.scanFolderWithReport('/old');
    expect(previous?.importedTracks, 1);

    final local = container.read(localMusicControllerProvider.notifier);
    final switching = local.useAllDeviceMusic();
    await media.started.future;
    await local.forget();
    media.result.complete(const SafScanResult(
      documents: [
        SafAudioDocument(
          uri: 'content://media/external/audio/media/7',
          name: 'New.mp3',
          mimeType: 'audio/mpeg',
        )
      ],
      filesVisited: 1,
    ));
    await switching;

    expect(await selected.getSelectedFolders(), isEmpty);
    expect(await library.getAllTracks(), isEmpty);
    expect(container.read(localScanReportProvider), isNull);
  });
}
