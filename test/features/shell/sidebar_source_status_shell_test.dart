import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/sources/music_provider.dart';
import 'package:linthra/core/sources/source_availability.dart';
import 'package:linthra/features/library/source_availability_providers.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/shell/home_shell.dart';
import 'package:linthra/features/shell/sidebar_source_status.dart';

import '../player/fake_playback_controller.dart';

/// The source indicators where the frame actually puts them (#425).
///
/// The strip is desktop chrome, so the rule is the one the rest of the desktop
/// work follows: the *layout* decides whether it exists. A phone never grows
/// one, a Linux window too narrow for the rail loses it with the rail, and a
/// problem row lands the user on the Connections screen that already exists
/// rather than on something new.

/// Comfortably past [HomeShell.desktopNavigationBreakpoint].
const Size _wideWindow = Size(1600, 900);

/// A Linux window below the breakpoint: bottom bar, no rail.
const Size _narrowWindow = Size(700, 900);

class _BranchScreen extends StatelessWidget {
  const _BranchScreen(this.label);
  final String label;

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text('$label screen')));
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
  final List<String> labels = HomeShell.destinationLabels;

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
                  builder: (_, __) => _BranchScreen(labels[i]),
                  routes: <RouteBase>[
                    if (paths[i] == '/settings')
                      GoRoute(
                        path: 'connections',
                        builder: (_, __) => const Scaffold(
                          body: Center(child: Text('Connections screen')),
                        ),
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

Future<GoRouter> _pumpShell(
  WidgetTester tester, {
  required TargetPlatform platform,
  required Size size,
  required SourceAvailability jellyfin,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final List<GlobalKey<NavigatorState>> branchKeys =
      <GlobalKey<NavigatorState>>[
    for (int i = 0; i < 5; i++) GlobalKey<NavigatorState>(),
  ];
  final FakePlaybackController controller =
      FakePlaybackController(initial: const PlaybackState());
  addTearDown(controller.dispose);
  final GoRouter router = _router(rootKey, branchKeys);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider.overrideWithValue(controller),
        sourceAvailabilityProvider.overrideWithValue(
          <String, SourceAvailability>{
            MusicProviders.jellyfin.sourceId: jellyfin,
          },
        ),
      ],
      child: MaterialApp.router(
        theme: ThemeData(platform: platform),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  testWidgets('a wide Linux window carries the indicators in the rail',
      (WidgetTester tester) async {
    await _pumpShell(
      tester,
      platform: TargetPlatform.linux,
      size: _wideWindow,
      jellyfin: SourceAvailability.available,
    );

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(SidebarSourceStatusTile), findsOneWidget);
    expect(find.byTooltip('Jellyfin connected'), findsOneWidget);
  });

  testWidgets('a phone never grows one', (WidgetTester tester) async {
    await _pumpShell(
      tester,
      platform: TargetPlatform.android,
      size: _wideWindow,
      jellyfin: SourceAvailability.unreachable,
    );

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(SidebarSourceStatusTile), findsNothing);
  });

  testWidgets('a Linux window too narrow for the rail loses it with the rail',
      (WidgetTester tester) async {
    await _pumpShell(
      tester,
      platform: TargetPlatform.linux,
      size: _narrowWindow,
      jellyfin: SourceAvailability.unreachable,
    );

    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(SidebarSourceStatusTile), findsNothing);
  });

  testWidgets('a problem row lands on the Connections screen that exists',
      (WidgetTester tester) async {
    final GoRouter router = await _pumpShell(
      tester,
      platform: TargetPlatform.linux,
      size: _wideWindow,
      jellyfin: SourceAvailability.authenticationError,
    );

    await tester.tap(find.byTooltip('Jellyfin sign-in needed'));
    await tester.pumpAndSettle();

    expect(find.text('Connections screen'), findsOneWidget);
    expect(
      router.routerDelegate.currentConfiguration.uri.toString(),
      '/settings/connections',
    );
    // Switched tabs rather than pushing over Library, so the rail is not
    // highlighting one place while the page shows another.
    expect(find.text('Library screen'), findsNothing);
  });
}
