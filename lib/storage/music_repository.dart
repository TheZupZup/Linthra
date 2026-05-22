import '../models/album.dart';
import '../models/artist.dart';
import '../models/playlist.dart';
import '../models/song.dart';

/// The local, offline-first cache the UI reads from.
///
/// Critical separation of concerns: the UI always reads from the repository
/// (backed by SQLite), never directly from a MusicSource. Sources *sync into*
/// the repository on demand. This is what makes Echora work fully offline and
/// keeps remote latency out of the render path.
///
/// The concrete implementation (`DriftMusicRepository`) is added when the
/// library feature lands; until then this contract lets the rest of the app be
/// built and tested against fakes.
abstract interface class MusicRepository {
  Future<List<Song>> getAllSongs();
  Future<List<Album>> getAllAlbums();
  Future<List<Artist>> getAllArtists();
  Future<Song?> getSongById(String id);

  Future<List<Playlist>> getAllPlaylists();
  Future<Playlist> createPlaylist(String name);
  Future<void> updatePlaylist(Playlist playlist);
  Future<void> deletePlaylist(String id);

  /// Replaces the cached catalog for a given source after a scan/sync.
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Song> songs,
    required List<Album> albums,
    required List<Artist> artists,
  });
}
