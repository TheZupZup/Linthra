import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/library/album_detail_screen.dart';
import 'package:linthra/features/library/artist_detail_screen.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/library/widgets/album_tile.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';

import '../player/fake_playback_controller.dart';
import 'fake_music_library_repository.dart';

const List<Track> _tracks = <Track>[
  Track(
    id: '1',
    title: 'Alpha',
    uri: 'jellyfin:1',
    artistName: 'Daft Punk',
    albumName: 'Discovery',
    trackNumber: 1,
  ),
  Track(
    id: '2',
    title: 'Beta',
    uri: 'jellyfin:2',
    artistName: 'Daft Punk',
    albumName: 'Homework',
    trackNumber: 1,
  ),
  Track(
    id: '3',
    title: 'Gamma',
    uri: 'jellyfin:3',
    artistName: 'Adele',
    albumName: '25',
    trackNumber: 1,
  ),
];

GoRouter _router() {
  return GoRouter(
    initialLocation: AppRoutes.library,
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.library,
        builder: (_, __) => const LibraryScreen(),
      ),
      GoRoute(
        path: '/library/album/:id',
        builder: (_, GoRouterState s) =>
            AlbumDetailScreen(albumId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/library/artist/:id',
        builder: (_, GoRouterState s) =>
            ArtistDetailScreen(artistId: s.pathParameters['id']!),
      ),
      GoRoute(path: AppRoutes.player, builder: (_, __) => const PlayerScreen()),
    ],
  );
}

Future<FakePlaybackController> _pump(
  WidgetTester tester, {
  List<Track> tracks = _tracks,
}) async {
  final FakePlaybackController controller = FakePlaybackController();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository(tracks: tracks)),
        playlistStoreProvider.overrideWithValue(InMemoryPlaylistStore()),
        playbackControllerProvider.overrideWithValue(controller),
      ],
      child: MaterialApp.router(routerConfig: _router()),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _openArtist(WidgetTester tester, String name) async {
  await tester.tap(find.text('Artists'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
}

void main() {
  group('ArtistDetailScreen', () {
    testWidgets('tapping an artist opens detail listing albums and tracks',
        (tester) async {
      await _pump(tester);
      await _openArtist(tester, 'Daft Punk');

      expect(find.text('Play all'), findsOneWidget);
      expect(find.text('Shuffle all'), findsOneWidget);
      // Albums section (the artist has two albums) and songs section.
      expect(find.text('Albums'), findsOneWidget);
      expect(find.text('Songs'), findsOneWidget);
      expect(find.byType(AlbumTile), findsNWidgets(2));
      // This artist's tracks, not the other artist's.
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Gamma'), findsNothing);
    });

    testWidgets('Play all queues the artist tracks', (tester) async {
      final FakePlaybackController controller = await _pump(tester);
      await _openArtist(tester, 'Daft Punk');

      await tester.tap(find.text('Play all'));
      await tester.pumpAndSettle();

      // Two tracks by Daft Punk; album order puts Discovery before Homework.
      expect(controller.state.currentTrack?.id, '1');
      expect(controller.state.upNext.map((Track t) => t.id), <String>['2']);
    });

    testWidgets('tapping an album in the artist detail opens that album',
        (tester) async {
      await _pump(tester);
      await _openArtist(tester, 'Daft Punk');

      await tester.tap(find.text('Discovery'));
      await tester.pumpAndSettle();

      // Now on the album detail: its Play action and only its track.
      expect(find.text('Play'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsNothing);
    });

    testWidgets('long-pressing an artist album adds only that album songs',
        (tester) async {
      await _pump(tester);
      await _openArtist(tester, 'Daft Punk');

      await tester.longPress(find.text('Discovery'));
      await tester.pumpAndSettle();

      expect(find.text('Add to playlist'), findsOneWidget);
      expect(find.text('Add 2 songs to playlist'), findsNothing);
      expect(find.text('New playlist'), findsOneWidget);
    });

    testWidgets('adds every artist track through the bulk playlist sheet',
        (tester) async {
      await _pump(tester);
      await _openArtist(tester, 'Daft Punk');

      await tester.tap(find.byTooltip('Add all songs to playlist'));
      await tester.pumpAndSettle();

      expect(find.text('Add 2 songs to playlist'), findsOneWidget);
      expect(find.text('New playlist'), findsOneWidget);
    });

    testWidgets('an artist with missing metadata shows Unknown Artist',
        (tester) async {
      final FakePlaybackController controller = await _pump(
        tester,
        tracks: const <Track>[
          Track(id: 'x', title: 'Untagged', uri: 'file:///x.mp3'),
        ],
      );
      await _openArtist(tester, 'Unknown Artist');

      expect(find.text('Play all'), findsOneWidget);
      expect(find.text('Untagged'), findsOneWidget);

      await tester.tap(find.text('Play all'));
      await tester.pumpAndSettle();
      expect(controller.state.currentTrack?.id, 'x');
    });
  });
}
