import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'halcyon_database.dart';

/// The app-wide [HalcyonDatabase]. The underlying SQLite connection is opened
/// lazily on first query and closed when the provider is disposed, so nothing
/// touches the disk until the catalog is actually read or written.
final halcyonDatabaseProvider = Provider<HalcyonDatabase>((ref) {
  final db = HalcyonDatabase();
  ref.onDispose(db.close);
  return db;
});
