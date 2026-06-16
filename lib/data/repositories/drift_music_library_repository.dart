import 'package:drift/drift.dart';

import '../../core/models/album.dart';
import '../../core/models/artist.dart';
import '../../core/models/track.dart';
import '../../core/repositories/incremental_catalog_writer.dart';
import '../../core/repositories/music_library_repository.dart';
import '../database/linthra_database.dart';
import '../mappers/track_mapper.dart';

/// SQLite-backed [MusicLibraryRepository] using Drift. This is the persistent
/// catalog the UI reads from; it replaces the in-memory stand-in once storage
/// is wired up.
///
/// Albums and artists are not persisted yet — [getAllAlbums] and
/// [getAllArtists] return empty lists. Only tracks are stored at v1.
///
/// Also implements [IncrementalCatalogWriter] so a large remote sync (Plex) can
/// fill a source's slice batch by batch instead of one monolithic write.
class DriftMusicLibraryRepository
    implements MusicLibraryRepository, IncrementalCatalogWriter {
  DriftMusicLibraryRepository(this._db);

  final LinthraDatabase _db;

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
      await _deleteSource(sourceId);
      await _insertTracks(sourceId, tracks);
    });
  }

  /// Starts an incremental replacement: clears [sourceId]'s slice and writes the
  /// first batch in one transaction, so a reader never sees the old rows gone
  /// with no new ones in their place.
  @override
  Future<void> beginCatalogReplacement({
    required String sourceId,
    required List<Track> tracks,
  }) async {
    await _db.transaction(() async {
      await _deleteSource(sourceId);
      await _insertTracks(sourceId, tracks);
    });
  }

  /// Appends one more batch to a slice already begun by
  /// [beginCatalogReplacement]. An empty batch is a no-op.
  @override
  Future<void> appendToCatalog({
    required String sourceId,
    required List<Track> tracks,
  }) async {
    await _insertTracks(sourceId, tracks);
  }

  Future<void> _deleteSource(String sourceId) =>
      (_db.delete(_db.tracks)..where((t) => t.sourceId.equals(sourceId))).go();

  Future<void> _insertTracks(String sourceId, List<Track> tracks) async {
    if (tracks.isEmpty) return;
    await _db.batch((Batch batch) {
      // insertOrReplace makes the write idempotent: a source can legitimately
      // hand us the same stable track id twice within one sync — e.g. a Subsonic
      // album that shifts across paginated `getAlbumList2` pages and so is
      // fetched twice, or an `appendToCatalog` batch that overlaps an earlier
      // one during an incremental replacement. A plain insert would raise a
      // UNIQUE-constraint error on the duplicate id and roll back the whole
      // transaction, failing an otherwise-good sync. The id is the track's
      // stable identity, so a duplicate is the same track; collapsing to one row
      // (last wins) is the correct resolution. `tracks` is the only table and
      // has no foreign keys, so the replace can never cascade.
      batch.insertAll(
        _db.tracks,
        tracks.map((Track t) => trackToCompanion(t, sourceId)).toList(),
        mode: InsertMode.insertOrReplace,
      );
    });
  }

  /// Deletes the catalog rows for [trackIds] only. This touches nothing on disk
  /// and nothing on a server — it is purely an index removal (see
  /// [MusicLibraryRepository.removeTracks]).
  @override
  Future<void> removeTracks(List<String> trackIds) async {
    if (trackIds.isEmpty) return;
    await (_db.delete(_db.tracks)..where((t) => t.id.isIn(trackIds))).go();
  }
}
