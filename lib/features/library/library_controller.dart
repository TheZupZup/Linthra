import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sources/local/local_music_source.dart';
import '../../data/repositories/music_library_repository_provider.dart';
import 'library_providers.dart';
import 'library_state.dart';

/// Drives the Library screen: loads tracks from the [MusicLibraryRepository]
/// and exposes them as a [LibraryState]. Keeps the UI free of any direct
/// knowledge of the repository or its backing store.
class LibraryController extends Notifier<LibraryState> {
  @override
  LibraryState build() {
    // Kick off the initial load; the screen shows a spinner until it lands.
    _load();
    return const LibraryState.loading();
  }

  /// Re-reads the catalog. Safe to call again (e.g. after a scan).
  Future<void> refresh() => _load();

  /// Scans [folderPath] with a [LocalMusicSource], persists the discovered
  /// tracks through the [MusicLibraryRepository], then reloads so the screen
  /// shows what was just stored. Any failure surfaces as an error state.
  Future<void> scanFolder(String folderPath) async {
    state = const LibraryState.loading();
    try {
      final source = LocalMusicSource(
        folderPath: folderPath,
        scanner: ref.read(audioFileScannerProvider),
      );
      final tracks = await source.fetchTracks();
      final albums = await source.fetchAlbums();
      final artists = await source.fetchArtists();
      final repository = ref.read(musicLibraryRepositoryProvider);
      await repository.upsertCatalog(
        sourceId: source.id,
        tracks: tracks,
        albums: albums,
        artists: artists,
      );
      await _load();
    } catch (error) {
      state = LibraryState.error(error.toString());
    }
  }

  Future<void> _load() async {
    state = const LibraryState.loading();
    try {
      final tracks =
          await ref.read(musicLibraryRepositoryProvider).getAllTracks();
      state = LibraryState.loaded(tracks);
    } catch (error) {
      state = LibraryState.error(error.toString());
    }
  }
}

final libraryControllerProvider =
    NotifierProvider<LibraryController, LibraryState>(LibraryController.new);
