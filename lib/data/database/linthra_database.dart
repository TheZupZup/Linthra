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
/// Schema is at v1 with no migrations yet. When the schema changes, bump
/// [schemaVersion] and add a `MigrationStrategy`; we are not pre-building that
/// machinery while there is nothing to migrate from.
@DriftDatabase(tables: [Tracks])
class LinthraDatabase extends _$LinthraDatabase {
  LinthraDatabase() : super(_openConnection());

  /// Builds a database over a caller-supplied executor. Used by tests to run
  /// against an in-memory SQLite instance (`NativeDatabase.memory()`).
  LinthraDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 1;
}

QueryExecutor _openConnection() {
  return LazyDatabase(() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    final File file = File(p.join(dir.path, 'linthra.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
