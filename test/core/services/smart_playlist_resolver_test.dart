import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/play_history.dart';
import 'package:linthra/core/models/smart_playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/services/smart_playlist_resolver.dart';

Track _t(String id) => Track(id: id, title: 'Title $id', uri: 'jellyfin:$id');

List<String> _ids(List<Track> tracks) =>
    <String>[for (final Track t in tracks) t.id];

void main() {
  // A small catalog plus the on-device signals each mix is built from.
  final List<Track> catalog = <Track>[_t('a'), _t('b'), _t('c'), _t('d')];

  final PlayHistory history = PlayHistory(
    stats: <String, TrackPlayStats>{
      'a': TrackPlayStats(playCount: 5, lastPlayedAt: DateTime(2024, 1, 1)),
      'b': TrackPlayStats(playCount: 1, lastPlayedAt: DateTime(2024, 1, 3)),
      'c': TrackPlayStats(playCount: 3, lastPlayedAt: DateTime(2024, 1, 2)),
    },
  );

  // Keyed by the provider-namespaced uri (jellyfin:<id> here, matching the _t
  // helper), the way RecordingMusicLibraryRepository now stamps first-seen times.
  final Map<String, DateTime> addedAt = <String, DateTime>{
    'jellyfin:a': DateTime(2024, 1, 1),
    'jellyfin:b': DateTime(2024, 1, 3),
    'jellyfin:c': DateTime(2024, 1, 2),
    'jellyfin:d': DateTime(2024, 1, 4),
  };

  List<Track> resolve(
    SmartPlaylistKind kind, {
    List<Track>? tracks,
    Set<String> favoriteIds = const <String>{},
    Set<String> downloadedKeys = const <String>{},
    int maxTracks = 100,
    Random? random,
  }) {
    return SmartPlaylistResolver(maxTracks: maxTracks).resolve(
      kind,
      allTracks: tracks ?? catalog,
      history: history,
      addedAt: addedAt,
      favoriteIds: favoriteIds,
      downloadedKeys: downloadedKeys,
      random: random,
    );
  }

  group('SmartPlaylistResolver', () {
    test('recently added is newest-first by first-seen time', () {
      expect(_ids(resolve(SmartPlaylistKind.recentlyAdded)),
          <String>['d', 'b', 'c', 'a']);
    });

    test('recently added falls back to a legacy bare-id timestamp', () {
      // An upgraded user whose store predates uri keys: a remote track's
      // first-seen time is still under the bare id until the next sync migrates
      // it. The read must honor that key so Recently Added keeps its order right
      // after the upgrade instead of collapsing to catalog order.
      final List<Track> result =
          const SmartPlaylistResolver(maxTracks: 100).resolve(
        SmartPlaylistKind.recentlyAdded,
        allTracks: <Track>[_t('a'), _t('b')],
        history: history,
        addedAt: <String, DateTime>{
          'jellyfin:a': DateTime(2024, 1, 1), // already migrated to the uri key
          'b': DateTime(2024, 1, 5), // legacy bare-id key, and newer
        },
        favoriteIds: const <String>{},
        downloadedKeys: const <String>{},
      );
      // 'b' (legacy key, Jan 5) outranks 'a' (uri key, Jan 1).
      expect(_ids(result), <String>['b', 'a']);
    });

    test('recently played is most-recently-played first, played-only', () {
      // a@Jan1, b@Jan3, c@Jan2 → b, c, a; d was never played so it's excluded.
      expect(_ids(resolve(SmartPlaylistKind.recentlyPlayed)),
          <String>['b', 'c', 'a']);
    });

    test('most played is highest-count first', () {
      // counts a:5, c:3, b:1 → a, c, b; d excluded.
      expect(
          _ids(resolve(SmartPlaylistKind.mostPlayed)), <String>['a', 'c', 'b']);
    });

    test('favorites mix uses the favorite id set', () {
      final List<Track> result = resolve(
        SmartPlaylistKind.favorites,
        // 'z' isn't in the catalog and must be ignored gracefully.
        favoriteIds: <String>{'b', 'd', 'z'},
      );
      expect(_ids(result), <String>['b', 'd']);
    });

    test('downloaded mix uses the cached (downloaded) cache-key set', () {
      final List<Track> result = resolve(
        SmartPlaylistKind.downloaded,
        downloadedKeys: <String>{
          CachedTrack.cacheKeyForTrack(_t('a')),
          CachedTrack.cacheKeyForTrack(_t('c')),
        },
      );
      expect(_ids(result), <String>['a', 'c']);
    });

    test('downloaded mix is provider-aware for same-id copies', () {
      // Two providers expose the same bare id 101; only the Subsonic copy is
      // downloaded. The mix must show that copy alone — never the Jellyfin copy
      // that merely shares the id.
      const Track jelly = Track(id: '101', title: 'A', uri: 'jellyfin:101');
      const Track sub = Track(id: '101', title: 'A', uri: 'subsonic:101');
      final List<Track> result = resolve(
        SmartPlaylistKind.downloaded,
        tracks: <Track>[jelly, sub],
        downloadedKeys: <String>{CachedTrack.cacheKeyForTrack(sub)},
      );
      expect(result.map((Track t) => t.uri).toList(), <String>['subsonic:101']);
    });

    test('never played excludes anything in the play history', () {
      // a, b, c have history; only d is never played.
      expect(_ids(resolve(SmartPlaylistKind.neverPlayed)), <String>['d']);
    });

    test('random mix is bounded by maxTracks', () {
      final List<Track> result =
          resolve(SmartPlaylistKind.random, maxTracks: 2, random: Random(7));
      expect(result, hasLength(2));
    });

    test('random mix is a permutation that does not mutate the input', () {
      final List<Track> input = <Track>[_t('a'), _t('b'), _t('c'), _t('d')];
      final List<String> before = _ids(input);
      final List<Track> result = resolve(
        SmartPlaylistKind.random,
        tracks: input,
        random: Random(1),
      );
      // Same members, input untouched.
      expect(_ids(result).toSet(), before.toSet());
      expect(_ids(input), before);
    });

    test('random mix is safe on an empty catalog', () {
      expect(
        resolve(SmartPlaylistKind.random, tracks: const <Track>[]),
        isEmpty,
      );
    });

    test('an empty catalog yields an empty mix for every kind', () {
      for (final SmartPlaylistKind kind in SmartPlaylistKind.values) {
        expect(
          resolve(kind, tracks: const <Track>[], favoriteIds: <String>{'a'}),
          isEmpty,
          reason: 'kind $kind should be empty for an empty catalog',
        );
      }
    });
  });
}
