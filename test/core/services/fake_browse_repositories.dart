import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/favorites_repository.dart';
import 'package:linthra/core/repositories/playlist_repository.dart';

/// Minimal [PlaylistRepository] for browse-tree tests: serves a fixed list of
/// playlists. Only the reads the media browser uses ([getAllPlaylists],
/// [getPlaylistById]) are implemented; the editing/sync surface throws, so a
/// test that accidentally relied on it would fail loudly.
class FakePlaylistRepository implements PlaylistRepository {
  FakePlaylistRepository(this.playlists);

  final List<Playlist> playlists;

  @override
  Future<List<Playlist>> getAllPlaylists() async => playlists;

  @override
  Future<Playlist?> getPlaylistById(String id) async {
    for (final Playlist playlist in playlists) {
      if (playlist.id == id) return playlist;
    }
    return null;
  }

  @override
  Stream<List<Playlist>> get playlistsStream =>
      Stream<List<Playlist>>.value(playlists);

  // Editing/sync surface — not exercised by the media browser, so it throws to
  // fail loudly if a test ever depends on it.
  @override
  Future<Playlist> createPlaylist(
    String name, {
    String? description,
    PlaylistSource source = PlaylistSource.local,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> renamePlaylist(String id, String name, {String? description}) =>
      throw UnimplementedError();

  @override
  Future<void> deletePlaylist(String id) => throw UnimplementedError();

  @override
  Future<void> addTrack(String playlistId, String trackId) =>
      throw UnimplementedError();

  @override
  Future<void> addTracks(String playlistId, List<String> trackIds) =>
      throw UnimplementedError();

  @override
  Future<void> removeTrack(String playlistId, String trackId) =>
      throw UnimplementedError();

  @override
  Future<void> reorderTracks(String playlistId, int oldIndex, int newIndex) =>
      throw UnimplementedError();

  @override
  Future<void> markSyncState(
    String id,
    PlaylistSyncState state, {
    String? error,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> refreshFromRemote() => throw UnimplementedError();
}

/// Minimal local-only [FavoritesRepository] for browse-tree tests: holds a fixed
/// id set and yields it on the stream immediately (matching the real contract,
/// "the current set immediately, then on every change"), so the tree's
/// `favoritesStream.first` read resolves deterministically.
class FakeFavoritesRepository implements FavoritesRepository {
  FakeFavoritesRepository(Set<String> ids) : _ids = ids;

  final Set<String> _ids;

  @override
  Stream<Set<String>> get favoritesStream async* {
    yield _ids;
  }

  @override
  bool isFavorite(String trackId) => _ids.contains(trackId);

  @override
  Future<void> setFavorite(Track track, bool favorite) async {
    if (favorite) {
      _ids.add(track.id);
    } else {
      _ids.remove(track.id);
    }
  }

  @override
  Future<void> refreshFromRemote() async {}

  @override
  Future<void> clearRemote() async {}
}
