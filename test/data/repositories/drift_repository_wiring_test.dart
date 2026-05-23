import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonara/core/models/album.dart';
import 'package:sonara/core/models/artist.dart';
import 'package:sonara/core/models/track.dart';
import 'package:sonara/data/database/sonara_database.dart';
import 'package:sonara/data/database/sonara_database_provider.dart';
import 'package:sonara/data/repositories/drift_music_library_repository.dart';
import 'package:sonara/data/repositories/music_library_repository_provider.dart';
import 'package:sonara/features/library/library_controller.dart';
import 'package:sonara/features/library/library_state.dart';

void main() {
  group('driftMusicLibraryRepositoryOverride', () {
    test('binds the repository provider to the Drift implementation', () {
      final db = SonaraDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          sonaraDatabaseProvider.overrideWithValue(db),
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
      final db = SonaraDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          sonaraDatabaseProvider.overrideWithValue(db),
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
  });
}
