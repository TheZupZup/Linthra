import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/directory_readability.dart';
import 'package:linthra/core/sources/local/folder_scan_exception.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/core/sources/local/local_scan_report.dart';
import 'package:linthra/core/sources/local/saf_document_lister.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/library_controller.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/library_state.dart';
import 'package:linthra/features/library/local_scan_report_provider.dart';

import '../../core/sources/local/fake_saf_document_lister.dart';
import 'fake_audio_file_scanner.dart';
import 'fake_music_library_repository.dart';

Track _track(String id) => Track(id: id, title: 'Track $id', uri: 'file://$id');

/// Reports every resolved SAF path as readable, standing in for the on-device
/// scoped-storage probe so the content-URI walk runs in tests.
class _AlwaysReadable implements DirectoryReadability {
  @override
  Future<bool> canList(String path) async => true;
}

/// Reports every resolved SAF path as unreadable, simulating Android 11+ scoped
/// storage blocking a folder the SAF URI resolved to.
class _NeverReadable implements DirectoryReadability {
  @override
  Future<bool> canList(String path) async => false;
}

class _DeferredAudioFileScanner implements AudioFileScanner {
  final Map<String, Completer<List<String>>> requests =
      <String, Completer<List<String>>>{};

  final Map<String, Completer<void>> _arrivals = <String, Completer<void>>{};

  /// Completes once [listFiles] has really been called for [folder].
  ///
  /// The scan reads the previously indexed local slice before it walks
  /// anything (that is what lets it tell a moved file from a deleted one), so
  /// a test that wants to drive the walk has to wait for the walk to start
  /// rather than assume it already has.
  Future<void> requested(String folder) =>
      (_arrivals[folder] ??= Completer<void>()).future;

  void _noteArrival(String folder) {
    final Completer<void> arrival = _arrivals[folder] ??= Completer<void>();
    if (!arrival.isCompleted) arrival.complete();
  }

  @override
  Future<List<String>> listFiles(String folder) {
    _noteArrival(folder);
    return (requests[folder] ??= Completer<List<String>>()).future;
  }
}

ProviderContainer _containerWith(FakeMusicLibraryRepository repository) {
  final container = ProviderContainer(
    overrides: [musicLibraryRepositoryProvider.overrideWithValue(repository)],
  );
  addTearDown(container.dispose);
  return container;
}

