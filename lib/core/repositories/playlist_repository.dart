import '../models/playlist.dart';

/// Persistence contract for user-created playlists.
///
/// Kept separate from [MusicLibraryRepository] because playlists are
/// user-authored and mutable, whereas the catalog is derived from sources and
/// rebuilt on sync. Different lifecycles, different contracts.
abstract interface class PlaylistRepository {
  Future<List<Playlist>> getAllPlaylists();
  Future<Playlist?> getPlaylistById(String id);
  Future<Playlist> createPlaylist(String name);
  Future<void> updatePlaylist(Playlist playlist);
  Future<void> deletePlaylist(String id);
}
