import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/shell/home_shell.dart';

import '../player/fake_playback_controller.dart';

class _BranchScreen extends StatelessWidget {
  const _BranchScreen(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Center(child: Text('$label screen')));
  }
}

GoRouter _router(
  GlobalKey<NavigatorState> rootKey,
  List<GlobalKey<NavigatorState>> branchKeys,
) {
  const List<String> paths = <String>[
    '/library',
    '/playlists',
    '/downloads',
    '/settings',
  ];
  const List<String> labels = <String>[
    'Library',
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
                  builder: (_, __) => _BranchScreen(labels[i]),
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
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  debugDefaultTargetPlatformOverride = platform;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(() => debugDefaultTargetPlatformOverride = null);

  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final List<GlobalKey<NavigatorState>> branchKeys =
      <GlobalKey<NavigatorState>>[
    for (int i = 0; i < 4; i++) GlobalKey<NavigatorState>(),
  ];

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
      ],
      child: MaterialApp.router(
        theme: ThemeData(platform: platform),
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
        1,
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
        1,
      );

      tester.view.physicalSize = const Size(1280, 720);
      await tester.pumpAndSettle();

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.text('Playlists screen'), findsOneWidget);
      expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        1,
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
}
