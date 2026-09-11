import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tables/tracks_table.dart';

part 'linthra_database.g.dart';

/// The app's local SQLite database — the offline-first catalog the UI reads
/// from. Kept deliberately outside the UI and feature layers; repositories in
/// `data/repositories/` are the only callers.
///
/// Schema history:
///  * **v1** — `tracks`, keyed by the bare server-side `id`.
///  * **v2** — `tracks` re-keyed on the provider-namespaced `uri`, so the same
///    server-side `id` from two providers (e.g. Plex `101` and Subsonic `101`)
///    can coexist instead of overwriting each other. See [migration].
///  * **v3** — nullable `album_id` / `album_artist_name` columns, so tracks
///    whose per-track artist differs (collaborations) can still group under
///    one album (`library_grouping.dart`). Purely additive: existing rows keep
///    every value and read back with the new columns `null` until the next
///    source re-scan populates them.
///  * **v4** — index on `tracks.source_id` (see `tracks_table.dart`), so a
///    source re-sync's `DELETE ... WHERE source_id = ?` no longer scans the
///    whole catalog to find the one source's rows. Purely additive: no rows
///    or columns change.
///  * **v5**: nullable `file_size_bytes` / `file_modified_at_ms` columns, so
///    a local scan can tell an unchanged file from a changed one with a
///    `stat` instead of re-parsing its tags. Purely additive; see
///    [_addLocalFileStampColumns] for why this is worth a migration at all.
@DriftDatabase(tables: [Tracks])
class LinthraDatabase extends _$LinthraDatabase {
  LinthraDatabase() : super(_openConnection());

  /// Builds a database over a caller-supplied executor. Used by tests to run
  /// against an in-memory SQLite instance (`NativeDatabase.memory()`).
  LinthraDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
        },
        onUpgrade: (Migrator m, int from, int to) async {
          if (from < 2) {
            // Rebuilds `tracks` from the *current* table definition, which
            // already includes the v3 columns — so a v1 database arrives at
            // the v3 shape here and must skip the add-column step below (a
            // second ADD COLUMN of an existing column is an SQLite error).
            await _migrateTracksKeyToUri(m);
          } else if (from < 3) {
            await _addAlbumGroupingColumns(m);
          }
          // Independent of the branches above: a v1 database rebuilt by
          // _migrateTracksKeyToUri still needs the index added separately
          // here, same as a v2 or v3 database does -- createTable never
          // creates indexes declared on the table, and createAll() (the
          // fresh-install path) is the only place that already includes it.
          if (from < 4) {
            await _addTracksSourceIdIndex(m);
          }
          // Also independent of the branches above, and for the same reason:
          // _migrateTracksKeyToUri rebuilds from the *current* table
          // definition, which already has these columns, so a v1 database
          // arrives here with them and must not add them twice.
          if (from < 5 && from >= 2) {
            await _addLocalFileStampColumns(m);
          }
        },
      );

  /// v1 → v2: move the `tracks` primary key from the bare `id` to the
  /// provider-namespaced `uri`.
  ///
  /// SQLite can't alter a primary key in place, so the table is rebuilt: rename
  /// the old one aside, create the new-shaped `tracks`, copy every row across,
  /// then drop the old. All of it runs in one transaction so a reader never sees
  /// a half-migrated catalog (and a failure rolls the whole thing back).
  ///
  /// **Data is preserved.** A v1 catalog could only ever store one row per bare
  /// `id` (that was exactly the collision bug — a second provider's same-id row
  /// overwrote the first), so every surviving row already has a distinct `uri`
  /// and the copy keeps them all. `INSERT OR REPLACE` keeps the copy total even
  /// if some older build had somehow persisted two rows sharing one `uri`.
  Future<void> _migrateTracksKeyToUri(Migrator m) async {
    await transaction(() async {
      await m.database.customStatement(
        'ALTER TABLE tracks RENAME TO tracks_legacy_v1;',
      );
      await m.createTable(tracks);
      await m.database.customStatement(
        'INSERT OR REPLACE INTO tracks '
        '(id, source_id, title, uri, artist_name, album_name, '
        'duration_ms, track_number, artwork_uri) '
        'SELECT id, source_id, title, uri, artist_name, album_name, '
        'duration_ms, track_number, artwork_uri FROM tracks_legacy_v1;',
      );
      await m.database.customStatement('DROP TABLE tracks_legacy_v1;');
    });
  }

  /// v2 → v3: add the nullable `album_id` / `album_artist_name` columns that
  /// let album grouping key off a source's own stable album id instead of the
  /// track's per-track artist name (see `library_grouping.dart`).
  ///
  /// **Purely additive, and data is preserved.** Both columns are nullable
  /// with no default, so SQLite's `ALTER TABLE … ADD COLUMN` rewrites no rows
  /// and needs no table rebuild (unlike the v1 → v2 primary-key change above):
  /// every existing row keeps all of its values and simply reads back with the
  /// two new fields `null`. A null `album_id` falls through to the name-based
  /// grouping tiers, i.e. exactly the pre-v3 behavior, until the next source
  /// re-scan repopulates the catalog with the new metadata.
  Future<void> _addAlbumGroupingColumns(Migrator m) async {
    await transaction(() async {
      await m.addColumn(tracks, tracks.albumId);
      await m.addColumn(tracks, tracks.albumArtistName);
    });
  }

  /// v(1|2|3) → v4: add the index a fresh install already gets from
  /// [Tracks]'s `@TableIndex` via `createAll()`. `createTable` (used by the
  /// v1 → v2 rebuild above) only ever issues `CREATE TABLE`, never the
  /// indexes declared on it, so every upgrade path needs this run
  /// separately regardless of which version it started from.
  ///
  /// **Purely additive, and data is preserved.** An index changes lookup
  /// performance, not row contents; no existing value is read, moved, or
  /// dropped.
  Future<void> _addTracksSourceIdIndex(Migrator m) async {
    await m.createIndex(tracksSourceId);
  }

  /// v(2|3|4) → v5: add the nullable `file_size_bytes` /
  /// `file_modified_at_ms` columns an incremental local scan compares against
  /// a fresh `stat`.
  ///
  /// **Why this earns a migration.** A scan of a real Linux library spends
  /// nearly all of its time opening files and parsing metadata blocks, and on
  /// a routine rescan almost none of those files changed. Skipping them needs
  /// to know what each one looked like when it was last parsed, and the only
  /// place that fact can live without being able to drift is next to the row
  /// it describes: one write, one transaction, no way for a catalog and a
  /// separate stamp index to disagree about whether a file was ever indexed.
  /// A sidecar store would avoid the migration and buy a real hazard, namely
  /// a stamp saying "parsed" for a track the catalog does not have.
  ///
  /// **Purely additive, and data is preserved.** Both columns are nullable
  /// with no default, so SQLite's `ALTER TABLE … ADD COLUMN` rewrites no rows:
  /// every existing row keeps every value and reads back with the two new
  /// fields null. A null stamp means "parse this file", so an upgraded
  /// database behaves exactly as it did before, and the first scan after the
  /// upgrade fills the stamps in as it goes. There is nothing to backfill and
  /// nothing to lose if the upgrade is interrupted.
  Future<void> _addLocalFileStampColumns(Migrator m) async {
    await transaction(() async {
      await m.addColumn(tracks, tracks.fileSizeBytes);
      await m.addColumn(tracks, tracks.fileModifiedAtMs);
    });
  }
}

QueryExecutor _openConnection() {
  return LazyDatabase(() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    final File file = File(p.join(dir.path, 'linthra.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
