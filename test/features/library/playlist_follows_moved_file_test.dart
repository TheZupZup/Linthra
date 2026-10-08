// A local playlist keeps a song the listener moved to another folder, in the
// same place, the way its heart and play count already do (#794). Only a move
// the scan proved counts: a deleted file, or a second copy, leaves the
// playlist pointing where it did.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';
import 'package:linthra/core/sources/local/local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_library_added_store.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/library_added_store_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/data/repositories/recording_music_library_repository.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/selected_folder_controller.dart';
import 'package:linthra/features/settings/source/local_music_controller.dart';

import 'fake_audio_file_scanner.dart';
import 'fake_folder_picker_service.dart';

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

const LocalAudioMetadata _towers = LocalAudioMetadata(
  title: 'Towers',
  artist: 'Bon Iver',
  albumArtist: 'Bon Iver',
  album: 'Bon Iver',
  trackNumber: 6,
  duration: Duration(milliseconds: 188000),
);

const String _from = '/music/inbox/track05.flac';
const String _to = '/music/Bon Iver/05 Holocene.flac';
const String _other = '/music/Bon Iver/06 Towers.flac';

void main() {
  setUp(LocalScanDiagnostics.reset);
  tearDown(LocalScanDiagnostics.reset);

  late InMemoryPlaylistStore playlistStore;
  late FakeAudioFileScanner scanner;
  late _MapMetadataReader tags;
  late ProviderContainer c;

  Future<void> rescan() =>
      c.read(localMusicControllerProvider.notifier).rescan();

  Future<List<String>> songs() async =>
      (await c.read(playlistRepositoryProvider).getPlaylistById('mix'))!
          .trackIds;

  void onDisk(Map<String, LocalAudioMetadata> files) {
    tags.byPath = files;
    scanner.filesByFolder = <String, List<String>>{
      '/music': files.keys.toList(),
    };
  }

  /// [_from] and [_other] indexed, both in a local playlist.
  setUp(() async {
    final InMemoryLibraryAddedStore addedStore = InMemoryLibraryAddedStore();
    playlistStore = InMemoryPlaylistStore();
    await playlistStore.save(const <Playlist>[
      Playlist(id: 'mix', name: 'Mix', trackIds: <String>[_from, _other]),
    ]);
    scanner = FakeAudioFileScanner();
    tags = _MapMetadataReader(const <String, LocalAudioMetadata>{});
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
        playlistStoreProvider.overrideWithValue(playlistStore),
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
    onDisk(const <String, LocalAudioMetadata>{
      _from: _holocene,
      _other: _towers,
    });
    await c.read(selectedFolderControllerProvider.future);
    await rescan();
  });

  test('a moved song stays in the playlist, in its place', () async {
    onDisk(const <String, LocalAudioMetadata>{_other: _towers, _to: _holocene});
    await rescan();

    expect(await songs(), <String>[_to, _other]);
    expect((await playlistStore.load()).single.trackIds, <String>[_to, _other]);
  });

  test('a deleted song is not mistaken for a move', () async {
    onDisk(const <String, LocalAudioMetadata>{_other: _towers});
    await rescan();

    expect(await songs(), <String>[_from, _other]);
  });

  test('two copies of a song are not a move', () async {
    onDisk(const <String, LocalAudioMetadata>{
      _other: _towers,
      _to: _holocene,
      '/music/backup/05 Holocene.flac': _holocene,
    });
    await rescan();

    expect(await songs(), <String>[_from, _other]);
  });
}
