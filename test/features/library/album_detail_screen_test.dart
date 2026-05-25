import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/album_detail_screen.dart';
import 'package:linthra/features/library/artist_detail_screen.dart';
import 'package:linthra/features/library/library_screen.dart';
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
    albumName: 'Discovery',
    trackNumber: 2,
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
        playbackControllerProvider.overrideWithValue(controller),
      ],
      child: MaterialApp.router(routerConfig: _router()),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _openAlbum(WidgetTester tester, String title) async {
  await tester.tap(find.text('Albums'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
}

void main() {
  group('AlbumDetailScreen', () {
    testWidgets('tapping an album opens its detail listing its tracks',
        (tester) async {
      await _pump(tester);
      await _openAlbum(tester, 'Discovery');

      // The header's Play action confirms we're on the detail screen.
      expect(find.widgetWithText(FilledButton, 'Play'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Shuffle'), findsOneWidget);
      // Only this album's tracks are listed.
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Gamma'), findsNothing);
    });

    testWidgets('Play queues the album tracks in order', (tester) async {
      final FakePlaybackController controller = await _pump(tester);
      await _openAlbum(tester, 'Discovery');

      await tester.tap(find.widgetWithText(FilledButton, 'Play'));
      await tester.pumpAndSettle();

      expect(controller.state.currentTrack?.id, '1');
      expect(controller.state.upNext.map((Track t) => t.id), <String>['2']);
    });

    testWidgets('tapping a track plays it and queues the rest of the album',
        (tester) async {
      final FakePlaybackController controller = await _pump(tester);
      await _openAlbum(tester, 'Discovery');

      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();

      // Started at Beta; nothing after it on this album.
      expect(controller.state.currentTrack?.id, '2');
      expect(controller.state.upNext, isEmpty);
    });

    testWidgets('an album with missing metadata shows Unknown Album',
        (tester) async {
      await _pump(
        tester,
        tracks: const <Track>[
          Track(id: 'x', title: 'Untagged', uri: 'file:///x.mp3'),
        ],
      );
      await _openAlbum(tester, 'Unknown Album');

      expect(find.widgetWithText(FilledButton, 'Play'), findsOneWidget);
      expect(find.text('Untagged'), findsOneWidget);
    });
  });
}
