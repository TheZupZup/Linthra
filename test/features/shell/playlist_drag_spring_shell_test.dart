import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/playlists/playlist_drag.dart';
import 'package:linthra/features/shell/home_shell.dart';
import 'package:linthra/features/shell/playlist_drag_spring.dart';

import '../player/fake_playback_controller.dart';

const Track _song = Track(id: 'a', title: 'Dragged Song', uri: 'file:///a.mp3');

/// The Library tab, with a draggable row standing in for a track list.
class _LibraryScreen extends StatelessWidget {
  const _LibraryScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 200,
          height: 80,
          child: PlaylistTrackDraggable(
            tracks: () => const <Track>[_song],
            child: const Center(child: Text('library row')),
          ),
        ),
      ),
    );
  }
}

/// A plain branch page.
class _BranchScreen extends StatelessWidget {
  const _BranchScreen(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Center(child: Text('$label screen')));
  }
}

/// Favorites: a nested page inside the Playlists branch that is *not* a drop
/// target, but does have a draggable row of its own.
class _FavoritesScreen extends StatelessWidget {
  const _FavoritesScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 200,
          height: 80,
          child: PlaylistTrackDraggable(
            tracks: () => const <Track>[_song],
            child: const Center(child: Text('favorites row')),
          ),
        ),
      ),
    );
  }
}

GoRouter _router(
  GlobalKey<NavigatorState> rootKey,
  List<GlobalKey<NavigatorState>> branchKeys,
) {
  const List<String> paths = <String>[
    '/library',
    '/folders',
    '/playlists',
    '/downloads',
    '/settings',
  ];
  const List<String> labels = <String>[
    'Library',
    'Folders',
    'Playlists',
    'Downloads',
    'Settings',
  ];

  return GoRouter(
    navigatorKey: rootKey,
    initialLocation: paths.first,
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        builder: (_, __, StatefulNavigationShell shell) => HomeShell(
          navigationShell: shell,
          rootNavigatorKey: rootKey,
          branchNavigatorKeys: branchKeys,
        ),
        branches: <StatefulShellBranch>[
          for (int i = 0; i < paths.length; i++)
            StatefulShellBranch(
              navigatorKey: branchKeys[i],
              routes: <RouteBase>[
                GoRoute(
                  path: paths[i],
                  builder: (_, __) => i == 0
                      ? const _LibraryScreen()
                      : _BranchScreen(labels[i]),
                  routes: <RouteBase>[
                    // Only the Playlists branch gets the nested pages that
                    // matter here.
                    if (i == 2)
                      GoRoute(
                        path: 'favorites',
                        builder: (_, __) => const _FavoritesScreen(),
                      ),
                  ],
                ),
              ],
            ),
        ],
      ),
    ],
  );
}

Future<void> _pumpShell(WidgetTester tester, {required Size size}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final List<GlobalKey<NavigatorState>> branchKeys =
      <GlobalKey<NavigatorState>>[
    for (int i = 0; i < 5; i++) GlobalKey<NavigatorState>(),
  ];

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
      ],
      child: MaterialApp.router(
        theme: ThemeData(platform: TargetPlatform.linux),
        routerConfig: _router(rootKey, branchKeys),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Picks the named row up and holds it over the navigation region until the
/// spring has had time to fire.
Future<TestGesture> _dragOntoNavigation(
  WidgetTester tester,
  String rowLabel,
) async {
  final TestGesture gesture =
      await tester.startGesture(tester.getCenter(find.text(rowLabel)));
  await gesture.moveBy(const Offset(-40, 0));
  await tester.pump();
  await gesture.moveTo(tester.getCenter(find.byType(PlaylistDragSpring)));
  await tester.pump();
  await tester.pump(PlaylistDragSpring.dwell);
  await tester.pumpAndSettle();
  return gesture;
}

void main() {
  group('the spring reaches the playlists from anywhere a drag can start', () {
    testWidgets('a narrow Linux window springs its bottom bar', (tester) async {
      // The drag is enabled by platform, but the rail only exists above the
      // 900 px breakpoint. Without a spring on the bottom bar, a sideways pull
      // in a narrow window picks a row up and has nowhere at all to put it.
      await _pumpShell(tester, size: const Size(700, 800));
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);

      final TestGesture gesture =
          await _dragOntoNavigation(tester, 'library row');

      expect(find.text('Playlists screen'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a wide window springs its rail', (tester) async {
      await _pumpShell(tester, size: const Size(1280, 800));
      expect(find.byType(NavigationRail), findsOneWidget);

      final TestGesture gesture =
          await _dragOntoNavigation(tester, 'library row');

      expect(find.text('Playlists screen'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

  group('the spring lands on a page that can take the drop', () {
    testWidgets('a nested page in the branch is not restored under the drag',
        (tester) async {
      // Favorites lives inside the Playlists branch and takes no drop.
      // Restoring whatever the branch had on top leaves the drag stranded.
      await _pumpShell(tester, size: const Size(1280, 800));
      await tester.tap(find.text('Playlists'));
      await tester.pumpAndSettle();
      final BuildContext context =
          tester.element(find.text('Playlists screen'));
      unawaited(GoRouter.of(context).push('/playlists/favorites'));
      await tester.pumpAndSettle();
      expect(find.text('favorites row'), findsOneWidget);

      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      final TestGesture gesture =
          await _dragOntoNavigation(tester, 'library row');

      expect(find.text('Playlists screen'), findsOneWidget);
      expect(find.text('favorites row'), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a drag starting on a nested page can still spring',
        (tester) async {
      // The Playlists branch is already selected here, so a spring gated on
      // "not already on this tab" never fires and the drag is stuck on a page
      // with no drop target.
      await _pumpShell(tester, size: const Size(1280, 800));
      await tester.tap(find.text('Playlists'));
      await tester.pumpAndSettle();
      final BuildContext context =
          tester.element(find.text('Playlists screen'));
      unawaited(GoRouter.of(context).push('/playlists/favorites'));
      await tester.pumpAndSettle();

      final TestGesture gesture =
          await _dragOntoNavigation(tester, 'favorites row');

      expect(find.text('Playlists screen'), findsOneWidget);
      expect(find.text('favorites row'), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

  group('the drag stays visible across the tab it just opened', () {
    testWidgets('the feedback card survives the branch switch', (tester) async {
      // The draggable's default overlay belongs to the branch it started in.
      // Once the spring switches branches that branch goes offstage, taking
      // the feedback with it, and the pointer carries an invisible drag.
      await _pumpShell(tester, size: const Size(1280, 800));

      final TestGesture gesture =
          await _dragOntoNavigation(tester, 'library row');

      // The source row is offstage now (its branch is), so the only onstage
      // copy of this title is the feedback card following the pointer.
      expect(find.text('library row'), findsNothing);
      expect(find.text(_song.title), findsOneWidget);

      await gesture.up();
      await tester.pumpAndSettle();
    });
  });
}
