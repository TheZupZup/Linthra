import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/favorites_repository.dart';
import 'package:linthra/core/repositories/remote_sync_result.dart';
import 'package:linthra/core/services/playback_candidate_source.dart';
import 'package:linthra/data/repositories/favorites_repository_provider.dart';
import 'package:linthra/features/player/now_playing_favorite_target.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/widgets/now_playing_actions.dart';

import 'fake_playback_controller.dart';

const Track _jellyfin = Track(
  id: 'j1',
  title: 'Matched song',
  uri: 'jellyfin:j1',
);

const Track _subsonic = Track(
  id: 's1',
  title: 'Matched song',
  uri: 'subsonic:s1',
);

const Track _local = Track(
  id: 'l1',
  title: 'Local song',
  uri: '/music/local.mp3',
);

void main() {
  group('resolveNowPlayingFavoriteTarget', () {
    test('targets Subsonic candidate when playback resolved to Subsonic', () {
      final target = resolveNowPlayingFavoriteTarget(
        displayTrack: _jellyfin,
        playbackState: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _subsonic,
          source: PlaybackSource.streamingDirect,
        ),
        candidateSource: const MapPlaybackCandidateSource(_matchedCandidates),
      );

      expect(target.uri, 'subsonic:s1');
    });

    test('targets Jellyfin candidate when playback resolved to Jellyfin', () {
      final target = resolveNowPlayingFavoriteTarget(
        displayTrack: _subsonic,
        playbackState: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _jellyfin,
          source: PlaybackSource.streamingDirect,
        ),
        candidateSource: const MapPlaybackCandidateSource(_matchedCandidates),
      );

      expect(target.uri, 'jellyfin:j1');
    });

    test('keeps a local-only track local', () {
      final target = resolveNowPlayingFavoriteTarget(
        displayTrack: _local,
        playbackState: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _local,
          source: PlaybackSource.localFile,
        ),
        candidateSource: const NoFallbackCandidateSource(),
      );

      expect(target, _local);
    });

    test('falls back to current track when no better target can be resolved',
        () {
      final target = resolveNowPlayingFavoriteTarget(
        displayTrack: _jellyfin,
        playbackState: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _jellyfin,
          source: PlaybackSource.streamingDirect,
        ),
        candidateSource: const NoFallbackCandidateSource(),
      );

      expect(target.uri, 'jellyfin:j1');
    });
  });

  group('NowPlayingActions favorite target', () {
    testWidgets(
      'display Jellyfin + actual Subsonic playback writes Subsonic favorite',
      (tester) async {
        final favorites = _RecordingFavoritesRepository();
        await _pumpActions(
          tester,
          displayTrack: _jellyfin,
          playingTrack: _subsonic,
          favorites: favorites,
          candidates: const MapPlaybackCandidateSource(_matchedCandidates),
        );

        await tester.tap(find.byTooltip('Favorite'));
        await tester.pump();

        expect(favorites.writes.single.track.uri, 'subsonic:s1');
        expect(favorites.writes.single.favorite, isTrue);
      },
    );

    testWidgets('heart icon state uses resolved Subsonic target',
        (tester) async {
      await _pumpActions(
        tester,
        displayTrack: _jellyfin,
        playingTrack: _subsonic,
        favorites: _RecordingFavoritesRepository(<String>{'subsonic:s1'}),
        candidates: const MapPlaybackCandidateSource(_matchedCandidates),
      );

      expect(find.byIcon(Icons.favorite), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border), findsNothing);
    });

    testWidgets('Jellyfin-only track still writes Jellyfin', (tester) async {
      final favorites = _RecordingFavoritesRepository();
      await _pumpActions(
        tester,
        displayTrack: _jellyfin,
        playingTrack: _jellyfin,
        favorites: favorites,
      );

      await tester.tap(find.byTooltip('Favorite'));
      await tester.pump();

      expect(favorites.writes.single.track.uri, 'jellyfin:j1');
    });

    testWidgets('Subsonic-only track writes Subsonic', (tester) async {
      final favorites = _RecordingFavoritesRepository();
      await _pumpActions(
        tester,
        displayTrack: _subsonic,
        playingTrack: _subsonic,
        favorites: favorites,
      );

      await tester.tap(find.byTooltip('Favorite'));
      await tester.pump();

      expect(favorites.writes.single.track.uri, 'subsonic:s1');
    });

    testWidgets('fallback from Jellyfin to Subsonic writes Subsonic',
        (tester) async {
      final favorites = _RecordingFavoritesRepository();
      await _pumpActions(
        tester,
        displayTrack: _jellyfin,
        playingTrack: _subsonic,
        favorites: favorites,
        candidates: const MapPlaybackCandidateSource(_matchedCandidates),
      );

      await tester.tap(find.byTooltip('Favorite'));
      await tester.pump();

      expect(favorites.writes.single.track.uri, 'subsonic:s1');
    });

    testWidgets('local tracks do not pretend to sync to Navidrome',
        (tester) async {
      final favorites = _RecordingFavoritesRepository();
      await _pumpActions(
        tester,
        displayTrack: _local,
        playingTrack: _local,
        favorites: favorites,
      );

      await tester.tap(find.byTooltip('Favorite'));
      await tester.pump();

      expect(favorites.writes.single.track.uri, '/music/local.mp3');
    });
  });
}

Map<String, List<Track>> _matchedCandidates() => const <String, List<Track>>{
      'jellyfin:j1': <Track>[_jellyfin, _subsonic],
      'subsonic:s1': <Track>[_jellyfin, _subsonic],
    };

Future<void> _pumpActions(
  WidgetTester tester, {
  required Track displayTrack,
  required Track playingTrack,
  required _RecordingFavoritesRepository favorites,
  PlaybackCandidateSource candidates = const NoFallbackCandidateSource(),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        favoritesRepositoryProvider.overrideWithValue(favorites),
        playbackCandidateSourceProvider.overrideWithValue(candidates),
        playbackControllerProvider.overrideWithValue(
          FakePlaybackController(
            initial: PlaybackState(
              status: PlaybackStatus.playing,
              currentTrack: playingTrack,
              source: playingTrack.uri.startsWith('/')
                  ? PlaybackSource.localFile
                  : PlaybackSource.streamingDirect,
            ),
          ),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(body: NowPlayingActions(track: displayTrack)),
      ),
    ),
  );
  await tester.pump();
}

class _FavoriteWrite {
  const _FavoriteWrite(this.track, this.favorite);

  final Track track;
  final bool favorite;
}

class _RecordingFavoritesRepository implements FavoritesRepository {
  _RecordingFavoritesRepository([Set<String> initial = const <String>{}])
      : _ids = <String>{...initial};

  final List<_FavoriteWrite> writes = <_FavoriteWrite>[];
  Set<String> _ids;

  @override
  Stream<Set<String>> get favoritesStream async* {
    yield _ids;
  }

  @override
  bool isFavorite(String trackUri) => _ids.contains(trackUri);

  @override
  Future<void> setFavorite(Track track, bool favorite) async {
    writes.add(_FavoriteWrite(track, favorite));
    if (favorite) {
      _ids = <String>{..._ids, track.uri};
    } else {
      _ids = <String>{..._ids}..remove(track.uri);
    }
  }

  @override
  Future<FavoritesSyncResult> refreshFromRemote() async =>
      FavoritesSyncResult.synced(_ids.length);

  @override
  Future<void> clearRemote({String? providerScheme}) async {
    _ids = const <String>{};
  }
}
