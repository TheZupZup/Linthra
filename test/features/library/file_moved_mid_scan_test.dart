// A file moved while a scan is running keeps its heart, its play count and its
// "added on" date.
//
// Moving a tagged file between two scans keeps its history: the next scan sees
// it gone from one path and present at another with the same tag identity, and
// LocalTrackMoveApplier carries the history across (#410). A scan whose walk
// listed the file *before* the move reads it *after*, though, and can neither
// stat nor read it at the old path. The row indexed there has to stay as it was
// (tags, duration and so the identity a move is matched by), so that the next
// scan, the one the move itself triggers, can still match it to the new path.
// With live updates on, a scan running while the listener tidies folders is
// the normal case, not a corner one.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/play_history.dart';
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

/// Tags keyed by path: a path with no entry is a file that is not there (or
/// not readable) any more, which the real reader also answers with null.
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

const String _from = '/music/inbox/track05.flac';
const String _to = '/music/Bon Iver/Bon Iver/05 Holocene.flac';

void main() {
  setUp(LocalScanDiagnostics.reset);
  tearDown(LocalScanDiagnostics.reset);

  late InMemoryLibraryAddedStore addedStore;
  late InMemoryFavoritesStore favoritesStore;
  late InMemoryPlayHistoryStore historyStore;
  late FakeAudioFileScanner scanner;
  late _MapMetadataReader tags;
  late ProviderContainer c;

  Future<void> rescan() =>
      c.read(localMusicControllerProvider.notifier).rescan();

  /// The app's wiring, with [_from] indexed, hearted, played twice and added
  /// years ago.
  setUp(() async {
    addedStore = InMemoryLibraryAddedStore();
    favoritesStore = InMemoryFavoritesStore();
    historyStore = InMemoryPlayHistoryStore();
    scanner = FakeAudioFileScanner(filesByFolder: <String, List<String>>{
      '/music': <String>[_from],
    });
    tags = _MapMetadataReader(<String, LocalAudioMetadata>{_from: _holocene});
    c = ProviderContainer(
      overrides: <Override>[
        folderPickerServiceProvider
            .overrideWithValue(FakeFolderPickerService()),
        selectedMusicFolderRepositoryProvider.overrideWithValue(
          InMemorySelectedMusicFolderRepository(
            initialFolders: const <String>['/music'],
          ),
        ),
        libraryAddedStoreProvider.overrideWithValue(addedStore),
        favoritesStoreProvider.overrideWithValue(favoritesStore),
        playHistoryStoreProvider.overrideWithValue(historyStore),
        musicLibraryRepositoryProvider.overrideWithValue(
          RecordingMusicLibraryRepository(
            delegate: InMemoryMusicLibraryRepository(),
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
    await favoritesStore.save(const FavoritesData(localIds: <String>{_from}));
    await historyStore.save(PlayHistory(stats: <String, TrackPlayStats>{
      _from: TrackPlayStats(playCount: 2, lastPlayedAt: DateTime.utc(2026, 3)),
    }));
    await addedStore.save(<String, DateTime>{_from: DateTime.utc(2021, 6, 1)});
    await c.read(selectedFolderControllerProvider.future);
    await rescan();
  });

  Future<void> expectHistoryAt(String uri, {required String because}) async {
    expect((await favoritesStore.load()).localIds, <String>{uri},
        reason: because);
    expect((await historyStore.load()).playCountFor(uri), 2);
    expect((await addedStore.load())[uri], DateTime.utc(2021, 6, 1));
  }

  test('a file moved while a scan is reading keeps its history', () async {
    // A scan is running (a watcher refresh for an earlier change): its walk
    // listed the file at its old path, and the user moved the file before the
    // scan got to reading it.
    tags.byPath = <String, LocalAudioMetadata>{_to: _holocene};
    await rescan();

    // The scan the move itself triggers.
    scanner.filesByFolder = <String, List<String>>{
      '/music': <String>[_to],
    };
    await rescan();

    await expectHistoryAt(
      _to,
      because: 'the heart must follow the file, as it does when the move does '
          'not overlap a scan',
    );
  });

  test('the same move between two scans keeps its history', () async {
    tags.byPath = <String, LocalAudioMetadata>{_to: _holocene};
    scanner.filesByFolder = <String, List<String>>{
      '/music': <String>[_to],
    };
    await rescan();

    await expectHistoryAt(_to, because: 'an ordinary move');
  });
}