ProviderContainer _scanContainer({
  required MusicLibraryRepository repository,
  required AudioFileScanner scanner,
}) {
  final container = ProviderContainer(
    overrides: [
      musicLibraryRepositoryProvider.overrideWithValue(repository),
      audioFileScannerProvider.overrideWithValue(scanner),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('LibraryController', () {
    test('starts in the loading state', () {
      final container = _containerWith(FakeMusicLibraryRepository());

      expect(
        container.read(libraryControllerProvider).status,
        LibraryStatus.loading,
      );
    });

    test('loads tracks from the repository', () async {
      final container = _containerWith(
        FakeMusicLibraryRepository(tracks: <Track>[_track('a'), _track('b')]),
      );

      await container.read(libraryControllerProvider.notifier).refresh();

      final state = container.read(libraryControllerProvider);
      expect(state.status, LibraryStatus.loaded);
      expect(state.tracks, hasLength(2));
      expect(state.isEmpty, isFalse);
    });

    test('reports empty when the repository has no tracks', () async {
      final container = _containerWith(FakeMusicLibraryRepository());

      await container.read(libraryControllerProvider.notifier).refresh();

      final state = container.read(libraryControllerProvider);
      expect(state.status, LibraryStatus.loaded);
      expect(state.isEmpty, isTrue);
    });

    test(
      'surfaces a friendly, leak-free error when the repository throws',
      () async {
        // A raw store failure (a corrupt-db or filesystem error on device) must
        // not leak its text — the user sees one clean, actionable line instead.
        final container = _containerWith(
          FakeMusicLibraryRepository(
            error: Exception('FileSystemException: /data/.../db errno = 13'),
          ),
        );

        await container.read(libraryControllerProvider.notifier).refresh();

        final state = container.read(libraryControllerProvider);
        expect(state.status, LibraryStatus.error);
        expect(
          state.errorMessage,
          contains("Couldn't open your music library"),
        );
        // The raw exception text never reaches the UI.
        expect(state.errorMessage, isNot(contains('errno')));
        expect(state.errorMessage, isNot(contains('Exception')));
      },
    );

    test('scanFolder persists discovered tracks and reloads', () async {
      final repository = InMemoryMusicLibraryRepository();
      final scanner = FakeAudioFileScanner(
        files: <String>[
          '/music/One.mp3',
          '/music/Two.flac',
          '/music/cover.jpg',
        ],
      );
      final container = _scanContainer(
        repository: repository,
        scanner: scanner,
      );

      await container
          .read(libraryControllerProvider.notifier)
          .scanFolder('/music');

      final state = container.read(libraryControllerProvider);
      expect(scanner.requestedFolder, '/music');
      expect(state.status, LibraryStatus.loaded);
      // The non-audio file is dropped; the two tracks are persisted.
      expect(state.tracks.map((t) => t.title), <String>['One', 'Two']);
      expect(await repository.getAllTracks(), hasLength(2));
    });

    test('an obsolete scan cannot overwrite a newer source scan', () async {
      final repository = InMemoryMusicLibraryRepository();
      final scanner = _DeferredAudioFileScanner();
      final container = _scanContainer(
        repository: repository,
        scanner: scanner,
      );
      final controller = container.read(libraryControllerProvider.notifier);

      final Future<void> oldScan = controller.scanFolder('/old');
      // Let the old walk genuinely start before the new scan supersedes it:
      // the point is that a walk already in flight cannot commit late, not
      // that a superseded scan never starts walking.
      await scanner.requested('/old');
      final Future<void> newScan = controller.scanFolder('/new');
      await scanner.requested('/new');
      scanner.requests['/new']!.complete(<String>['/new/New.mp3']);
      await newScan;
      scanner.requests['/old']!.complete(<String>['/old/Old.mp3']);
      await oldScan;

      final tracks = await repository.getAllTracks();
      expect(tracks.map((track) => track.title), <String>['New']);
      expect(container.read(libraryControllerProvider).tracks, tracks);
    });

    test('explicit source invalidation discards an in-flight scan', () async {
      final repository = InMemoryMusicLibraryRepository();
      final scanner = _DeferredAudioFileScanner();
      final container = _scanContainer(
        repository: repository,
        scanner: scanner,
      );
      final controller = container.read(libraryControllerProvider.notifier);

      final Future<void> scan = controller.scanFolder('/forgotten');
      await scanner.requested('/forgotten');
      controller.invalidatePendingScans();
      await controller.refresh();
      scanner.requests['/forgotten']!.complete(<String>[
        '/forgotten/ShouldNotReturn.mp3',
      ]);
      await scan;

      expect(await repository.getAllTracks(), isEmpty);
      expect(container.read(libraryControllerProvider).tracks, isEmpty);
    });

    test('an unrelated catalog refresh does not cancel a local scan', () async {
      final repository = InMemoryMusicLibraryRepository();
      final scanner = _DeferredAudioFileScanner();
      final container = _scanContainer(
        repository: repository,
        scanner: scanner,
      );
      final controller = container.read(libraryControllerProvider.notifier);

      final scan = controller.scanFolderWithReport('/music');
      await controller.refresh();
      await scanner.requested('/music');
      scanner.requests['/music']!.complete(<String>['/music/One.mp3']);
      final report = await scan;

      expect(report, isNotNull);
      expect(report!.hadError, isFalse);
      expect(report.importedTracks, 1);
      expect(await repository.getAllTracks(), hasLength(1));
      expect(container.read(localScanReportProvider), same(report));
    });

    test(
      'scanFolder shows a friendly message for an unexpected scan failure',
      () async {
        // A raw scanner failure (a dart:io permission error on device, say) must
        // not leak its text — the user sees one clean, actionable line instead.
        final container = _scanContainer(
          repository: InMemoryMusicLibraryRepository(),
          scanner: FakeAudioFileScanner(
            error: Exception('FileSystemException: errno = 13'),
          ),
        );

        await container
            .read(libraryControllerProvider.notifier)
            .scanFolder('/missing');

        final state = container.read(libraryControllerProvider);
        expect(state.status, LibraryStatus.error);
        expect(state.errorMessage, contains("Couldn't scan that folder"));
        // The raw exception text never reaches the UI.
        expect(state.errorMessage, isNot(contains('errno')));
        expect(state.errorMessage, isNot(contains('Exception')));
      },
    );

    test('scanFolder surfaces a FolderScanException message verbatim',
        () async {
      // A typed scan error already carries a curated, secret-free message, so
      // it should pass through unchanged rather than be replaced by the generic
      // fallback.
      final container = _scanContainer(
        repository: InMemoryMusicLibraryRepository(),
        scanner: FakeAudioFileScanner(
          error: const FolderScanException(
            'This folder is on a provider Linthra cannot read yet.',
          ),
        ),
      );

      await container
          .read(libraryControllerProvider.notifier)
          .scanFolder('/missing');

      final state = container.read(libraryControllerProvider);
      expect(state.status, LibraryStatus.error);
      expect(
        state.errorMessage,
        'This folder is on a provider Linthra cannot read yet.',
      );
    });

    test('scanFolder scans a content URI through the SAF lister', () async {
      final repository = InMemoryMusicLibraryRepository();
      final saf = FakeSafDocumentLister(
        documents: const <SafAudioDocument>[
          SafAudioDocument(uri: 'content://doc/1', name: 'One.mp3'),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          musicLibraryRepositoryProvider.overrideWithValue(repository),
          // The filesystem scanner must not run when SAF traversal works.
          audioFileScannerProvider.overrideWithValue(
            FakeAudioFileScanner(error: Exception('should not scan files')),
          ),
          safDocumentListerProvider.overrideWithValue(saf),
        ],
      );
      addTearDown(container.dispose);

      const folderUri =
          'content://com.android.externalstorage.documents/tree/x';
      await container
          .read(libraryControllerProvider.notifier)
          .scanFolder(folderUri);

      expect(saf.requestedTreeUri, folderUri);
      final state = container.read(libraryControllerProvider);
      expect(state.status, LibraryStatus.loaded);
      expect(state.tracks.map((t) => t.title), <String>['One']);
    });

    test('scanFolder routes a content URI through the Android scanner',
        () async {
      final repository = InMemoryMusicLibraryRepository();
      // A filesystem fake stands in for the on-device walk; the real routing +
      // SAF tree-URI resolution runs in front of it.
      final filesystem = FakeAudioFileScanner(
        files: <String>['/storage/emulated/0/Music/One.mp3'],
      );
      // Wire the fake into the content scanner's walk: a content URI routes to
      // ContentUriAudioFileScanner, which resolves the URI to a path and then
      // delegates that path to its filesystem scanner. A fake readability probe
      // stands in for the on-device scoped-storage check.
      final contentScanner = ContentUriAudioFileScanner(
        filesystemScanner: filesystem,
        readability: _AlwaysReadable(),
      );
      final container = _scanContainer(
        repository: repository,
        scanner: PlatformAudioFileScanner(contentUriScanner: contentScanner),
      );

      const folderUri = 'content://com.android.externalstorage.documents/tree/'
          'primary%3AMusic';
      await container
          .read(libraryControllerProvider.notifier)
          .scanFolder(folderUri);

      // The content URI was resolved to a path before the walk.
      expect(filesystem.requestedFolder, '/storage/emulated/0/Music');
      final state = container.read(libraryControllerProvider);
      expect(state.status, LibraryStatus.loaded);
      expect(state.tracks.map((t) => t.title), <String>['One']);
    });

    test(
      'scanFolder surfaces a clean error for an unscannable content URI',
      () async {
        final container = _scanContainer(
          repository: InMemoryMusicLibraryRepository(),
          scanner: const PlatformAudioFileScanner(),
        );

        const folderUri = 'content://com.android.providers.downloads.documents/'
            'tree/raw%3A';
        await container
            .read(libraryControllerProvider.notifier)
            .scanFolder(folderUri);

        final state = container.read(libraryControllerProvider);
        expect(state.status, LibraryStatus.error);
        expect(state.errorMessage, contains('Storage Access Framework'));
      },
    );

    test(
        'scanFolder surfaces a clean error when a resolved content URI is '
        'unreadable', () async {
      // The external-storage URI resolves to a real path, but scoped storage
      // blocks reading it. The Library should show a clear, actionable error
      // rather than an empty "no music found" library.
      final contentScanner = ContentUriAudioFileScanner(
        filesystemScanner: FakeAudioFileScanner(
          files: <String>['/storage/emulated/0/Music/One.mp3'],
        ),
        readability: _NeverReadable(),
      );
      final container = _scanContainer(
        repository: InMemoryMusicLibraryRepository(),
        scanner: PlatformAudioFileScanner(contentUriScanner: contentScanner),
      );

      const folderUri = 'content://com.android.externalstorage.documents/tree/'
          'primary%3AMusic';
      await container
          .read(libraryControllerProvider.notifier)
          .scanFolder(folderUri);

      final state = container.read(libraryControllerProvider);
      expect(state.status, LibraryStatus.error);
      expect(state.errorMessage, contains('not letting it read'));
    });

    test(
      'a folder Linthra can no longer reach keeps the catalog intact',
      () async {
        // The recoverable-source case (#438/#414): a selected folder that has
        // gone away — an unplugged drive, a deleted folder, a revoked Flatpak
        // portal document — must leave the already-indexed tracks alone. Wiping
        // them would turn a "reselect the folder" problem into a lost library.
        // The scan report recorder is a process-wide static; keep this test's
        // report from leaking into the next one.
        addTearDown(LocalScanDiagnostics.reset);
        final repository = InMemoryMusicLibraryRepository();
        await repository.upsertCatalog(
          sourceId: 'local',
          tracks: <Track>[_track('a'), _track('b')],
          albums: const [],
          artists: const [],
        );
        final container = _scanContainer(
          repository: repository,
          scanner: FakeAudioFileScanner(
            error: const FolderScanException(
              "Linthra couldn't find the selected folder.",
            ),
          ),
        );

        await container
            .read(libraryControllerProvider.notifier)
            .scanFolder('/home/me/Music');

        final state = container.read(libraryControllerProvider);
        expect(state.status, LibraryStatus.error);
        expect(await repository.getAllTracks(), hasLength(2));
        // Recorded as a folder-availability failure, not as an Android SAF one,
        // so a desktop diagnostics report says what actually happened.
        final report = container.read(localScanReportProvider);
        expect(report?.error, LocalScanError.folderUnavailable);
        expect(report?.isContentUri, isFalse);
      },
    );
  });
}
