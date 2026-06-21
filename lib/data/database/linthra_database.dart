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
@DriftDatabase(tables: [Tracks])
class LinthraDatabase extends _$LinthraDatabase {
  LinthraDatabase() : super(_openConnection());

  /// Builds a database over a caller-supplied executor. Used by tests to run
  /// against an in-memory SQLite instance (`NativeDatabase.memory()`).
  LinthraDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
        },
        onUpgrade: (Migrator m, int from, int to) async {
          if (from < 2) {
            await _migrateTracksKeyToUri(m);
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
}

QueryExecutor _openConnection() {
  return LazyDatabase(() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    final File file = File(p.join(dir.path, 'linthra.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
