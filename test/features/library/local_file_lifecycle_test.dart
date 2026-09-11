// The whole "moved and deleted local tracks" path (#410) wired the way the app
// wires it: the Settings rescan action, the scan, the catalog, and the three
// stores that key state on a track's uri.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/play_history.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/repositories/favorites_store.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';
import 'package:linthra/core/sources/local/local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/data/repositories/favorites_repository_provider.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_favorites_store.dart';
import 'package:linthra/data/repositories/in_memory_library_added_store.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_play_history_store.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/library_added_store_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/play_history_repository_provider.dart';
import 'package:linthra/data/repositories/recording_music_library_repository.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/selected_folder_controller.dart';
import 'package:linthra/features/settings/source/local_music_controller.dart';

import 'fake_audio_file_scanner.dart';
import 'fake_folder_picker_service.dart';

/// Tags keyed by path, so a test can say "this file's tags moved to that path"
/// without any disk. A path with no entry reads back untagged, which is exactly
/// the case that must never be matched on.
class _MapMetadataReader implements LocalMetadataReader {
  _MapMetadataReader(this.byPath);

  Map<String, LocalAudioMetadata> byPath;

  @override
  Future<LocalAudioMetadata?> readFromPath(String path) async => byPath[path];
}

const LocalAudioMetadata _holocene = LocalAudioMetadata(
  title: 'Holocene',
  artist: 'Bon Iver',
  albumArtist: 'Bon Iver',
  album: 'Bon Iver',
  trackNumber: 5,
  duration: Duration(milliseconds: 337000),
);

const LocalAudioMetadata _perth = LocalAudioMetadata(
  title: 'Perth',
  artist: 'Bon Iver',
  albumArtist: 'Bon Iver',
  album: 'Bon Iver',
  trackNumber: 1,
  duration: Duration(milliseconds: 250000),
);

