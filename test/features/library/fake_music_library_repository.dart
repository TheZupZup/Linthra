import 'package:halcyon/core/models/album.dart';
import 'package:halcyon/core/models/artist.dart';
import 'package:halcyon/core/models/track.dart';
import 'package:halcyon/core/repositories/music_library_repository.dart';

/// A minimal [MusicLibraryRepository] for driving controller/widget tests.
///
/// [getAllTracks] returns [tracks], or throws [error] when one is set, so a
/// test can exercise the loaded, empty, and error paths.
class FakeMusicLibraryRepository implements MusicLibraryRepository {
  FakeMusicLibraryRepository({this.tracks = const <Track>[], this.error});

  final List<Track> tracks;
  final Object? error;

  @override
  Future<List<Track>> getAllTracks() async {
    if (error != null) throw error!;
    return tracks;
  }

  @override
  Future<List<Album>> getAllAlbums() async => const <Album>[];

  @override
  Future<List<Artist>> getAllArtists() async => const <Artist>[];

  @override
  Future<Track?> getTrackById(String id) async {
    for (final track in tracks) {
      if (track.id == id) return track;
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
}
