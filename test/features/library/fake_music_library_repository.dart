import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';

/// A minimal [MusicLibraryRepository] for driving controller/widget tests.
///
/// [getAllTracks] returns [tracks], or throws [error] when one is set, so a
/// test can exercise the loaded, empty, and error paths.
class FakeMusicLibraryRepository implements MusicLibraryRepository {
  FakeMusicLibraryRepository({this.tracks = const <Track>[], this.error});

  final List<Track> tracks;
  final Object? error;

  /// Track uris passed to [removeTracks], in order, so a test can assert that a
  /// "Remove from Linthra library" action only removed from the index.
  final List<String> removedTrackUris = <String>[];

  @override
  Future<List<Track>> getAllTracks() async {
    if (error != null) throw error!;
    return <Track>[
      for (final Track track in tracks)
        if (!removedTrackUris.contains(track.uri)) track,
    ];
  }

  @override
  Future<List<Album>> getAllAlbums() async => const <Album>[];

  @override
  Future<List<Artist>> getAllArtists() async => const <Artist>[];

  @override
  Future<Track?> getTrackByUri(String uri) async {
    for (final track in tracks) {
      if (track.uri == uri) return track;
    }
    return null;
  }

  @override
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  }) async {}

  @override
  Future<void> removeTracks(List<String> trackUris) async {
    removedTrackUris.addAll(trackUris);
  }
}
