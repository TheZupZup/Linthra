import 'package:drift/drift.dart';

import '../../core/models/album.dart';
import '../../core/models/artist.dart';
import '../../core/models/local_file_stamp.dart';
import '../../core/models/track.dart';
import '../../core/repositories/incremental_catalog_writer.dart';
import '../../core/repositories/music_library_repository.dart';
import '../../core/repositories/source_catalog_reader.dart';
import '../../core/repositories/stamped_catalog_writer.dart';
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
    implements
        MusicLibraryRepository,
        IncrementalCatalogWriter,
        SourceCatalogReader,
        StampedCatalogWriter {
  DriftMusicLibraryRepository(this._db);

  final LinthraDatabase _db;

  @override
  Future<List<Track>> getAllTracks() async {
    final List<TrackRow> rows = await _db.select(_db.tracks).get();
    return rows.map(trackFromRow).toList();
  }

  /// The stored slice for one source, straight off the `source_id` index.
  @override
  Future<List<Track>> getTracksForSource(String sourceId) async {
    return (await _rowsForSource(sourceId)).map(trackFromRow).toList();
  }

  /// The same slice, carrying each row's on-disk stamp so a local scan can
  /// tell which files still look exactly as they did when they were parsed.
  /// One query, the same `source_id` index; the stamp columns ride along on
  /// rows that are being read anyway.
  @override
  Future<List<StampedTrack>> getStampedTracksForSource(String sourceId) async {
    return (await _rowsForSource(sourceId)).map(stampedTrackFromRow).toList();
  }

  Future<List<TrackRow>> _rowsForSource(String sourceId) {
    return (_db.select(_db.tracks)..where((t) => t.sourceId.equals(sourceId)))
        .get();
  }

  @override
  Future<Track?> getTrackByUri(String uri) async {
    final TrackRow? row = await (_db.select(_db.tracks)
          ..where((t) => t.uri.equals(uri)))
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

  /// Replaces [sourceId]'s slice with [tracks] and their stamps, in one
  /// transaction. Same shape and same guarantees as [upsertCatalog]; the only
  /// difference is that each row records what its source file looked like when
  /// it was parsed.
  @override
  Future<void> upsertStampedCatalog({
    required String sourceId,
    required List<StampedTrack> tracks,
  }) async {
    await _db.transaction(() async {
      await _deleteSource(sourceId);
      await _insertStampedTracks(sourceId, tracks);
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

  Future<void> _insertTracks(String sourceId, List<Track> tracks) {
    return _insertStampedTracks(
      sourceId,
      <StampedTrack>[for (final Track t in tracks) StampedTrack(track: t)],
    );
  }

  Future<void> _insertStampedTracks(
    String sourceId,
    List<StampedTrack> tracks,
  ) async {
    if (tracks.isEmpty) return;
    await _db.batch((Batch batch) {
      // insertOrReplace makes the write idempotent: a source can legitimately
      // hand us the same track twice within one sync — e.g. a Subsonic album that
      // shifts across paginated `getAlbumList2` pages and so is fetched twice, or
      // an `appendToCatalog` batch that overlaps an earlier one during an
      // incremental replacement. A plain insert would raise a UNIQUE-constraint
      // error on the duplicate and roll back the whole transaction, failing an
      // otherwise-good sync. The row's identity is its provider-namespaced `uri`
      // (the primary key), so a duplicate uri is the same track; collapsing to
      // one row (last wins) is the correct resolution. Because the key is the
      // uri — not the bare `id` — a same-`id` row from a *different* provider has
      // a different uri and is kept as its own row rather than overwritten.
      // `tracks` is the only table and has no foreign keys, so the replace can
      // never cascade.
      batch.insertAll(
        _db.tracks,
        tracks
            .map((StampedTrack t) =>
                trackToCompanion(t.track, sourceId, stamp: t.stamp))
            .toList(),
        mode: InsertMode.insertOrReplace,
      );
    });
  }

  /// Deletes the catalog rows for [trackIds] only. This touches nothing on disk
  /// and nothing on a server — it is purely an index removal (see
  /// [MusicLibraryRepository.removeTracks]).
  @override
  Future<void> removeTracks(List<String> trackUris) async {
    if (trackUris.isEmpty) return;
    await (_db.delete(_db.tracks)..where((t) => t.uri.isIn(trackUris))).go();
  }
}
