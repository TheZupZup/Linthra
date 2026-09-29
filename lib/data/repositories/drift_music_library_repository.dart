import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../../core/models/album.dart';
import '../../core/models/artist.dart';
import '../../core/models/local_file_stamp.dart';
import '../../core/models/track.dart';
import '../../core/repositories/catalog_track_counter.dart';
import '../../core/repositories/incremental_catalog_writer.dart';
import '../../core/repositories/music_library_repository.dart';
import '../../core/repositories/reconciling_catalog_writer.dart';
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
/// fill a source's slice batch by batch instead of one monolithic write, and
/// [ReconcilingCatalogWriter] so a long sync (Subsonic) can persist each batch
/// as it arrives and only prune stale rows once it knows it saw everything.
class DriftMusicLibraryRepository
    implements
        MusicLibraryRepository,
        IncrementalCatalogWriter,
        ReconcilingCatalogWriter,
        SourceCatalogReader,
        StampedCatalogWriter,
        CatalogTrackCounter {
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

  /// Inserts or replaces [tracks] by uri, deleting nothing. Same write as
  /// [appendToCatalog], exposed under the reconciling contract.
  @override
  Future<void> upsertTracks({
    required String sourceId,
    required List<Track> tracks,
  }) =>
      _insertTracks(sourceId, tracks);

  /// Reads only the `uri` column of [sourceId]'s slice (off the `source_id`
  /// index), works out which rows were not kept, and deletes them in chunks, all
  /// in one transaction so a reader never sees half a prune.
  @override
  Future<List<String>> removeTracksNotIn({
    required String sourceId,
    required Set<String> keepUris,
  }) {
    return _db.transaction(() async {
      final List<String> stale = <String>[
        for (final String uri in await _urisForSource(sourceId))
          if (!keepUris.contains(uri)) uri,
      ];
      for (int i = 0; i < stale.length; i += _deleteChunkSize) {
        final List<String> chunk =
            stale.sublist(i, math.min(i + _deleteChunkSize, stale.length));
        await (_db.delete(_db.tracks)
              ..where((t) => t.sourceId.equals(sourceId) & t.uri.isIn(chunk)))
            .go();
      }
      return stale;
    });
  }

  /// Keeps each `DELETE ... WHERE uri IN (...)` well under SQLite's
  /// bound-parameter limit.
  static const int _deleteChunkSize = 500;

  Future<List<String>> _urisForSource(String sourceId) async {
    final query = _db.selectOnly(_db.tracks)
      ..addColumns(<Expression<Object>>[_db.tracks.uri])
      ..where(_db.tracks.sourceId.equals(sourceId));
    return <String>[
      for (final TypedResult row in await query.get())
        row.read(_db.tracks.uri)!,
    ];
  }

  /// A `COUNT(*)`, so reporting the library size never loads the rows.
  @override
  Future<int> countTracks({String? sourceId}) async {
    final Expression<int> count = countAll();
    final query = _db.selectOnly(_db.tracks)
      ..addColumns(<Expression<Object>>[count]);
    if (sourceId != null) {
      query.where(_db.tracks.sourceId.equals(sourceId));
    }
    return (await query.getSingle()).read(count) ?? 0;
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
