import '../../core/models/album.dart';
import '../../core/models/artist.dart';
import '../../core/models/track.dart';
import '../../core/repositories/incremental_catalog_writer.dart';
import '../../core/repositories/music_library_repository.dart';

/// An in-memory [MusicLibraryRepository] for development and tests.
///
/// A temporary stand-in for the planned Drift/SQLite implementation. The
/// whole catalog lives in plain maps on the heap, so nothing is persisted —
/// data is lost when the instance is dropped. That is fine for unit tests
/// and for running the app before storage code generation is in place.
///
/// Items are grouped by `sourceId`. Each [upsertCatalog] call fully replaces
/// the catalog for that one source, leaving every other source untouched.
/// The `getAll*` methods flatten across sources, preserving the order that
/// sources were first seen and the item order within each source.
class InMemoryMusicLibraryRepository
    implements MusicLibraryRepository, IncrementalCatalogWriter {
  // Per-source catalogs. Keyed by sourceId so a re-scan of one source can
  // replace just its slice without disturbing the others. `upsertCatalog` is
  // the only writer, which keeps the three maps in sync.
  final Map<String, List<Track>> _tracksBySource = <String, List<Track>>{};
  final Map<String, List<Album>> _albumsBySource = <String, List<Album>>{};
  final Map<String, List<Artist>> _artistsBySource = <String, List<Artist>>{};

  @override
  Future<List<Track>> getAllTracks() async {
    final List<Track> all = <Track>[];
    for (final List<Track> tracks in _tracksBySource.values) {
      all.addAll(tracks);
    }
    return all;
  }

  @override
  Future<List<Album>> getAllAlbums() async {
    final List<Album> all = <Album>[];
    for (final List<Album> albums in _albumsBySource.values) {
      all.addAll(albums);
    }
    return all;
  }

  @override
  Future<List<Artist>> getAllArtists() async {
    final List<Artist> all = <Artist>[];
    for (final List<Artist> artists in _artistsBySource.values) {
      all.addAll(artists);
    }
    return all;
  }

  @override
  Future<Track?> getTrackByUri(String uri) async {
    for (final List<Track> tracks in _tracksBySource.values) {
      for (final Track track in tracks) {
        if (track.uri == uri) {
          return track;
        }
      }
    }
    return null;
  }

  @override
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  }) async {
    // Store defensive copies so later mutation of the caller's lists can't
    // silently change what we've cached.
    _tracksBySource[sourceId] = List<Track>.of(tracks);
    _albumsBySource[sourceId] = List<Album>.of(albums);
    _artistsBySource[sourceId] = List<Artist>.of(artists);
  }

  @override
  Future<void> beginCatalogReplacement({
    required String sourceId,
    required List<Track> tracks,
  }) async {
    // Mirror upsertCatalog's "replace this source" semantics, but only for the
    // tracks an incremental sync streams; the album/artist slices are derived
    // from tracks by readers, so they're dropped to stay consistent.
    _tracksBySource[sourceId] = List<Track>.of(tracks);
    _albumsBySource.remove(sourceId);
    _artistsBySource.remove(sourceId);
  }

  @override
  Future<void> appendToCatalog({
    required String sourceId,
    required List<Track> tracks,
  }) async {
    if (tracks.isEmpty) return;
    (_tracksBySource[sourceId] ??= <Track>[]).addAll(tracks);
  }

  @override
  Future<void> removeTracks(List<String> trackUris) async {
    if (trackUris.isEmpty) return;
    final Set<String> uris = trackUris.toSet();
    for (final String sourceId in _tracksBySource.keys.toList()) {
      _tracksBySource[sourceId] = <Track>[
        for (final Track track in _tracksBySource[sourceId]!)
          if (!uris.contains(track.uri)) track,
      ];
    }
  }
}
