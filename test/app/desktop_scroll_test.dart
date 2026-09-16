import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/catalog/library_grouping.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/library/album_detail_screen.dart';
import 'package:linthra/features/library/artist_detail_screen.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';
import 'package:linthra/features/player/widgets/playback_progress_bar.dart';
import 'package:linthra/features/player/widgets/queue_sheet.dart';
import 'package:linthra/features/player/widgets/wavy_seek_bar.dart';
import 'package:linthra/features/playlists/playlists_screen.dart';
import 'package:linthra/features/settings/settings_screen.dart';
import 'package:linthra/shared/scroll/app_scroll_behavior.dart';
import 'package:linthra/shared/scroll/pointer_scroll_policy.dart';

import '../features/library/fake_music_library_repository.dart';
import '../features/player/fake_playback_controller.dart';

/// The desktop scrolling audit (#396).
///
/// Every surface a listener spends real time in is pumped at a desktop window
/// size and given one mouse-wheel notch, and the assertion is always the same
/// shape: the surface under the pointer moved by exactly one notch, and
/// nothing else on screen moved at all. The second half is the interesting
/// one — a wheel that scrolls a list *and* the page behind it, or a detail
/// pane *and* the grid beside it, is what makes an app feel like a phone
/// stretched across a monitor.
///
/// Nothing here is gated on Linux. These pump a desktop-sized window and drive
/// it with a mouse, which is what a desktop is; the last group pumps the same
/// screens as Android with a finger and pins that none of it changed.

/// A window wide enough for the desktop compositions (rail, panes, grids) and
/// short enough that every list on it has somewhere to scroll.
const Size _desktopWindow = Size(1400, 800);

/// A library fixture. The counts are per case: a grid needs many albums to
/// have a second row, and an album page needs one album with many tracks.
List<Track> _library({
  int count = 120,
  int albums = 40,
  int artists = 40,
}) {
  return <Track>[
    for (int i = 0; i < count; i++)
      Track(
        id: '$i',
        title: 'Song number $i',
        uri: 'jellyfin:$i',
        artistName: 'Artist ${i % artists}',
        albumName: 'Album ${i % albums}',
        trackNumber: i + 1,
        duration: const Duration(minutes: 3, seconds: 20),
      ),
  ];
}

void _sizeWindow(WidgetTester tester, {Size size = _desktopWindow}) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

/// Every vertical scroll surface currently on screen.
List<ScrollPosition> _verticalPositions(WidgetTester tester) {
  return tester
      .stateList<ScrollableState>(find.byType(Scrollable))
      .where((ScrollableState state) => state.widget.axis == Axis.vertical)
      .map((ScrollableState state) => state.position)
      .toList();
}

/// One wheel notch over [target], and how far each vertical surface moved.
Future<List<double>> _wheelOver(
  WidgetTester tester,
  Finder target, {
  double delta = wheelNotchExtent,
}) async {
  final List<ScrollPosition> positions = _verticalPositions(tester);
  final List<double> before =
      positions.map((ScrollPosition p) => p.pixels).toList();

  final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
  pointer.hover(tester.getCenter(target.first));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, delta)));
  await tester.pump();

  return <double>[
    for (int i = 0; i < positions.length; i++) positions[i].pixels - before[i],
  ];
}

/// Asserts that one surface took the notch, and that it took all of it.
void _expectOneSurfaceTookTheNotch(List<double> moved, String what) {
  expect(
    moved.where((double delta) => delta != 0.0),
    <double>[wheelNotchExtent],
    reason: '$what should move exactly one surface by exactly one notch; '
        'the surfaces on screen moved $moved',
  );
}

List<Override> _overrides({
  List<Track>? tracks,
  InMemoryPlaylistStore? playlists,
  FakePlaybackController? controller,
}) {
  return <Override>[
    musicLibraryRepositoryProvider.overrideWithValue(
      FakeMusicLibraryRepository(tracks: tracks ?? _library()),
    ),
    playlistStoreProvider.overrideWithValue(
      playlists ?? InMemoryPlaylistStore(),
    ),
    playbackControllerProvider.overrideWithValue(
      controller ??
          FakePlaybackController(
            initial: PlaybackState(
              status: PlaybackStatus.playing,
              currentTrack: _library().first,
              upNext: _library().sublist(1),
              position: const Duration(seconds: 30),
              duration: const Duration(minutes: 3, seconds: 20),
            ),
          ),
    ),
  ];
}

Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  List<Override> overrides = const <Override>[],
  TargetPlatform? platform,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides.isEmpty ? _overrides() : overrides,
      child: MaterialApp(
        theme: platform == null ? null : ThemeData(platform: platform),
        scrollBehavior: const AppScrollBehavior(),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

GoRouter _router(String location) {
  return GoRouter(
    initialLocation: location,
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
    ],
  );
}

