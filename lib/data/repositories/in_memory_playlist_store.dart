import '../../core/models/playlist.dart';
import '../../core/repositories/playlist_store.dart';

/// An in-memory [PlaylistStore] for development and tests.
///
/// The whole list lives on the heap, so nothing is persisted — data is lost when
/// the instance is dropped. That is exactly what unit tests and plugin-free dev
/// runs want; the app overrides it with the `shared_preferences` binding.
class InMemoryPlaylistStore implements PlaylistStore {
  List<Playlist> _playlists = const <Playlist>[];

  @override
  Future<List<Playlist>> load() async => List<Playlist>.of(_playlists);

  @override
  Future<void> save(List<Playlist> playlists) async {
    // Store a defensive copy so later mutation of the caller's list can't
    // silently change what we've cached.
    _playlists = List<Playlist>.of(playlists);
  }
}
