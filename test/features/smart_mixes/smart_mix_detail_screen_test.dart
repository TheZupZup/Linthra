import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/smart_mixes/smart_mix_detail_screen.dart';

import '../library/fake_music_library_repository.dart';
import '../player/fake_playback_controller.dart';

const List<Track> _tracks = <Track>[
  Track(id: 'a', title: 'Song A', uri: 'jellyfin:a', artistName: 'Artist A'),
  Track(id: 'b', title: 'Song B', uri: 'jellyfin:b', artistName: 'Artist B'),
  Track(id: 'c', title: 'Song C', uri: 'jellyfin:c', artistName: 'Artist C'),
];

GoRouter _router(String kindId) {
  return GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (_, __) => SmartMixDetailScreen(kindId: kindId),
      ),
      GoRoute(
        path: AppRoutes.player,
        builder: (_, __) => const Scaffold(body: Text('player-screen')),
      ),
    ],
  );
}

Future<FakePlaybackController> _pump(
  WidgetTester tester, {
  required String kindId,
  List<Track> tracks = _tracks,
}) async {
  final FakePlaybackController controller = FakePlaybackController();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository(tracks: tracks)),
        playbackControllerProvider.overrideWithValue(controller),
      ],
      child: MaterialApp.router(routerConfig: _router(kindId)),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  group('SmartMixDetailScreen', () {
    testWidgets('shows the mix title and its tracks', (tester) async {
      await _pump(tester, kindId: 'recentlyAdded');

      expect(find.text('Recently added'), findsOneWidget);
      expect(find.text('Song A'), findsOneWidget);
      expect(find.text('Song B'), findsOneWidget);
      expect(find.text('Song C'), findsOneWidget);
    });

    testWidgets('Play queues the mix and opens the player', (tester) async {
      final FakePlaybackController controller =
          await _pump(tester, kindId: 'recentlyAdded');

      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();

      expect(controller.state.currentTrack, isNotNull);
      expect(controller.playedTracks, isNotEmpty);
      expect(find.text('player-screen'), findsOneWidget);
    });

    testWidgets('Shuffle turns shuffle on and starts playback', (tester) async {
      final FakePlaybackController controller =
          await _pump(tester, kindId: 'recentlyAdded');

      await tester.tap(find.text('Shuffle'));
      await tester.pumpAndSettle();

      expect(controller.state.shuffleEnabled, isTrue);
      expect(controller.state.currentTrack, isNotNull);
      expect(find.text('player-screen'), findsOneWidget);
    });

    testWidgets('tapping a track plays from there', (tester) async {
      final FakePlaybackController controller =
          await _pump(tester, kindId: 'recentlyAdded');

      await tester.tap(find.text('Song B'));
      await tester.pumpAndSettle();

      expect(controller.state.currentTrack?.id, 'b');
      expect(find.text('player-screen'), findsOneWidget);
    });

    testWidgets('an empty mix shows a friendly empty state', (tester) async {
      // Nothing has been played, so "Recently played" is empty.
      await _pump(tester, kindId: 'recentlyPlayed');

      expect(find.text('Nothing here yet'), findsOneWidget);
      expect(find.text('Play'), findsNothing);
    });

    testWidgets('an unknown mix id shows "Mix not found"', (tester) async {
      await _pump(tester, kindId: 'bogus');

      expect(find.text('Mix not found'), findsOneWidget);
    });
  });
}
