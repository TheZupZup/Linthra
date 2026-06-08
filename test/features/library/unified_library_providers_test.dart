import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/library_grouping.dart';
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

Track _jelly(String id,
        {required String title, String album = '25', Uri? artwork}) =>
    Track(
      id: id,
      title: title,
      uri: 'jellyfin:$id',
      artistName: 'Adele',
      albumName: album,
      duration: const Duration(minutes: 3),
      artworkUri: artwork,
    );

Track _sub(String id, {required String title, String album = '25'}) => Track(
      id: id,
      title: title,
      uri: 'subsonic:$id',
      artistName: 'Adele',
      albumName: album,
      duration: const Duration(minutes: 3),
    );

final Uri _jellyArt =
    Uri.parse('https://music.example.com/Items/j/Images/Primary');

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

  group('libraryUnifiedTracksProvider — artwork is not regressed', () {
    test('a Subsonic-preferred row keeps the Jellyfin copy\'s cover', () async {
      // Subsonic is active/preferred, but Subsonic tracks carry no artwork. The
      // merged row must still show the Jellyfin copy's cover instead of going
      // blank — the reported "covers disappeared after unification" bug.
      final container = await _seed(
        priority: const SourcePriority(<String>['subsonic', 'jellyfin']),
        jellyfin: <Track>[_jelly('j', title: 'Hello', artwork: _jellyArt)],
        subsonic: <Track>[_sub('s', title: 'Hello')],
      );

      final List<Track> songs = container.read(libraryUnifiedTracksProvider);
      expect(songs, hasLength(1));
      // Plays from the preferred (Subsonic) copy...
      expect(songs.single.uri, 'subsonic:s');
      // ...but displays the Jellyfin cover.
      expect(songs.single.artworkUri, _jellyArt);
    });

    test('albums derived from the unified catalog keep their cover', () async {
      final container = await _seed(
        priority: const SourcePriority(<String>['subsonic', 'jellyfin']),
        jellyfin: <Track>[_jelly('j', title: 'Hello', artwork: _jellyArt)],
        subsonic: <Track>[_sub('s', title: 'Hello')],
      );

      final List<Album> albums = groupAlbums(
        container.read(libraryUnifiedTracksProvider),
      );
      expect(albums, hasLength(1));
      expect(albums.single.artworkUri, _jellyArt);
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
