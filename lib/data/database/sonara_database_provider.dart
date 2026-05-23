import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'sonara_database.dart';

/// The app-wide [SonaraDatabase]. The underlying SQLite connection is opened
/// lazily on first query and closed when the provider is disposed, so nothing
/// touches the disk until the catalog is actually read or written.
final sonaraDatabaseProvider = Provider<SonaraDatabase>((ref) {
  final db = SonaraDatabase();
  ref.onDispose(db.close);
  return db;
});
