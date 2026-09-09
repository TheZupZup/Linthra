import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/catalog/library_grouping.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/library/album_detail_screen.dart';
import 'package:linthra/features/library/artist_detail_screen.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';

import '../player/fake_playback_controller.dart';
import 'fake_music_library_repository.dart';

/// Escape leaves a selection wherever one can be started (#387). Album and
/// artist detail take the same Ctrl and Shift clicks the songs list does, so a
/// keyboard user has to be able to get back out of them the same way — without
/// reaching for the app bar's close button with the mouse.
final List<Track> _tracks = <Track>[
  for (int i = 0; i < 4; i++)
    Track(
      id: '$i',
      title: 'Song $i',
      uri: 'jellyfin:$i',
      artistName: 'Daft Punk',
      albumName: 'Discovery',
      trackNumber: i + 1,
    ),
];

Future<void> _pump(WidgetTester tester, String location) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 900);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository(tracks: _tracks)),
        playlistStoreProvider.overrideWithValue(InMemoryPlaylistStore()),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: location,
          routes: <RouteBase>[
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
            GoRoute(
              path: AppRoutes.player,
              builder: (_, __) => const PlayerScreen(),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _ctrlClick(WidgetTester tester, String title) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

void main() {
  group('Escape leaves a detail-page selection', () {
    testWidgets('on an album page', (tester) async {
      await _pump(
        tester,
        '/library/album/${albumIdForTrack(_tracks.first)}',
      );

      await _ctrlClick(tester, 'Song 0');
      expect(find.text('1 selected'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsNothing);
      // Back on the album's own app bar, with nothing selected.
      expect(find.text('Discovery'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('on an artist page', (tester) async {
      await _pump(
        tester,
        '/library/artist/${artistIdForTrack(_tracks.first)}',
      );

      await _ctrlClick(tester, 'Song 0');
      expect(find.text('1 selected'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsNothing);
      expect(find.text('Daft Punk'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Escape does nothing when nothing is selected', (tester) async {
      await _pump(
        tester,
        '/library/album/${albumIdForTrack(_tracks.first)}',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(AlbumDetailScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
