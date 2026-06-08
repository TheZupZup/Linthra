import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/source_priority.dart';
import 'package:linthra/core/catalog/source_strategy.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/downloads/download_providers.dart';
import 'package:linthra/features/library/library_controller.dart';
import 'package:linthra/features/library/playback_candidates_provider.dart';
import 'package:linthra/features/library/playback_source_strategy_controller.dart';
import 'package:linthra/features/library/source_preference_controller.dart';

final Uri _jellyArt =
    Uri.parse('https://music.example.com/Items/j/Images/Primary');

Track _jelly(String id, {required String title, Uri? artwork}) => Track(
      id: id,
      title: title,
      uri: 'jellyfin:$id',
      artistName: 'Adele',
      albumName: '25',
      duration: const Duration(minutes: 3),
      artworkUri: artwork,
    );

Track _sub(String id, {required String title}) => Track(
      id: id,
      title: title,
      uri: 'subsonic:$id',
      artistName: 'Adele',
      albumName: '25',
      duration: const Duration(minutes: 3),
    );

/// Pins the source preference for a deterministic test.
class _FixedPreference extends SourcePreferenceController {
  _FixedPreference(this._priority);
  final SourcePriority _priority;
  @override
  SourcePriority build() => _priority;
}

/// Pins the playback source strategy for a deterministic test.
class _FixedStrategy extends PlaybackSourceStrategyController {
  _FixedStrategy(this._strategy);
  final PlaybackSourceStrategy _strategy;
  @override
  PlaybackSourceStrategy build() => _strategy;
}

Future<ProviderContainer> _seed({
  required SourcePriority priority,
  required List<Track> jellyfin,
  required List<Track> subsonic,
  PlaybackSourceStrategy strategy = PlaybackSourceStrategy.preferDefault,
  Set<String> cachedIds = const <String>{},
}) async {
  final repo = InMemoryMusicLibraryRepository();
  final container = ProviderContainer(
    overrides: <Override>[
      musicLibraryRepositoryProvider.overrideWithValue(repo),
      librarySourcePriorityProvider
          .overrideWith(() => _FixedPreference(priority)),
      playbackSourceStrategyProvider
          .overrideWith(() => _FixedStrategy(strategy)),
      offlineAvailableTrackIdsProvider.overrideWithValue(cachedIds),
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
  group('playbackCandidatesProvider', () {
    test('a cross-provider song maps to ordered candidates, Jellyfin first',
        () async {
      final container = await _seed(
        priority: const SourcePriority(<String>['jellyfin', 'subsonic']),
        jellyfin: <Track>[_jelly('j', title: 'Hello', artwork: _jellyArt)],
        subsonic: <Track>[_sub('s', title: 'Hello')],
      );

      final Map<String, List<Track>> map =
          container.read(playbackCandidatesProvider);

      // Keyed by the displayed (primary) track id; Jellyfin is preferred.
      expect(map.keys, <String>['j']);
      expect(
        map['j']!.map((Track t) => t.uri).toList(),
        <String>['jellyfin:j', 'subsonic:s'],
      );
    });

    test('every candidate carries the row\'s best-available cover', () async {
      // Subsonic is preferred (and carries no artwork), but the Jellyfin copy
      // has a cover — so both candidates must carry it, so a fallback keeps art.
      final container = await _seed(
        priority: const SourcePriority(<String>['subsonic', 'jellyfin']),
        jellyfin: <Track>[_jelly('j', title: 'Hello', artwork: _jellyArt)],
        subsonic: <Track>[_sub('s', title: 'Hello')],
      );

      final Map<String, List<Track>> map =
          container.read(playbackCandidatesProvider);

      // Displayed copy is the Subsonic one; Jellyfin is the fallback.
      final List<Track> candidates = map['s']!;
      expect(candidates.map((Track t) => t.uri).toList(),
          <String>['subsonic:s', 'jellyfin:j']);
      expect(candidates.every((Track t) => t.artworkUri == _jellyArt), isTrue);
    });

    test('single-source songs are not listed (no fallback needed)', () async {
      final container = await _seed(
        priority: const SourcePriority(<String>['jellyfin', 'subsonic']),
        jellyfin: <Track>[_jelly('only', title: 'Jelly Only')],
        subsonic: <Track>[_sub('s', title: 'Navi Only')],
      );

      final Map<String, List<Track>> map =
          container.read(playbackCandidatesProvider);

      expect(map, isEmpty);
    });
  });

  group('playbackCandidatesProvider — strategy ordering', () {
    test('preferDefault leaves the default-source order unchanged', () async {
      final container = await _seed(
        priority: const SourcePriority(<String>['jellyfin', 'subsonic']),
        jellyfin: <Track>[_jelly('j', title: 'Hello')],
        subsonic: <Track>[_sub('s', title: 'Hello')],
        strategy: PlaybackSourceStrategy.preferDefault,
      );

      final Map<String, List<Track>> map =
          container.read(playbackCandidatesProvider);
      expect(map['j']!.map((Track t) => t.uri).toList(),
          <String>['jellyfin:j', 'subsonic:s']);
    });

    test('preferLocalCache promotes a cached copy ahead of the default',
        () async {
      // Jellyfin is the default (so leads by default), but the Subsonic copy is
      // downloaded — "prefer local/cache" must play the cached copy first.
      final container = await _seed(
        priority: const SourcePriority(<String>['jellyfin', 'subsonic']),
        jellyfin: <Track>[_jelly('j', title: 'Hello')],
        subsonic: <Track>[_sub('s', title: 'Hello')],
        strategy: PlaybackSourceStrategy.preferLocalCache,
        cachedIds: <String>{'s'},
      );

      final Map<String, List<Track>> map =
          container.read(playbackCandidatesProvider);
      // Same display id (Jellyfin primary), but the cached Subsonic copy leads.
      expect(map['j']!.map((Track t) => t.uri).toList(),
          <String>['subsonic:s', 'jellyfin:j']);
    });

    test(
        'preferLocalCache keeps the default order when nothing is cached/local',
        () async {
      final container = await _seed(
        priority: const SourcePriority(<String>['jellyfin', 'subsonic']),
        jellyfin: <Track>[_jelly('j', title: 'Hello')],
        subsonic: <Track>[_sub('s', title: 'Hello')],
        strategy: PlaybackSourceStrategy.preferLocalCache,
        // No offline copies.
      );

      final Map<String, List<Track>> map =
          container.read(playbackCandidatesProvider);
      expect(map['j']!.map((Track t) => t.uri).toList(),
          <String>['jellyfin:j', 'subsonic:s']);
    });
  });
}
