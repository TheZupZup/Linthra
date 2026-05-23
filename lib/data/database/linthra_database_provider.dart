import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'linthra_database.dart';

/// The app-wide [LinthraDatabase]. The underlying SQLite connection is opened
/// lazily on first query and closed when the provider is disposed, so nothing
/// touches the disk until the catalog is actually read or written.
final linthraDatabaseProvider = Provider<LinthraDatabase>((ref) {
  final db = LinthraDatabase();
  ref.onDispose(db.close);
  return db;
});
