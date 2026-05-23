import 'package:drift/drift.dart';

import '../../core/models/album.dart';
import '../../core/models/artist.dart';
import '../../core/models/track.dart';
import '../../core/repositories/music_library_repository.dart';
import '../database/sonara_database.dart';
import '../mappers/track_mapper.dart';

/// SQLite-backed [MusicLibraryRepository] using Drift. This is the persistent
/// catalog the UI reads from; it replaces the in-memory stand-in once storage
/// is wired up.
///
/// Albums and artists are not persisted yet — [getAllAlbums] and
/// [getAllArtists] return empty lists. Only tracks are stored at v1.
class DriftMusicLibraryRepository implements MusicLibraryRepository {
  DriftMusicLibraryRepository(this._db);

  final SonaraDatabase _db;

  @override
  Future<List<Track>> getAllTracks() async {
    final List<TrackRow> rows = await _db.select(_db.tracks).get();
    return rows.map(trackFromRow).toList();
  }

  @override
  Future<Track?> getTrackById(String id) async {
    final TrackRow? row = await (_db.select(_db.tracks)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : trackFromRow(row);
  }

  @override
  Future<List<Album>> getAllAlbums() async => const <Album>[];

  @override
  Future<List<Artist>> getAllArtists() async => const <Artist>[];

  /// Replaces every track previously stored for [sourceId] with [tracks], in a
  /// single transaction so a reader never observes a half-applied catalog.
  /// Albums and artists are accepted for interface parity but not persisted at
  /// v1.
  @override
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  }) async {
    await _db.transaction(() async {
      await (_db.delete(_db.tracks)..where((t) => t.sourceId.equals(sourceId)))
          .go();
      await _db.batch((Batch batch) {
        batch.insertAll(
          _db.tracks,
          tracks.map((Track t) => trackToCompanion(t, sourceId)).toList(),
        );
      });
    });
  }
}
