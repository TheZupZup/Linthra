import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/shell/home_shell.dart';

import '../library/fake_music_library_repository.dart';
import '../library/fake_remote_track_downloader.dart';
import '../player/fake_playback_controller.dart';

/// Android's Back inside the frame, where the app's routes really live: every
/// tab has a navigator of its own under the root one, so the first page of a
/// tab is not the page the router pops.

const List<Track> _tracks = <Track>[
  Track(id: 'a', title: 'Song A', uri: 'file:///a.mp3'),
  Track(id: 'b', title: 'Song B', uri: 'file:///b.mp3'),
];

/// The app's frame with the real Library as the first tab, the way
/// `appRouterProvider` builds it, and every platform call recorded so a test
/// can tell whether Back closed the app.
Future<List<String>> _pumpShell(WidgetTester tester) async {
  final List<String> platformCalls = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (MethodCall call) async {
      platformCalls.add(call.method);
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final List<GlobalKey<NavigatorState>> branchKeys =
      <GlobalKey<NavigatorState>>[
    for (int i = 0; i < 5; i++) GlobalKey<NavigatorState>(),
  ];
  final GoRouter router = GoRouter(
    navigatorKey: rootKey,
    initialLocation: '/library',
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        builder: (_, __, StatefulNavigationShell shell) => HomeShell(
          navigationShell: shell,
          rootNavigatorKey: rootKey,
          branchNavigatorKeys: branchKeys,
        ),
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            navigatorKey: branchKeys[0],
            routes: <RouteBase>[
              GoRoute(
                path: '/library',
                builder: (_, __) => const LibraryScreen(),
              ),
            ],
          ),
          for (int i = 1; i < 5; i++)
            StatefulShellBranch(
              navigatorKey: branchKeys[i],
              routes: <RouteBase>[
                GoRoute(
                  path: '/tab$i',
                  builder: (_, __) => Scaffold(body: Text('Tab $i')),
                ),
              ],
            ),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider.overrideWithValue(
          FakeMusicLibraryRepository(tracks: _tracks),
        ),
        remoteTrackDownloaderProvider
            .overrideWithValue(FakeRemoteTrackDownloader()),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return platformCalls;
}

void main() {
  // Selection is a mode the Library page holds Back for: Back ends it, the
  // way it does on the album and playlist pages. The Library is the first
  // page of its tab, though, and the router only ever pops the root
  // navigator, so the page was never asked and Back closed the app instead.
  testWidgets(
      'Back in the Library selection ends it instead of closing the app',
      (WidgetTester tester) async {
    final List<String> platformCalls = await _pumpShell(tester);
    await tester.longPress(find.text('Song A'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(platformCalls, isNot(contains('SystemNavigator.pop')));
    expect(find.text('1 selected'), findsNothing);
    expect(find.text('Song A'), findsOneWidget);

    // With nothing left to end, Back from the Library leaves the app as
    // before.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(platformCalls, contains('SystemNavigator.pop'));
  });
}
