import '../models/album.dart';
import '../models/artist.dart';
import '../models/track.dart';

/// The local, offline-first catalog the UI reads from.
///
/// Critical separation of concerns: the UI always reads from the repository
/// (backed by SQLite), never directly from a [MusicSource]. Sources *sync into*
/// the repository on demand. This is what makes Linthra work fully offline and
/// keeps remote latency out of the render path.
///
/// The concrete implementation (e.g. a `drift`-backed one) is added when the
/// library feature lands; until then this contract lets the rest of the app be
/// built and tested against fakes.
abstract interface class MusicLibraryRepository {
  Future<List<Track>> getAllTracks();
  Future<List<Album>> getAllAlbums();
  Future<List<Artist>> getAllArtists();

  /// Looks up a single track by its provider-namespaced [Track.uri] (e.g.
  /// `jellyfin:101`, `plex:101`, or a local path) — the catalog's canonical,
  /// collision-free identity. The bare server-side `id` is *not* used as a key
  /// because two providers can share one (`plex:101` vs `subsonic:101`).
  Future<Track?> getTrackByUri(String uri);

  /// Replaces the cached catalog for a given source after a scan/sync.
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  });

  /// Removes the tracks with the given provider-namespaced [Track.uri]s
  /// ([trackUris]) from the local catalog/index only.
  ///
  /// This is the "Remove from Linthra library" primitive: it deletes nothing on
  /// disk and nothing on a server — it only forgets the rows in Linthra's own
  /// index. The original local file or remote server item is untouched, so a
  /// later re-scan / re-sync of that source can bring the track back. A safe,
  /// reversible default, deliberately distinct from deleting a file or a server
  /// item. Keyed on the `uri` (not the bare `id`) so removing one provider's copy
  /// can't take a different provider's same-id row with it.
  Future<void> removeTracks(List<String> trackUris);
}
