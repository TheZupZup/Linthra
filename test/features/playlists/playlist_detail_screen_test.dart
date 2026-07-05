import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/playlists/playlist_detail_screen.dart';

import '../library/fake_music_library_repository.dart';
import '../player/fake_playback_controller.dart';

const List<Track> _tracks = <Track>[
  Track(id: 'a', title: 'Song A', uri: 'file:///a.mp3'),
  Track(id: 'b', title: 'Song B', uri: 'file:///b.mp3'),
];

GoRouter _router() {
  return GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (_, __) => const PlaylistDetailScreen(playlistId: 'p1'),
      ),
      GoRoute(
        path: AppRoutes.player,
        builder: (_, __) => const Scaffold(body: Text('player-screen')),
      ),
    ],
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required InMemoryPlaylistStore store,
  required FakePlaybackController controller,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playlistStoreProvider.overrideWithValue(store),
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository(tracks: _tracks)),
        playbackControllerProvider.overrideWithValue(controller),
      ],
      child: MaterialApp.router(routerConfig: _router()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<InMemoryPlaylistStore> _seededStore() async {
  final InMemoryPlaylistStore store = InMemoryPlaylistStore();
  await store.save(<Playlist>[
    const Playlist(
        id: 'p1',
        name: 'Road Trip',
        trackIds: <String>['file:///a.mp3', 'file:///b.mp3']),
  ]);
  return store;
}

void main() {
  testWidgets('renders the playlist tracks', (tester) async {
    await _pump(
      tester,
      store: await _seededStore(),
      controller: FakePlaybackController(),
    );
    expect(find.text('Road Trip'), findsOneWidget);
    expect(find.text('Song A'), findsOneWidget);
    expect(find.text('Song B'), findsOneWidget);
  });

  testWidgets('Play queues the playlist and opens the player', (tester) async {
    final FakePlaybackController controller = FakePlaybackController();
    await _pump(tester, store: await _seededStore(), controller: controller);

    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();

    expect(controller.playedTracks.first.id, 'a');
    // The rest of the playlist is queued behind the first track.
    expect(controller.state.upNext.map((Track t) => t.id), <String>['b']);
    expect(find.text('player-screen'), findsOneWidget);
  });

  testWidgets('tapping a track plays from there and queues the playlist',
      (tester) async {
    final FakePlaybackController controller = FakePlaybackController();
    await _pump(tester, store: await _seededStore(), controller: controller);

    await tester.tap(find.text('Song B'));
    await tester.pumpAndSettle();

    expect(controller.playedTracks.first.id, 'b');
    expect(find.text('player-screen'), findsOneWidget);
  });

  testWidgets(
      'track row menu toggles favorite without playing or changing the queue',
      (tester) async {
    final FakePlaybackController controller = FakePlaybackController();
    await _pump(tester, store: await _seededStore(), controller: controller);

    await tester.tap(find.byTooltip('Track actions').first);
    await tester.pumpAndSettle();
    expect(find.text('Add to favorites'), findsOneWidget);

    await tester.tap(find.text('Add to favorites'));
    await tester.pumpAndSettle();

    // Favoriting is a pure like: no playback, no queue change.
    expect(controller.playedTracks, isEmpty);
    expect(controller.state.upNext, isEmpty);

    // Reopening the row's menu now offers the filled-heart remove action.
    await tester.tap(find.byTooltip('Track actions').first);
    await tester.pumpAndSettle();
    expect(find.text('Remove from favorites'), findsOneWidget);
  });

  testWidgets('long-press enters selection mode and shows the count',
      (tester) async {
    await _pump(
      tester,
      store: await _seededStore(),
      controller: FakePlaybackController(),
    );

    await tester.longPress(find.text('Song A'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    // Selecting another track updates the count.
    await tester.tap(find.text('Song B'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
  });
}