Future<void> _pumpRoute(
  WidgetTester tester,
  String location, {
  List<Track>? tracks,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(tracks: tracks),
      child: MaterialApp.router(
        scrollBehavior: const AppScrollBehavior(),
        routerConfig: _router(location),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the wheel scrolls the surface under the pointer, and only it', () {
    testWidgets('the songs list', (tester) async {
      _sizeWindow(tester);
      await _pumpRoute(tester, AppRoutes.library);
      _expectOneSurfaceTookTheNotch(
        await _wheelOver(tester, find.text('Song number 1')),
        'the songs list',
      );
    });

    testWidgets('the albums grid', (tester) async {
      _sizeWindow(tester);
      await _pumpRoute(tester, AppRoutes.library);
      await tester.tap(find.text('Albums'));
      await tester.pumpAndSettle();
      _expectOneSurfaceTookTheNotch(
        await _wheelOver(tester, find.text('Album 1')),
        'the albums grid',
      );
    });

    testWidgets('the artists grid', (tester) async {
      _sizeWindow(tester);
      await _pumpRoute(tester, AppRoutes.library);
      await tester.tap(find.text('Artists'));
      await tester.pumpAndSettle();
      _expectOneSurfaceTookTheNotch(
        await _wheelOver(tester, find.text('Artist 1')),
        'the artists grid',
      );
    });

    testWidgets('an album track list, beside its own pane', (tester) async {
      _sizeWindow(tester);
      final List<Track> tracks = _library(count: 40, albums: 1, artists: 1);
      await _pumpRoute(
        tester,
        '/library/album/${albumIdForTrack(tracks.first)}',
        tracks: tracks,
      );
      _expectOneSurfaceTookTheNotch(
        await _wheelOver(tester, find.text('Song number 5')),
        'an album track list',
      );
    });

    testWidgets('an artist track list, beside its own pane', (tester) async {
      _sizeWindow(tester);
      final List<Track> tracks = _library(count: 40, albums: 1, artists: 1);
      await _pumpRoute(
        tester,
        '/library/artist/${artistIdForTrack(tracks.first)}',
        tracks: tracks,
      );
      _expectOneSurfaceTookTheNotch(
        await _wheelOver(tester, find.text('Song number 6')),
        'an artist track list',
      );
    });

    testWidgets('the playlists list', (tester) async {
      _sizeWindow(tester);
      final InMemoryPlaylistStore playlists = InMemoryPlaylistStore();
      await playlists.save(<Playlist>[
        for (int i = 0; i < 30; i++)
          Playlist(id: 'p$i', name: 'Playlist $i', trackIds: const <String>[]),
      ]);
      await _pump(
        tester,
        const PlaylistsScreen(),
        overrides: _overrides(playlists: playlists),
      );
      _expectOneSurfaceTookTheNotch(
        await _wheelOver(tester, find.text('Playlist 1')),
        'the playlists list',
      );
    });

    testWidgets('the settings hub', (tester) async {
      // Short on purpose: the hub is a handful of rows, and a window it fits
      // in has nothing to prove.
      _sizeWindow(tester, size: const Size(1000, 420));
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(
            scrollBehavior: const AppScrollBehavior(),
            routerConfig: GoRouter(
              initialLocation: AppRoutes.settings,
              routes: <RouteBase>[
                GoRoute(
                  path: AppRoutes.settings,
                  builder: (_, __) => const SettingsScreen(),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      _expectOneSurfaceTookTheNotch(
        await _wheelOver(tester, find.text('Connections')),
        'the settings hub',
      );
    });

    testWidgets('the queue, over the page that opened it', (tester) async {
      _sizeWindow(tester);
      await _pump(
        tester,
        Scaffold(
          body: Builder(
            builder: (BuildContext context) => ListView(
              children: <Widget>[
                TextButton(
                  onPressed: () => showQueueSheet(context),
                  child: const Text('open'),
                ),
                for (int i = 0; i < 30; i++)
                  SizedBox(height: 80, child: Text('behind $i')),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // A sheet over a page is the nesting that matters most: the page behind
      // it must not move because the pointer is on the sheet.
      _expectOneSurfaceTookTheNotch(
        await _wheelOver(tester, find.text('Song number 3')),
        'the queue sheet',
      );
    });

    testWidgets('a dialog, over the page that opened it', (tester) async {
      _sizeWindow(tester, size: const Size(900, 600));
      await _pump(
        tester,
        Scaffold(
          body: Builder(
            builder: (BuildContext context) => ListView(
              children: <Widget>[
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => AlertDialog(
                      content: SizedBox(
                        height: 200,
                        width: 300,
                        child: ListView(
                          children: <Widget>[
                            for (int i = 0; i < 30; i++)
                              SizedBox(height: 40, child: Text('option $i')),
                          ],
                        ),
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
                for (int i = 0; i < 30; i++)
                  SizedBox(height: 80, child: Text('behind $i')),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      _expectOneSurfaceTookTheNotch(
        await _wheelOver(tester, find.text('option 1')),
        'a dialog over a page',
      );
    });
  });

  group('a seek that goes away leaves the app scrolling', () {
    testWidgets('a cancelled press on the bar does not swallow the wheel',
        (tester) async {
      // Holding a slider stops the page scrolling under it, which is the
      // point; a hold that never ends would stop the *app* scrolling, which
      // is a far worse bug than the one it fixes.
      _sizeWindow(tester, size: const Size(900, 600));
      final ScrollController page = ScrollController();
      addTearDown(page.dispose);

      await _pump(
        tester,
        Scaffold(
          body: Column(
            children: <Widget>[
              SizedBox(
                width: 300,
                child: PlaybackProgressBar(
                  position: const Duration(minutes: 1),
                  duration: const Duration(minutes: 4),
                  onSeek: (_) {},
                ),
              ),
              Expanded(
                child: ListView(
                  controller: page,
                  children: <Widget>[
                    for (int i = 0; i < 30; i++)
                      SizedBox(height: 80, child: Text('row $i')),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byType(WavySeekBar)),
      );
      await tester.pumpAndSettle();
      await gesture.cancel();
      await tester.pumpAndSettle();

      await _wheelOver(tester, find.text('row 2'));
      expect(page.offset, wheelNotchExtent);
    });
  });

  group('horizontal input belongs to horizontal surfaces', () {
    testWidgets('a sideways flick over the songs list moves nothing',
        (tester) async {
      _sizeWindow(tester);
      await _pumpRoute(tester, AppRoutes.library);

      final List<ScrollPosition> positions = _verticalPositions(tester);
      final List<double> before =
          positions.map((ScrollPosition p) => p.pixels).toList();

      final TestPointer pointer = TestPointer(1, PointerDeviceKind.trackpad);
      pointer.hover(tester.getCenter(find.text('Song number 1').first));
      await tester.sendEventToBinding(
        pointer.scroll(const Offset(wheelNotchExtent, 0)),
      );
      await tester.pump();

      expect(
        positions.map((ScrollPosition p) => p.pixels).toList(),
        before,
        reason: 'a vertical list has no business reading a sideways gesture',
      );
    });
  });

  group('the keyboard scrolls the way it always did', () {
    testWidgets('Page Down moves the list the keyboard is in', (tester) async {
      _sizeWindow(tester, size: const Size(900, 600));
      final ScrollController page = ScrollController();
      addTearDown(page.dispose);

      await _pump(
        tester,
        Scaffold(
          body: ListView(
            controller: page,
            children: <Widget>[
              const Focus(
                autofocus: true,
                child: SizedBox(height: 60, child: Text('first')),
              ),
              for (int i = 0; i < 40; i++)
                SizedBox(height: 60, child: Text('row $i')),
            ],
          ),
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();

      expect(page.offset, greaterThan(0));
    });
  });

  group('a slider takes the wheel off the page', () {
    testWidgets('a notch over the seek bar seeks, and nothing scrolls',
        (tester) async {
      _sizeWindow(tester);
      final FakePlaybackController controller = FakePlaybackController(
        initial: PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _library().first,
          upNext: _library().sublist(1),
          position: const Duration(minutes: 1),
          duration: const Duration(minutes: 4),
        ),
      );
      await _pump(
        tester,
        const PlayerScreen(),
        overrides: _overrides(controller: controller),
      );

      final List<double> moved = await _wheelOver(
        tester,
        find.bySemanticsLabel('Playback position'),
        delta: -wheelNotchExtent,
      );

      expect(
        controller.seeks,
        // One notch is one arrow-key step, which is 5% of a four-minute track.
        <Duration>[const Duration(minutes: 1, seconds: 12)],
        reason: 'answering the wheel is what a desktop control does',
      );
      expect(moved.where((double delta) => delta != 0.0), isEmpty);
    });
  });

  group('touch is untouched', () {
    testWidgets('a finger still drags the songs list on Android',
        (tester) async {
      _sizeWindow(tester, size: const Size(420, 900));
      await _pump(
        tester,
        const LibraryScreen(),
        platform: TargetPlatform.android,
      );

      final ScrollPosition list = _verticalPositions(tester).first;
      await tester.drag(find.text('Song number 1'), const Offset(0, -200));
      await tester.pumpAndSettle();

      expect(list.pixels, greaterThan(0));
    });

    testWidgets('and keeps the overscroll stretch at the end of it',
        (tester) async {
      _sizeWindow(tester, size: const Size(420, 900));
      await _pump(
        tester,
        const LibraryScreen(),
        platform: TargetPlatform.android,
      );

      expect(
        find.byType(StretchingOverscrollIndicator),
        findsWidgets,
        reason: 'the phone keeps the affordance a thumb expects',
      );
    });
  });
}
