import 'package:drift/drift.dart';

/// The persisted shape of a [Track] in the local SQLite catalog.
///
/// The generated row class is named `TrackRow` (not `Track`) so it never
/// collides with the domain model in `core/models/track.dart`. Conversion
/// between the two lives in the explicit mappers under `data/mappers/`.
///
/// `sourceId` records which [MusicSource] a row came from so a re-scan of one
/// source can replace just its rows (see `upsertCatalog`) without touching the
/// others. `durationMs` and `artworkUri` are stored as primitives (SQLite has
/// no Duration/Uri types); the mappers rebuild the rich types on read.
///
/// The primary key is [uri], not [id]. `id` is the *bare* server-side id
/// (Jellyfin item id, Subsonic/Plex `ratingKey`, or a local path), which is only
/// unique *within* a provider — two providers can hand us the same `id` (e.g.
/// Plex `101` and Subsonic `101`). `uri` is the provider-namespaced identity the
/// rest of the app already keys off (`jellyfin:101`, `plex:101`, a local path),
/// so keying the row on it lets the same server-side id from different providers
/// coexist instead of silently overwriting each other under `insertOrReplace`.
/// `id` is kept as a column because the per-provider server APIs (e.g. Jellyfin
/// favourites/playlists) still address items by it.
/// Sync replaces one source's rows at a time by deleting every row whose
/// [Tracks.sourceId] matches (`DELETE FROM tracks WHERE source_id = ?`,
/// see `upsertCatalog`). Without an index that lookup is a full scan of the
/// whole catalog on every re-sync; a large library makes every sync
/// noticeably slower for a delete that only ever touches one source's rows.
/// Added in schema v4.
@TableIndex(name: 'tracks_source_id', columns: {#sourceId})
@DataClassName('TrackRow')
class Tracks extends Table {
  TextColumn get id => text()();
  TextColumn get sourceId => text()();
  TextColumn get title => text()();
  TextColumn get uri => text()();
  TextColumn get artistName => text().nullable()();
  TextColumn get albumName => text().nullable()();

  /// The source's provider-namespaced album id (e.g. `jellyfin:al-1`), when
  /// reported — the primary album-grouping key (`library_grouping.dart`).
  /// Nullable: local files and older rows carry none and fall back to
  /// name-based grouping. Added in schema v3.
  TextColumn get albumId => text().nullable()();

  /// The album's artist as the source reported it, distinct from the track's
  /// own [artistName] — the second album-grouping tier when [albumId] is
  /// absent. Nullable, added in schema v3.
  TextColumn get albumArtistName => text().nullable()();
  IntColumn get durationMs => integer().withDefault(const Constant(0))();
  IntColumn get trackNumber => integer().nullable()();
  TextColumn get artworkUri => text().nullable()();

  /// The source file's length in bytes the last time its tags were parsed, and
  /// the file's last-modified time as milliseconds since the Unix epoch. Together
  /// they are the stamp an incremental local scan compares against a fresh
  /// `stat` to decide whether a file has to be opened and parsed again. Both
  /// null for anything that is not a plain local file (remote tracks, Android
  /// SAF documents, MediaStore rows) and for rows written before schema v5; a
  /// null stamp means "parse it", i.e. exactly the pre-v5 behavior.
  ///
  /// They live on the track row rather than in a side table because the row
  /// *is* the record of "this path was parsed into this track": one write, one
  /// transaction, and no way for a catalog and a separate stamp index to drift
  /// apart and skip parsing a file whose track was never stored. Added in
  /// schema v5.
  IntColumn get fileSizeBytes => integer().nullable()();
  IntColumn get fileModifiedAtMs => integer().nullable()();

  @override
  Set<Column> get primaryKey => {uri};
}
