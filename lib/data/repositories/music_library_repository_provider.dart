import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/music_library_repository.dart';
import '../database/linthra_database_provider.dart';
import 'drift_music_library_repository.dart';
import 'in_memory_music_library_repository.dart';
import 'library_added_store_provider.dart';
import 'recording_music_library_repository.dart';

/// The single [MusicLibraryRepository] the app reads its catalog from.
///
/// Defaults to the in-memory implementation, which keeps widget and unit tests
/// fast and free of platform plugins (no `path_provider`, no real SQLite). The
/// running app overrides this with [driftMusicLibraryRepositoryOverride] so the
/// catalog persists across restarts.
final musicLibraryRepositoryProvider = Provider<MusicLibraryRepository>((ref) {
  return InMemoryMusicLibraryRepository();
});

/// Production binding: a Drift/SQLite-backed repository so scanned tracks
/// survive app restarts. Applied in `main`; tests can apply it over an
/// in-memory database by also overriding [linthraDatabaseProvider].
final driftMusicLibraryRepositoryOverride =
    musicLibraryRepositoryProvider.overrideWith(
  (ref) => DriftMusicLibraryRepository(ref.watch(linthraDatabaseProvider)),
);

/// Production binding used by `main`: the Drift repository wrapped so each
/// scan/sync stamps newly-seen tracks with a first-seen time (the signal behind
/// the "Recently added" smart mix). Reads pass straight through to Drift; only
/// [MusicLibraryRepository.upsertCatalog]/[MusicLibraryRepository.removeTracks]
/// also touch the timestamp store. Replaces [driftMusicLibraryRepositoryOverride]
/// in the app's override list.
final recordingDriftMusicLibraryRepositoryOverride =
    musicLibraryRepositoryProvider.overrideWith(
  (ref) => RecordingMusicLibraryRepository(
    delegate: DriftMusicLibraryRepository(ref.watch(linthraDatabaseProvider)),
    addedStore: ref.watch(libraryAddedStoreProvider),
  ),
);
