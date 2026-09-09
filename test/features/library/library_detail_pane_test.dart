import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:linthra/features/library/widgets/track_tile.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';

import '../player/fake_playback_controller.dart';
import 'fake_music_library_repository.dart';

/// A window wide enough for three panes — rail, grid, detail — keeps the grid
/// on screen while an album is open, so browsing a shelf of albums is a click
/// each rather than a click and a trip back. Narrower windows push the same
/// screen as a route, which is the phone behaviour and stays untouched.
final List<Track> _tracks = <Track>[
  for (int i = 0; i < 4; i++)
    Track(
      id: '$i',
      title: 'Song $i',
      uri: 'jellyfin:$i',
      artistName: i.isEven ? 'Daft Punk' : 'Air',
      albumName: i.isEven ? 'Discovery' : 'Moon Safari',
      trackNumber: i + 1,
    ),
];

/// Comfortably past `listDetailMinWidth` (460 + 600).
const Size _paneWindow = Size(1280, 900);

/// A window with room for the grid alone.
const Size _narrowWindow = Size(800, 900);

Future<void> _pumpLibrary(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider.overrideWithValue(
          FakeMusicLibraryRepository(tracks: _tracks),
        ),
        playlistStoreProvider.overrideWithValue(InMemoryPlaylistStore()),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
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

Future<void> _openTab(WidgetTester tester, String tab) async {
  await tester.tap(find.text(tab));
  await tester.pumpAndSettle();
}

void main() {
  group('Library detail pane', () {
    testWidgets('a wide window opens an album beside the grid', (tester) async {
      await _pumpLibrary(tester, _paneWindow);
      await _openTab(tester, 'Albums');

      expect(find.text('Pick an album to see its songs here.'), findsOneWidget);

      await tester.tap(find.text('Discovery').first);
      await tester.pumpAndSettle();

      // The grid is still there beside the album's tracks.
      expect(find.text('Moon Safari'), findsWidgets);
      expect(find.byType(TrackTile), findsWidgets);
      expect(
        tester.getRect(find.byType(TrackTile).first).left,
        greaterThan(tester.getRect(find.text('Moon Safari').first).left),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a second album replaces the pane without a trip back',
        (tester) async {
      await _pumpLibrary(tester, _paneWindow);
      await _openTab(tester, 'Albums');

      await tester.tap(find.text('Discovery').first);
      await tester.pumpAndSettle();
      expect(find.text('Song 0'), findsOneWidget);

      await tester.tap(find.text('Moon Safari').first);
      await tester.pumpAndSettle();
      expect(find.text('Song 1'), findsOneWidget);
      expect(find.text('Song 0'), findsNothing);
    });

    testWidgets('artists get the same pane', (tester) async {
      await _pumpLibrary(tester, _paneWindow);
      await _openTab(tester, 'Artists');

      expect(
        find.text('Pick an artist to see their albums here.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Daft Punk').first);
      await tester.pumpAndSettle();

      expect(find.text('Air'), findsWidgets);
      expect(find.byType(TrackTile), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a narrow window pushes the detail as a page', (tester) async {
      await _pumpLibrary(tester, _narrowWindow);
      await _openTab(tester, 'Albums');

      await tester.tap(find.text('Discovery').first);
      await tester.pumpAndSettle();

      // The grid is gone: this is the pushed route, not a pane.
      expect(find.text('Moon Safari'), findsNothing);
      expect(find.byType(TrackTile), findsWidgets);
    });

    testWidgets('narrowing hides the pane and keeps the selection',
        (tester) async {
      await _pumpLibrary(tester, _paneWindow);
      await _openTab(tester, 'Albums');
      await tester.tap(find.text('Discovery').first);
      await tester.pumpAndSettle();
      expect(find.text('Song 0'), findsOneWidget);

      tester.view.physicalSize = _narrowWindow;
      await tester.pumpAndSettle();

      // Just the grid, at its narrow-window layout — and still on the Albums
      // tab, not thrown back anywhere.
      expect(find.text('Song 0'), findsNothing);
      expect(find.text('Discovery'), findsWidgets);
      expect(tester.takeException(), isNull);

      tester.view.physicalSize = _paneWindow;
      await tester.pumpAndSettle();
      expect(find.text('Song 0'), findsOneWidget);
    });

    testWidgets('a search that hides the album clears the pane with it',
        (tester) async {
      await _pumpLibrary(tester, _paneWindow);
      await _openTab(tester, 'Albums');
      await tester.tap(find.text('Discovery').first);
      await tester.pumpAndSettle();
      expect(find.text('Song 0'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Moon');
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // The pane cannot keep showing an album the grid beside it says is not
      // there.
      expect(find.text('Song 0'), findsNothing);
      expect(find.text('Pick an album to see its songs here.'), findsOneWidget);
    });
  });

  /// Dropping the pane unmounts the detail screen inside it, so anything that
  /// screen held itself would go with it. A track selection has to outlive the
  /// pane: narrowing the window is not something the user does to leave a
  /// selection, and they cannot even see it happen while the pane is gone.
  group('a selection in the pane', () {
    Future<void> ctrlClick(WidgetTester tester, String title) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }

    Future<void> resizeTo(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
    }

    testWidgets('survives the window narrowing past the pane and back',
        (tester) async {
      await _pumpLibrary(tester, _paneWindow);
      await _openTab(tester, 'Albums');
      await tester.tap(find.text('Discovery').first);
      await tester.pumpAndSettle();

      await ctrlClick(tester, 'Song 0');
      expect(find.text('1 selected'), findsOneWidget);

      await resizeTo(tester, _narrowWindow);
      await resizeTo(tester, _paneWindow);

      expect(find.text('1 selected'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('does not follow the pane onto another album', (tester) async {
      await _pumpLibrary(tester, _paneWindow);
      await _openTab(tester, 'Albums');
      await tester.tap(find.text('Discovery').first);
      await tester.pumpAndSettle();

      await ctrlClick(tester, 'Song 0');
      expect(find.text('1 selected'), findsOneWidget);

      // A selection only means anything against the list it was made in.
      await tester.tap(find.text('Moon Safari').first);
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsNothing);
      expect(find.text('Song 1'), findsOneWidget);
    });

    testWidgets('is ended by an action that finishes after the pane is gone',
        (tester) async {
      await _pumpLibrary(tester, _paneWindow);
      await _openTab(tester, 'Albums');
      await tester.tap(find.text('Discovery').first);
      await tester.pumpAndSettle();

      await ctrlClick(tester, 'Song 0');
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(find.byTooltip('Add to playlist'));
      await tester.pumpAndSettle();
      expect(find.text('Add to playlist'), findsWidgets);

      // The window narrows while the sheet is up: the detail screen goes, the
      // sheet stays, and the selection it is acting on is the host's now.
      await resizeTo(tester, _narrowWindow);
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();

      // Widening must not bring back a selection whose work is done.
      await resizeTo(tester, _paneWindow);
      expect(find.text('1 selected'), findsNothing);
      expect(find.text('Song 0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('artists keep their own, separate from the albums pane',
        (tester) async {
      await _pumpLibrary(tester, _paneWindow);
      await _openTab(tester, 'Artists');
      await tester.tap(find.text('Daft Punk').first);
      await tester.pumpAndSettle();

      await ctrlClick(tester, 'Song 0');
      expect(find.text('1 selected'), findsOneWidget);

      await resizeTo(tester, _narrowWindow);
      await resizeTo(tester, _paneWindow);
      expect(find.text('1 selected'), findsOneWidget);

      // The albums pane was never told about any of it.
      await _openTab(tester, 'Albums');
      await tester.tap(find.text('Discovery').first);
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsNothing);
    });
  });
}
