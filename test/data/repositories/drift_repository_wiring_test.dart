import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/source_catalog_reader.dart';
import 'package:linthra/data/database/linthra_database.dart';
import 'package:linthra/data/database/linthra_database_provider.dart';
import 'package:linthra/data/repositories/drift_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_library_added_store.dart';
import 'package:linthra/data/repositories/library_added_store_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/library_controller.dart';
import 'package:linthra/features/library/library_state.dart';

void main() {
  group('driftMusicLibraryRepositoryOverride', () {
    test('binds the repository provider to the Drift implementation', () {
      final db = LinthraDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          linthraDatabaseProvider.overrideWithValue(db),
          driftMusicLibraryRepositoryOverride,
        ],
      );
      addTearDown(container.dispose);

      expect(
        container.read(musicLibraryRepositoryProvider),
        isA<DriftMusicLibraryRepository>(),
      );
    });

    test('catalog persists through the controller via the Drift binding',
        () async {
      final db = LinthraDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          linthraDatabaseProvider.overrideWithValue(db),
          driftMusicLibraryRepositoryOverride,
        ],
      );
      addTearDown(container.dispose);

      // Seed the catalog the way a scan would, through the repository the
      // running app actually uses.
      await container.read(musicLibraryRepositoryProvider).upsertCatalog(
        sourceId: 'local',
        tracks: const <Track>[
          Track(id: '1', title: 'Persisted', uri: 'file:///1.mp3'),
        ],
        albums: const <Album>[],
        artists: const <Artist>[],
      );

      await container.read(libraryControllerProvider.notifier).refresh();

      final state = container.read(libraryControllerProvider);
      expect(state.status, LibraryStatus.loaded);
      expect(state.tracks.single.title, 'Persisted');
    });

    test('the repository the app runs on can read a source slice', () async {
      // The local library keeps an offline music folder's tracks by reading
      // back what is stored for the local source. That only works if the
      // production binding — the recording wrapper over Drift — can answer it.
      final db = LinthraDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          linthraDatabaseProvider.overrideWithValue(db),
          libraryAddedStoreProvider
              .overrideWithValue(InMemoryLibraryAddedStore()),
          recordingDriftMusicLibraryRepositoryOverride,
        ],
      );
      addTearDown(container.dispose);
      final repository = container.read(musicLibraryRepositoryProvider);
      await repository.upsertCatalog(
        sourceId: 'local',
        tracks: const <Track>[
          Track(id: '/music/a.mp3', title: 'A', uri: '/music/a.mp3'),
        ],
        albums: const <Album>[],
        artists: const <Artist>[],
      );

      expect(repository, isA<SourceCatalogReader>());
      expect(
        await (repository as SourceCatalogReader).getTracksForSource('local'),
        hasLength(1),
      );
    });
  });
}
