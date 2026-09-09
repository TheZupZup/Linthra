import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/favorites_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/library/album_detail_screen.dart';
import 'package:linthra/features/library/artist_detail_screen.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/library/widgets/track_tile.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';
import 'package:linthra/shared/widgets/context_menu_region.dart';

import '../player/fake_playback_controller.dart';
import 'fake_music_library_repository.dart';

/// Right-click menus (#386). Same entries as the row's 3-dot button, same
/// commands behind them, and a keyboard way in — a menu a mouse can reach and a
/// keyboard cannot is not an accessible menu.
final List<Track> _tracks = <Track>[
  for (int i = 0; i < 3; i++)
    Track(
      id: '$i',
      title: 'Song $i',
      uri: 'jellyfin:$i',
      artistName: 'Daft Punk',
      albumName: 'Discovery',
      trackNumber: i + 1,
    ),
];

/// A local track with no album or artist tags: nowhere to navigate to.
const Track _untagged = Track(id: '9', title: 'Untitled', uri: '/music/9.mp3');

Future<void> _pumpLibrary(WidgetTester tester, {List<Track>? tracks}) async {
  tester.view.devicePixelRatio = 1.0;
  // Narrow enough that the Albums grid has no detail pane, so the songs list is
  // the only thing on screen.
  tester.view.physicalSize = const Size(800, 900);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider.overrideWithValue(
          FakeMusicLibraryRepository(tracks: tracks ?? _tracks),
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

/// Right-clicks the first track row.
Future<void> _rightClickFirstTrack(WidgetTester tester) async {
  final Offset where = tester.getCenter(find.byType(TrackTile).first);
  final TestGesture gesture = await tester.startGesture(
    where,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(LibraryScreen)));

void main() {
  group('track row context menu', () {
    testWidgets('right-click opens the row actions', (tester) async {
      await _pumpLibrary(tester);
      await _rightClickFirstTrack(tester);

      expect(find.text('Play next'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget);
      expect(find.text('Add to playlist'), findsOneWidget);
      expect(find.text('Add to favorites'), findsOneWidget);
      expect(find.text('Show album'), findsOneWidget);
      expect(find.text('Show artist'), findsOneWidget);
      expect(find.text('Remove from Linthra'), findsOneWidget);
    });

    testWidgets('an action runs the same command the button would',
        (tester) async {
      await _pumpLibrary(tester);
      await _rightClickFirstTrack(tester);

      await tester.tap(find.text('Add to queue'));
      await tester.pumpAndSettle();

      // Nothing was playing, so the shared command starts the queued track
      // rather than leaving it queued behind silence — exactly what the 3-dot
      // button does with the same action.
      final FakePlaybackController controller = _container(tester)
          .read(playbackControllerProvider) as FakePlaybackController;
      expect(controller.state.currentTrack?.title, 'Song 0');
    });

    testWidgets('the menu reflects state as it is when it opens',
        (tester) async {
      await _pumpLibrary(tester);
      await _rightClickFirstTrack(tester);

      await tester.tap(find.text('Add to favorites'));
      await tester.pumpAndSettle();
      expect(
        _container(tester).read(favoritesRepositoryProvider).isFavorite(
              'jellyfin:0',
            ),
        isTrue,
      );

      // Opened again, the same entry now offers the other half of the toggle.
      await _rightClickFirstTrack(tester);
      expect(find.text('Remove from favorites'), findsOneWidget);
      expect(find.text('Add to favorites'), findsNothing);
    });

    testWidgets('Show album opens the album page', (tester) async {
      await _pumpLibrary(tester);
      await _rightClickFirstTrack(tester);

      await tester.tap(find.text('Show album'));
      await tester.pumpAndSettle();

      expect(find.byType(AlbumDetailScreen), findsOneWidget);
      expect(find.text('Discovery'), findsWidgets);
    });

    testWidgets('a track with no tags is offered nowhere to go',
        (tester) async {
      await _pumpLibrary(tester, tracks: <Track>[_untagged]);
      await _rightClickFirstTrack(tester);

      expect(find.text('Play next'), findsOneWidget);
      expect(find.text('Show album'), findsNothing);
      expect(find.text('Show artist'), findsNothing);
    });
  });

  group('album and artist context menus', () {
    Future<void> openTab(WidgetTester tester, String tab) async {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
    }

    Future<void> rightClick(WidgetTester tester, Finder target) async {
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(target),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('an album card offers what its page already does',
        (tester) async {
      await _pumpLibrary(tester);
      await openTab(tester, 'Albums');
      await rightClick(tester, find.text('Discovery').first);

      expect(find.text('Play'), findsOneWidget);
      expect(find.text('Shuffle'), findsOneWidget);
      expect(find.text('Play next'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget);
      expect(find.text('Add to playlist'), findsOneWidget);
    });

    testWidgets('queueing an album keeps it in album order', (tester) async {
      await _pumpLibrary(tester);
      await openTab(tester, 'Albums');
      await rightClick(tester, find.text('Discovery').first);

      await tester.tap(find.text('Add to queue'));
      await tester.pumpAndSettle();

      final FakePlaybackController controller = _container(tester)
          .read(playbackControllerProvider) as FakePlaybackController;
      expect(controller.state.currentTrack?.title, 'Song 0');
      expect(
        controller.state.upNext.map((Track t) => t.title).toList(),
        <String>['Song 1', 'Song 2'],
      );
    });

    testWidgets('Play next queues an album front to back', (tester) async {
      await _pumpLibrary(tester);
      await openTab(tester, 'Albums');

      // Something has to be playing for "next" to have a "current" to sit
      // after — the case where the insert order actually matters.
      final FakePlaybackController controller = _container(tester)
          .read(playbackControllerProvider) as FakePlaybackController;
      await controller.playTracks(<Track>[_tracks.first]);
      await tester.pumpAndSettle();

      await rightClick(tester, find.text('Discovery').first);
      await tester.tap(find.text('Play next'));
      await tester.pumpAndSettle();

      // Each insert lands right after the current track, so the album would
      // play backwards if the menu did not reverse them.
      expect(
        controller.state.upNext.map((Track t) => t.title).toList(),
        <String>['Song 0', 'Song 1', 'Song 2'],
      );
    });

    testWidgets('Play next from silence just starts the album', (tester) async {
      await _pumpLibrary(tester);
      await openTab(tester, 'Albums');
      await rightClick(tester, find.text('Discovery').first);

      await tester.tap(find.text('Play next'));
      await tester.pumpAndSettle();

      // There is no "next" to insert before, so the album plays from the top
      // rather than backwards from its last track.
      final FakePlaybackController controller = _container(tester)
          .read(playbackControllerProvider) as FakePlaybackController;
      expect(controller.state.currentTrack?.title, 'Song 0');
      expect(
        controller.state.upNext.map((Track t) => t.title).toList(),
        <String>['Song 1', 'Song 2'],
      );
    });

    testWidgets('an artist row offers the same set', (tester) async {
      await _pumpLibrary(tester);
      await openTab(tester, 'Artists');
      await rightClick(tester, find.text('Daft Punk').first);

      expect(find.text('Play'), findsOneWidget);
      expect(find.text('Add to playlist'), findsOneWidget);
    });
  });

  group('ContextMenuRegion keyboard access', () {
    Future<void> pumpRegion(
      WidgetTester tester, {
      bool enabled = true,
      required List<String> opened,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ContextMenuRegion<String>(
                enabled: enabled,
                itemBuilder: (BuildContext context) =>
                    const <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(value: 'a', child: Text('Play next')),
                ],
                onSelected: opened.add,
                child: const Focus(
                  autofocus: true,
                  child: SizedBox(width: 200, height: 60),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the menu key opens the menu on the focused row',
        (tester) async {
      final List<String> chosen = <String>[];
      await pumpRegion(tester, opened: chosen);

      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      expect(find.text('Play next'), findsOneWidget);

      await tester.tap(find.text('Play next'));
      await tester.pumpAndSettle();
      expect(chosen, <String>['a']);
    });

    testWidgets('Shift+F10 does the same, for keyboards without a menu key',
        (tester) async {
      await pumpRegion(tester, opened: <String>[]);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      expect(find.text('Play next'), findsOneWidget);
    });

    testWidgets('F10 on its own is left alone', (tester) async {
      await pumpRegion(tester, opened: <String>[]);

      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.pumpAndSettle();

      expect(find.text('Play next'), findsNothing);
    });

    testWidgets('a disabled region offers nothing', (tester) async {
      await pumpRegion(tester, enabled: false, opened: <String>[]);

      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();

      expect(find.text('Play next'), findsNothing);
    });
  });
}
