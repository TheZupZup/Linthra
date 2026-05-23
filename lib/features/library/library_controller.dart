import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/music_library_repository_provider.dart';
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

  /// Re-reads the catalog. Safe to call again (e.g. after a future scan).
  Future<void> refresh() => _load();

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
