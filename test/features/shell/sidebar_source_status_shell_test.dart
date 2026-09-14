import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/sources/music_provider.dart';
import 'package:linthra/core/sources/source_availability.dart';
import 'package:linthra/features/library/source_availability_providers.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/plex/plex_settings_controller.dart';
import 'package:linthra/features/settings/plex/plex_settings_state.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_state.dart';
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

class _StubSubsonicSettings extends SubsonicSettingsController {
  _StubSubsonicSettings({required this.connected});
  final bool connected;
  @override
  SubsonicSettingsState build() => SubsonicSettingsState(
        phase: connected
            ? SubsonicConnectionPhase.connected
            : SubsonicConnectionPhase.disconnected,
      );
}

/// Plex is configured when a *session* is retained, not when the phase says
/// connected — `connectWithPlex` keeps the session while the user is away in
/// the browser. The stub mirrors that so [phase] and [session] can be moved
/// independently.
class _StubPlexSettings extends PlexSettingsController {
  _StubPlexSettings({
    required this.phase,
    required this.hasSession,
  });

  final PlexConnectionPhase phase;
  final bool hasSession;

  @override
  PlexSession? get session => hasSession
      ? const PlexSession(
          baseUrl: 'https://plex.invalid:32400',
          token: 'plex-token',
          machineIdentifier: 'machine-1',
        )
      : null;

  @override
  PlexSettingsState build() => PlexSettingsState(phase: phase);
}

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
  bool allSources = false,
  double textScale = 1.0,
  PlexConnectionPhase plexPhase = PlexConnectionPhase.connected,
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
        if (allSources) ...<Override>[
          subsonicSettingsControllerProvider
              .overrideWith(() => _StubSubsonicSettings(connected: true)),
          plexSettingsControllerProvider.overrideWith(
            () => _StubPlexSettings(
              phase: plexPhase,
              hasSession: true,
            ),
          ),
        ],
      ],
      child: MaterialApp.router(
        theme: ThemeData(platform: platform),
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  _shortWindowTests();

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

  testWidgets('a Plex reconnect does not make its row disappear and come back',
      (WidgetTester tester) async {
    // `connectWithPlex` keeps the existing session while the user is away in
    // the browser approving a new one, so the phase runs linking → loading →
    // picking while Plex is still configured and still serving music. Reading
    // the phase pulled the row out of the sidebar for that whole flow.
    for (final PlexConnectionPhase phase in <PlexConnectionPhase>[
      PlexConnectionPhase.linking,
      PlexConnectionPhase.loadingUsers,
      PlexConnectionPhase.pickingUser,
      PlexConnectionPhase.loadingServers,
      PlexConnectionPhase.pickingServer,
    ]) {
      await _pumpShell(
        tester,
        platform: TargetPlatform.linux,
        size: _wideWindow,
        jellyfin: SourceAvailability.notConfigured,
        allSources: true,
        plexPhase: phase,
      );

      expect(
        find.byTooltip('Plex connected'),
        findsOneWidget,
        reason: 'the Plex row vanished during $phase',
      );
    }
  });

  testWidgets('signing out of Plex does drop its row',
      (WidgetTester tester) async {
    // The other half: no session means not configured, whatever the phase.
    await _pumpShell(
      tester,
      platform: TargetPlatform.linux,
      size: _wideWindow,
      jellyfin: SourceAvailability.notConfigured,
      plexPhase: PlexConnectionPhase.disconnected,
    );

    expect(find.byTooltip('Plex connected'), findsNothing);
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

/// A Linux window at the documented 600 px minimum height. The rail has to fit
/// five labelled destinations *and* the status strip into what the mini-player
/// leaves behind, which is where a fixed, non-scrollable column runs out of
/// room (#647 review).
const Size _shortWindow = Size(1600, 600);

void _shortWindowTests() {
  testWidgets('the rail survives the shortest supported window',
      (WidgetTester tester) async {
    await _pumpShell(
      tester,
      platform: TargetPlatform.linux,
      size: _shortWindow,
      jellyfin: SourceAvailability.unreachable,
      allSources: true,
    );

    expect(
      tester.takeException(),
      isNull,
      reason: 'the rail overflowed instead of scrolling',
    );
    expect(find.byType(SidebarSourceStatusTile), findsNWidgets(3));
  });

  testWidgets('and survives it at a doubled text scale',
      (WidgetTester tester) async {
    await _pumpShell(
      tester,
      platform: TargetPlatform.linux,
      size: _shortWindow,
      jellyfin: SourceAvailability.unreachable,
      allSources: true,
      textScale: 2.0,
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('every source stays reachable in the shortest window',
      (WidgetTester tester) async {
    await _pumpShell(
      tester,
      platform: TargetPlatform.linux,
      size: _shortWindow,
      jellyfin: SourceAvailability.unreachable,
      allSources: true,
      textScale: 2.0,
    );

    // The regression: the third tile used to be laid out from 553 to 617 in a
    // rail that ended at 600, painted past the edge with no overflow error to
    // give it away. Scrolling to it must now actually bring it into the rail.
    final Finder last = find.byType(SidebarSourceStatusTile).last;
    await tester.ensureVisible(last);
    await tester.pumpAndSettle();

    final Rect rail = tester.getRect(find.byType(NavigationRail));
    final Rect tile = tester.getRect(last);
    expect(
      tile.bottom,
      lessThanOrEqualTo(rail.bottom),
      reason: 'the last source is stranded outside the rail',
    );
    expect(tile.top, greaterThanOrEqualTo(rail.top));
  });

  testWidgets('a source row is a full-width, 48 px target',
      (WidgetTester tester) async {
    await _pumpShell(
      tester,
      platform: TargetPlatform.linux,
      size: _wideWindow,
      jellyfin: SourceAvailability.available,
      allSources: true,
    );

    final List<Rect> tiles = <Rect>[
      for (final Element e in find.byType(SidebarSourceStatusTile).evaluate())
        tester.getRect(find.byElementPredicate((c) => identical(c, e))),
    ];
    expect(tiles, hasLength(3));

    for (final Rect tile in tiles) {
      expect(
        tile.height,
        greaterThanOrEqualTo(48.0),
        reason: 'below the minimum interactive target',
      );
      // 80 px is what Material 3 gives a rail destination, so a short name
      // like "Plex" is a target the same size as the destinations above it
      // rather than a sliver in an otherwise inert rail row.
      expect(
        tile.width,
        greaterThanOrEqualTo(80.0),
        reason: 'narrower than a rail destination',
      );
    }
  });
}
