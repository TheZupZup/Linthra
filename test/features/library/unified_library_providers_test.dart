import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/source_priority.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/library_controller.dart';
import 'package:linthra/features/library/library_search.dart';
import 'package:linthra/features/library/source_preference_controller.dart';
import 'package:linthra/features/library/unified_library_providers.dart';

Track _jelly(String id, {required String title, String album = '25'}) => Track(
      id: id,
      title: title,
      uri: 'jellyfin:$id',
      artistName: 'Adele',
      albumName: album,
      duration: const Duration(minutes: 3),
    );

Track _sub(String id, {required String title, String album = '25'}) => Track(
      id: id,
      title: title,
      uri: 'subsonic:$id',
      artistName: 'Adele',
      albumName: album,
      duration: const Duration(minutes: 3),
    );

/// Pins the source preference for a deterministic test, bypassing the async
/// load from the store.
class _FixedPreference extends SourcePreferenceController {
  _FixedPreference(this._priority);
  final SourcePriority _priority;
  @override
  SourcePriority build() => _priority;
}

/// A container seeded with a per-source catalog and a fixed source preference.
Future<ProviderContainer> _seed({
  required SourcePriority priority,
  required List<Track> jellyfin,
  required List<Track> subsonic,
}) async {
  final repo = InMemoryMusicLibraryRepository();
  final container = ProviderContainer(
    overrides: <Override>[
      musicLibraryRepositoryProvider.overrideWithValue(repo),
      librarySourcePriorityProvider
          .overrideWith(() => _FixedPreference(priority)),
    ],
  );
  addTearDown(container.dispose);
  await repo.upsertCatalog(
    sourceId: 'jellyfin',
    tracks: jellyfin,
    albums: const <Album>[],
    artists: const <Artist>[],
  );
  await repo.upsertCatalog(
    sourceId: 'subsonic',
    tracks: subsonic,
    albums: const <Album>[],
    artists: const <Artist>[],
  );
  await container.read(libraryControllerProvider.notifier).refresh();
  return container;
}

void main() {
  group('libraryUnifiedTracksProvider', () {
    test('shows one row for a song served by both providers', () async {
      final container = await _seed(
        priority: const SourcePriority(<String>['subsonic', 'jellyfin']),
        jellyfin: <Track>[_jelly('j', title: 'Hello')],
        subsonic: <Track>[_sub('s', title: 'Hello')],
      );

      final List<Track> songs = container.read(libraryUnifiedTracksProvider);
      expect(songs, hasLength(1));
      // Navidrome is active, so the playable/queued copy is the Subsonic one.
      expect(songs.single.uri, 'subsonic:s');
    });

    test('a Jellyfin-only song still appears and plays from Jellyfin',
        () async {
      final container = await _seed(
        priority: const SourcePriority(<String>['subsonic', 'jellyfin']),
        jellyfin: <Track>[_jelly('j', title: 'Only Jelly')],
        subsonic: <Track>[_sub('s', title: 'Shared')],
      );

      final List<Track> songs = container.read(libraryUnifiedTracksProvider);
      final Track jellyOnly =
          songs.firstWhere((Track t) => t.title == 'Only Jelly');
      expect(jellyOnly.uri, 'jellyfin:j');
    });

    test('search over the unified list never duplicates a logical track',
        () async {
      final container = await _seed(
        priority: const SourcePriority(<String>['subsonic', 'jellyfin']),
        jellyfin: <Track>[_jelly('j', title: 'Hello')],
        subsonic: <Track>[_sub('s', title: 'Hello')],
      );

      final List<Track> results = filterTracks(
        container.read(libraryUnifiedTracksProvider),
        'hello',
      );
      expect(results, hasLength(1));
    });
  });

  group('logicalSourceIdsProvider', () {
    test('maps a displayed row to every provider copy for removal', () async {
      final container = await _seed(
        priority: const SourcePriority(<String>['subsonic', 'jellyfin']),
        jellyfin: <Track>[_jelly('j', title: 'Hello')],
        subsonic: <Track>[_sub('s', title: 'Hello')],
      );

      final Map<String, List<String>> bySource =
          container.read(logicalSourceIdsProvider);
      // The visible row is the Subsonic primary; removing it forgets both copies.
      expect(bySource['s'], containsAll(<String>['j', 's']));
    });
  });
}
