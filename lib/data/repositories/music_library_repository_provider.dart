import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/music_library_repository.dart';
import 'in_memory_music_library_repository.dart';

/// The single [MusicLibraryRepository] the app reads its catalog from.
///
/// Defaults to the in-memory implementation while the app is being built out;
/// once a scan flow exists, this can be overridden (e.g. in `main`) to the
/// Drift-backed repository without touching any UI code that depends on it.
final musicLibraryRepositoryProvider = Provider<MusicLibraryRepository>((ref) {
  return InMemoryMusicLibraryRepository();
});
