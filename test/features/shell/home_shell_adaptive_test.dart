import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/player/mini_player.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/shell/home_shell.dart';
import 'package:linthra/l10n/app_localizations.dart';

import '../player/fake_playback_controller.dart';

class _BranchScreen extends StatelessWidget {
  const _BranchScreen(this.label, this.path);

  final String label;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('$label screen'),
            TextButton(
              onPressed: () => context.push('$path/detail'),
              child: Text('Open $label detail'),
            ),
          ],
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
                  builder: (_, __) => _BranchScreen(labels[i], paths[i]),
                  routes: <RouteBase>[
                    GoRoute(
                      path: 'detail',
                      builder: (_, __) => Scaffold(
                        body: Center(child: Text('${labels[i]} detail')),
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

Future<void> _pumpShell(
  WidgetTester tester, {
  required TargetPlatform platform,
  required Size size,
  Locale locale = const Locale('en'),
  PlaybackState playback = PlaybackState.idle,
}) async {
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
        playbackControllerProvider.overrideWithValue(
          FakePlaybackController(initial: playback),
        ),
      ],
      child: MaterialApp.router(
        theme: ThemeData(platform: platform),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: _router(rootKey, branchKeys),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'wide Linux window uses persistent desktop navigation',
    (WidgetTester tester) async {
      await _pumpShell(
        tester,
        platform: TargetPlatform.linux,
        size: const Size(1280, 720),
      );

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Library screen'), findsOneWidget);

      await tester.tap(find.text('Playlists'));
      await tester.pumpAndSettle();

      expect(find.text('Playlists screen'), findsOneWidget);
      expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        2,
      );
    },
  );

  testWidgets(
    'Linux resize keeps the active route while changing shell layout',
    (WidgetTester tester) async {
      await _pumpShell(
        tester,
        platform: TargetPlatform.linux,
        size: const Size(1280, 720),
      );

      await tester.tap(find.text('Playlists'));
      await tester.pumpAndSettle();
      expect(find.text('Playlists screen'), findsOneWidget);

      tester.view.physicalSize = const Size(700, 720);
      await tester.pumpAndSettle();

      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('Playlists screen'), findsOneWidget);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        2,
      );

      tester.view.physicalSize = const Size(1280, 720);
      await tester.pumpAndSettle();

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.text('Playlists screen'), findsOneWidget);
      expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        2,
      );
    },
  );

  testWidgets(
    'resize preserves the inactive branch stack, not only its selected index',
    (WidgetTester tester) async {
      await _pumpShell(
        tester,
        platform: TargetPlatform.linux,
        size: const Size(1280, 720),
      );

      await tester.tap(find.text('Playlists'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open Playlists detail'));
      await tester.pumpAndSettle();
      expect(find.text('Playlists detail'), findsOneWidget);

      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      expect(find.text('Library screen'), findsOneWidget);

      tester.view.physicalSize = const Size(700, 720);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);

      await tester.tap(find.text('Playlists'));
      await tester.pumpAndSettle();

      // Re-entering the inactive branch after crossing the breakpoint must
      // restore its detail route, not silently reset it to the branch root.
      expect(find.text('Playlists detail'), findsOneWidget);

      tester.view.physicalSize = const Size(1280, 720);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.text('Playlists detail'), findsOneWidget);
    },
  );

  testWidgets(
    'the now-playing bar spans the window, under the desktop rail',
    (WidgetTester tester) async {
      await _pumpShell(
        tester,
        platform: TargetPlatform.linux,
        size: const Size(1280, 720),
        playback: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: Track(id: '1', title: 'Song One', uri: 'subsonic:1'),
        ),
      );

      // The bar is the frame's floor, not a footer inside the content column:
      // it starts at the window's left edge, where the rail is, and runs the
      // whole width — the shape a desktop music player has.
      expect(find.byType(NavigationRail), findsOneWidget);
      final Rect bar = tester.getRect(find.byType(MiniPlayer));
      expect(bar.left, 0);
      expect(bar.width, tester.view.physicalSize.width);
      expect(
        bar.top,
        greaterThan(tester.getRect(find.byType(NavigationRail)).top),
      );
    },
  );

  testWidgets(
    'wide Android window keeps the existing mobile navigation',
    (WidgetTester tester) async {
      await _pumpShell(
        tester,
        platform: TargetPlatform.android,
        size: const Size(1280, 720),
      );

      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('Library screen'), findsOneWidget);
    },
  );

  testWidgets('French navigation labels on Linux', (tester) async {
    await _pumpShell(
      tester,
      platform: TargetPlatform.linux,
      size: const Size(1280, 720),
      locale: const Locale('fr'),
    );

    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect((rail.destinations[0].label as Text).data, 'Bibliothèque');
    expect((rail.destinations[4].label as Text).data, 'Paramètres');
  });

  testWidgets('Brazilian Portuguese navigation labels on Android',
      (tester) async {
    await _pumpShell(
      tester,
      platform: TargetPlatform.android,
      size: const Size(390, 844),
      locale: const Locale('pt', 'BR'),
    );

    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    final destinations = bar.destinations.cast<NavigationDestination>();

    expect(destinations[0].label, 'Biblioteca');
    expect(destinations[4].label, 'Configurações');
  });
}
