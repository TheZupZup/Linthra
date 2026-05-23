import '../models/album.dart';
import '../models/artist.dart';
import '../models/track.dart';

/// The local, offline-first catalog the UI reads from.
///
/// Critical separation of concerns: the UI always reads from the repository
/// (backed by SQLite), never directly from a [MusicSource]. Sources *sync into*
/// the repository on demand. This is what makes Halcyon work fully offline and
/// keeps remote latency out of the render path.
///
/// The concrete implementation (e.g. a `drift`-backed one) is added when the
/// library feature lands; until then this contract lets the rest of the app be
/// built and tested against fakes.
abstract interface class MusicLibraryRepository {
  Future<List<Track>> getAllTracks();
  Future<List<Album>> getAllAlbums();
  Future<List<Artist>> getAllArtists();
  Future<Track?> getTrackById(String id);

  /// Replaces the cached catalog for a given source after a scan/sync.
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  });
}
