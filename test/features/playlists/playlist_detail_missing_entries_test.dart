// A playlist with songs that are no longer in the library still plays the
// right ones.
//
// A playlist stores its songs by uri, and a song can leave the library while
// it stays listed (a deleted file, a server that dropped it). The open
// playlist then shows only the songs it can find, says how many it can't,
// and turns drag-to-reorder off, since a row's place no longer matches its
// place in the stored list and a drag would scramble the order. Tapping a row
// has to start that row's song with the songs shown around it, never be
// thrown off by one by the missing entry before it.
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

const List<Track> _library = <Track>[
  Track(id: 'a', title: 'Song A', uri: 'file:///a.mp3'),
  Track(id: 'b', title: 'Song B', uri: 'file:///b.mp3'),
  Track(id: 'c', title: 'Song C', uri: 'file:///c.mp3'),
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
  required List<String> trackIds,
  required FakePlaybackController controller,
}) async {
  final InMemoryPlaylistStore store = InMemoryPlaylistStore();
  await store.save(<Playlist>[
    Playlist(id: 'p1', name: 'Road Trip', trackIds: trackIds),
  ]);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playlistStoreProvider.overrideWithValue(store),
        musicLibraryRepositoryProvider.overrideWithValue(
          FakeMusicLibraryRepository(tracks: _library),
        ),
        playbackControllerProvider.overrideWithValue(controller),
      ],
      child: MaterialApp.router(routerConfig: _router()),
    ),
  );
  await tester.pumpAndSettle();
}

/// a, then a song that left the library, then b.
const List<String> _withAGap = <String>[
  'file:///a.mp3',
  'file:///gone.mp3',
  'file:///b.mp3',
];

List<String> _ids(Iterable<Track> tracks) =>
    <String>[for (final Track t in tracks) t.id];

void main() {
  testWidgets('says a song is missing and offers no drag handles',
      (tester) async {
    await _pump(
      tester,
      trackIds: _withAGap,
      controller: FakePlaybackController(),
    );

    expect(find.text('Song A'), findsOneWidget);
    expect(find.text('Song B'), findsOneWidget);
    expect(find.text('1 song is no longer in your library.'), findsOneWidget);
    expect(find.byIcon(Icons.drag_handle), findsNothing);
  });

  testWidgets('with every song found, the rows can be dragged', (tester) async {
    // The other side of the one above, so its missing handles mean something.
    await _pump(
      tester,
      trackIds: const <String>['file:///a.mp3', 'file:///b.mp3'],
      controller: FakePlaybackController(),
    );

    expect(find.textContaining('no longer in your library'), findsNothing);
    expect(find.byIcon(Icons.drag_handle), findsNWidgets(2));
  });

  testWidgets('tapping the song after the gap plays it, after the one before',
      (tester) async {
    final FakePlaybackController controller = FakePlaybackController();
    // A song after b too, so a row index taken from the stored list (one
    // further along) would start c instead.
    await _pump(
      tester,
      trackIds: const <String>[..._withAGap, 'file:///c.mp3'],
      controller: controller,
    );

    await tester.tap(find.text('Song B'));
    await tester.pumpAndSettle();

    expect(controller.playedTracks.single.id, 'b');
    expect(_ids(controller.state.previous), <String>['a']);
    expect(_ids(controller.state.upNext), <String>['c']);
    expect(find.text('player-screen'), findsOneWidget);
  });

  testWidgets('Play queues exactly the songs that were found', (tester) async {
    final FakePlaybackController controller = FakePlaybackController();
    await _pump(tester, trackIds: _withAGap, controller: controller);

    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();

    expect(controller.playedTracks.single.id, 'a');
    expect(controller.state.previous, isEmpty);
    expect(_ids(controller.state.upNext), <String>['b']);
  });
}
