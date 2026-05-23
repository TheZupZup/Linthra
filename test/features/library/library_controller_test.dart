import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/directory_readability.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/library_controller.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/library_state.dart';

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

ProviderContainer _containerWith(FakeMusicLibraryRepository repository) {
  final container = ProviderContainer(
    overrides: [
      musicLibraryRepositoryProvider.overrideWithValue(repository),
    ],
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

    test('surfaces an error when the repository throws', () async {
      final container = _containerWith(
        FakeMusicLibraryRepository(error: Exception('boom')),
      );

      await container.read(libraryControllerProvider.notifier).refresh();

      final state = container.read(libraryControllerProvider);
      expect(state.status, LibraryStatus.error);
      expect(state.errorMessage, contains('boom'));
    });

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

    test('scanFolder surfaces an error when scanning fails', () async {
      final container = _scanContainer(
        repository: InMemoryMusicLibraryRepository(),
        scanner: FakeAudioFileScanner(error: Exception('no such folder')),
      );

      await container
          .read(libraryControllerProvider.notifier)
          .scanFolder('/missing');

      final state = container.read(libraryControllerProvider);
      expect(state.status, LibraryStatus.error);
      expect(state.errorMessage, contains('no such folder'));
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

    test('scanFolder surfaces a clean error for an unscannable content URI',
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
    });

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
  });
}
