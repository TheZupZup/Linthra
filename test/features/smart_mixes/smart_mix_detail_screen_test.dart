import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/play_history_repository_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/smart_mixes/smart_mix_detail_screen.dart';
import 'package:linthra/shared/widgets/loading_indicator.dart';

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

    testWidgets(
        'a song finishing while the mix is open keeps the list where the '
        'user left it', (tester) async {
      final List<Track> library = <Track>[
        for (int i = 0; i < 60; i++)
          Track(id: 't$i', title: 'Song $i', uri: 'jellyfin:t$i'),
      ];
      await _pump(tester, kindId: 'recentlyAdded', tracks: library);
      await tester.drag(find.byType(ListView), const Offset(0, -1500));
      await tester.pumpAndSettle();
      final double scrolled = _listOffset(tester);
      expect(scrolled, greaterThan(0));

      // Music plays on while the user browses: the player records each song
      // that reaches its end, which is what feeds the play-based mixes.
      final ProviderContainer container = ProviderScope.containerOf(
          tester.element(find.byType(SmartMixDetailScreen)));
      await container
          .read(playHistoryRepositoryProvider)
          .recordCompletion(library[3]);
      await tester.pump();

      expect(
        find.byType(LoadingIndicator),
        findsNothing,
        reason: 'the mix being recomputed is no reason to take it off screen',
      );
      await tester.pumpAndSettle();
      expect(_listOffset(tester), scrolled);
    });

    testWidgets(
        "a song's menu acts on that song when the mix reorders under it",
        (tester) async {
      final FakePlaybackController controller =
          await _pump(tester, kindId: 'recentlyPlayed');
      final ProviderContainer container = ProviderScope.containerOf(
          tester.element(find.byType(SmartMixDetailScreen)));
      final history = container.read(playHistoryRepositoryProvider);
      await history.recordCompletion(_tracks[2]);
      await history.recordCompletion(_tracks[1]);
      await history.recordCompletion(_tracks[0]);
      await tester.pumpAndSettle();

      // Most recent first: A, B, C. The menu of the second song, B.
      await tester.tap(find.byTooltip('More actions').at(1));
      await tester.pumpAndSettle();
      // While it is open a song ends: C moves to the top, B one row down.
      await history.recordCompletion(_tracks[2]);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Play next'));
      await tester.pumpAndSettle();

      expect(
        controller.playNextCalls.map((Track t) => t.title),
        <String>['Song B'],
        reason: 'the menu was opened on Song B, and the song now drawn where '
            'it was is another one',
      );
    });
  });
}

/// How far the mix's track list is scrolled.
double _listOffset(WidgetTester tester) {
  return tester
      .state<ScrollableState>(find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ))
      .position
      .pixels;
}