void main() {
  setUp(LocalScanDiagnostics.reset);
  tearDown(LocalScanDiagnostics.reset);

  late InMemoryMusicLibraryRepository catalog;
  late InMemoryLibraryAddedStore addedStore;
  late InMemoryFavoritesStore favoritesStore;
  late InMemoryPlayHistoryStore historyStore;
  late FakeAudioFileScanner scanner;
  late _MapMetadataReader tags;

  ProviderContainer container({List<String> roots = const <String>['/music']}) {
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        folderPickerServiceProvider
            .overrideWithValue(FakeFolderPickerService()),
        selectedMusicFolderRepositoryProvider.overrideWithValue(
          InMemorySelectedMusicFolderRepository(initialFolders: roots),
        ),
        libraryAddedStoreProvider.overrideWithValue(addedStore),
        favoritesStoreProvider.overrideWithValue(favoritesStore),
        playHistoryStoreProvider.overrideWithValue(historyStore),
        musicLibraryRepositoryProvider.overrideWithValue(
          RecordingMusicLibraryRepository(
            delegate: catalog,
            addedStore: addedStore,
            now: () => DateTime.utc(2026, 9, 10),
          ),
        ),
        audioFileScannerProvider.overrideWithValue(scanner),
        localMetadataReaderProvider.overrideWithValue(tags),
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() {
    catalog = InMemoryMusicLibraryRepository();
    addedStore = InMemoryLibraryAddedStore();
    favoritesStore = InMemoryFavoritesStore();
    historyStore = InMemoryPlayHistoryStore();
    scanner = FakeAudioFileScanner();
    tags = _MapMetadataReader(<String, LocalAudioMetadata>{});
  });

  Future<List<String>> catalogUris() async {
    final List<Track> tracks = await catalog.getAllTracks();
    return tracks.map((Track t) => t.uri).toList()..sort();
  }

  group('a deleted file', () {
    test('leaves the catalog on the next scan', () async {
      scanner = FakeAudioFileScanner(filesByFolder: <String, List<String>>{
        '/music': <String>['/music/a.mp3', '/music/b.mp3'],
      });
      final ProviderContainer c = container();
      await c.read(selectedFolderControllerProvider.future);
      await c.read(localMusicControllerProvider.notifier).rescan();
      expect(await catalogUris(), <String>['/music/a.mp3', '/music/b.mp3']);

      // b.mp3 is deleted from disk.
      scanner.filesByFolder = <String, List<String>>{
        '/music': <String>['/music/a.mp3'],
      };
      await c.read(localMusicControllerProvider.notifier).rescan();

      expect(await catalogUris(), <String>['/music/a.mp3']);
    });

    test('an unplugged drive keeps its music instead', () async {
      scanner = FakeAudioFileScanner(filesByFolder: <String, List<String>>{
        '/music': <String>['/music/a.mp3'],
        '/media/usb': <String>['/media/usb/b.mp3'],
      });
      final ProviderContainer c =
          container(roots: <String>['/music', '/media/usb']);
      await c.read(selectedFolderControllerProvider.future);
      await c.read(localMusicControllerProvider.notifier).rescan();

      scanner.unavailable = <String>{'/media/usb'};
      await c.read(localMusicControllerProvider.notifier).rescan();

      expect(
        await catalogUris(),
        <String>['/media/usb/b.mp3', '/music/a.mp3'],
      );
    });
  });

  group('a file that moved', () {
    /// Sets up: one tagged file at [from], scanned, hearted, played twice and
    /// stamped as added long ago. Then moves it to [to] and rescans.
    Future<void> moveFile({
      required String from,
      required String to,
      LocalAudioMetadata metadata = _holocene,
      List<String> alsoAtDestination = const <String>[],
    }) async {
      scanner = FakeAudioFileScanner(filesByFolder: <String, List<String>>{
        '/music': <String>[from],
      });
      tags = _MapMetadataReader(<String, LocalAudioMetadata>{from: metadata});
      final ProviderContainer c = container();

      await favoritesStore.save(FavoritesData(localIds: <String>{from}));
      await historyStore.save(PlayHistory(stats: <String, TrackPlayStats>{
        from: TrackPlayStats(
          playCount: 2,
          lastPlayedAt: DateTime.utc(2026, 3, 1),
        ),
      }));
      await addedStore.save(<String, DateTime>{from: DateTime.utc(2021, 6, 1)});

      await c.read(selectedFolderControllerProvider.future);
      await c.read(localMusicControllerProvider.notifier).rescan();

      scanner.filesByFolder = <String, List<String>>{
        '/music': <String>[to, ...alsoAtDestination],
      };
      tags.byPath = <String, LocalAudioMetadata>{
        to: metadata,
        for (final String extra in alsoAtDestination) extra: metadata,
      };
      await c.read(localMusicControllerProvider.notifier).rescan();
    }

    test('keeps its heart, its play count and its added date', () async {
      await moveFile(
        from: '/music/inbox/track01.flac',
        to: '/music/Bon Iver/Bon Iver/05 Holocene.flac',
      );
      const String to = '/music/Bon Iver/Bon Iver/05 Holocene.flac';

      expect(await catalogUris(), <String>[to]);
      expect((await favoritesStore.load()).localIds, <String>{to});
      expect((await historyStore.load()).playCountFor(to), 2);
      expect((await addedStore.load())[to], DateTime.utc(2021, 6, 1));
      expect(
        (await addedStore.load()).containsKey('/music/inbox/track01.flac'),
        isFalse,
      );
    });

    test('an ambiguous move hands its history to nobody', () async {
      // Two identically-tagged files turn up where one used to be: a copy, not
      // a move. Neither may inherit the original's listening history.
      await moveFile(
        from: '/music/inbox/track01.flac',
        to: '/music/copies/one.flac',
        alsoAtDestination: <String>['/music/copies/two.flac'],
      );

      final FavoritesData favorites = await favoritesStore.load();
      expect(favorites.localIds, <String>{'/music/inbox/track01.flac'});
      final PlayHistory history = await historyStore.load();
      expect(history.playCountFor('/music/copies/one.flac'), 0);
      expect(history.playCountFor('/music/copies/two.flac'), 0);
    });

    test('an untagged file is never matched by name alone', () async {
      // No tags at either end, so the title and folders came from the path.
      scanner = FakeAudioFileScanner(filesByFolder: <String, List<String>>{
        '/music': <String>['/music/one/01 - Intro.mp3'],
      });
      tags = _MapMetadataReader(<String, LocalAudioMetadata>{});
      final ProviderContainer c = container();
      await favoritesStore.save(
        const FavoritesData(localIds: <String>{'/music/one/01 - Intro.mp3'}),
      );
      await c.read(selectedFolderControllerProvider.future);
      await c.read(localMusicControllerProvider.notifier).rescan();

      scanner.filesByFolder = <String, List<String>>{
        '/music': <String>['/music/two/01 - Intro.mp3'],
      };
      await c.read(localMusicControllerProvider.notifier).rescan();

      expect(
        (await favoritesStore.load()).localIds,
        <String>{'/music/one/01 - Intro.mp3'},
        reason: 'two albums can each hold an "01 - Intro.mp3"; matching them '
            'would be matching the file name',
      );
    });

    test('a second, genuinely new file is still added normally', () async {
      scanner = FakeAudioFileScanner(filesByFolder: <String, List<String>>{
        '/music': <String>['/music/holocene.flac'],
      });
      tags = _MapMetadataReader(<String, LocalAudioMetadata>{
        '/music/holocene.flac': _holocene,
      });
      final ProviderContainer c = container();
      await c.read(selectedFolderControllerProvider.future);
      await c.read(localMusicControllerProvider.notifier).rescan();

      scanner.filesByFolder = <String, List<String>>{
        '/music': <String>['/music/holocene.flac', '/music/perth.flac'],
      };
      tags.byPath = <String, LocalAudioMetadata>{
        '/music/holocene.flac': _holocene,
        '/music/perth.flac': _perth,
      };
      await c.read(localMusicControllerProvider.notifier).rescan();

      expect(
        await catalogUris(),
        <String>['/music/holocene.flac', '/music/perth.flac'],
      );
      expect(
        (await addedStore.load())['/music/perth.flac'],
        DateTime.utc(2026, 9, 10),
        reason: 'a new file really is newly added',
      );
    });
  });
}
