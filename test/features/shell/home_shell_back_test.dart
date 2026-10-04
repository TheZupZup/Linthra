import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/core/models/music_folder.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/folder_browsable_music_source.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/folder_browser_providers.dart';
import 'package:linthra/features/library/folders_screen.dart';
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

  // Android 16 changed how Back reaches an app that targets API 36, which this
  // one does (flutter.targetSdkVersion): unless the app opts out of
  // predictive back, Back no longer arrives as a pop of the route, the path
  // every Back handler of the frame was written for.
  group('Back on Android 16', () {
    testWidgets('in a folder walks up a level instead of leaving the app',
        (WidgetTester tester) async {
      final _AndroidBack back = _AndroidBack(tester);
      await _pumpTabs(tester);
      await tester.tap(_destination('Folders'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rock'));
      await tester.pumpAndSettle();
      expect(find.text('Opener'), findsOneWidget);

      expect(await back.swipe(), isTrue,
          reason: 'Android kept the Back and left the app: the framework had '
              'told it the app did not want Back in a folder');
      expect(find.text('Opener'), findsNothing);
      expect(find.text('Rock'), findsOneWidget);
    });

    testWidgets(
        'on another tab goes back to Library instead of leaving the app',
        (WidgetTester tester) async {
      final _AndroidBack back = _AndroidBack(tester);
      await _pumpTabs(tester);
      await tester.tap(_destination('Downloads'));
      await tester.pumpAndSettle();
      expect(find.text('Tab 3'), findsOneWidget);

      expect(await back.swipe(), isTrue,
          reason: 'Android kept the Back and left the app: the framework had '
              'told it the app did not want Back on this tab');
      expect(find.text('Library page'), findsOneWidget);
    });

    testWidgets('a swipe on one tab leaves the pages of the other tabs alone',
        (WidgetTester tester) async {
      final _AndroidBack back = _AndroidBack(tester);
      final (GoRouter router, _) = await _pumpTabs(tester);
      router.go('/library/album');
      await tester.pumpAndSettle();
      await tester.tap(_destination('Playlists'));
      await tester.pumpAndSettle();
      router.go('/playlists/detail');
      await tester.pumpAndSettle();
      expect(find.text('Playlist page'), findsOneWidget);

      expect(await back.swipe(), isTrue);
      expect(find.text('Playlist page'), findsNothing);
      expect(find.text('Playlists page'), findsOneWidget);

      await tester.tap(_destination('Library'));
      await tester.pumpAndSettle();
      expect(find.text('Album page'), findsOneWidget,
          reason: 'the swipe also closed the album left open on the Library '
              'tab, a page that was not even on screen');
    });

    testWidgets('a swipe with a dialog open closes the dialog, not the page',
        (WidgetTester tester) async {
      final _AndroidBack back = _AndroidBack(tester);
      final (GoRouter router, GlobalKey<NavigatorState> rootKey) =
          await _pumpTabs(tester);
      await tester.tap(_destination('Playlists'));
      await tester.pumpAndSettle();
      router.go('/playlists/detail');
      await tester.pumpAndSettle();
      unawaited(showDialog<void>(
        context: rootKey.currentContext!,
        builder: (_) => const AlertDialog(content: Text('Delete playlist?')),
      ));
      await tester.pumpAndSettle();

      expect(await back.swipe(), isTrue);
      expect(find.text('Delete playlist?'), findsNothing,
          reason: 'the dialog the swipe was made over stayed open');
      expect(find.text('Playlist page'), findsOneWidget,
          reason: 'the page under the dialog was closed instead');
    });
  });
}

/// A server folder holding another one, so the Folders tab has a trail.
class _FolderSource implements FolderBrowsableMusicSource {
  @override
  String get id => 'subsonic';

  @override
  String get displayName => 'Navidrome';

  @override
  Future<List<MusicFolder>> fetchRootFolders() async =>
      const <MusicFolder>[MusicFolder(id: 'music', name: 'Music')];

  @override
  Future<MusicFolderListing> fetchFolder(String folderId) async =>
      folderId == 'music'
          ? const MusicFolderListing(
              folders: <MusicFolder>[MusicFolder(id: 'rock', name: 'Rock')],
            )
          : const MusicFolderListing(
              tracks: <Track>[
                Track(id: 't1', title: 'Opener', uri: 'subsonic:t1'),
              ],
            );
}

/// The frame with a page to open inside the Library and Playlists tabs, and
/// the real Folders screen as its second tab.
Future<(GoRouter, GlobalKey<NavigatorState>)> _pumpTabs(
  WidgetTester tester,
) async {
  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final List<GlobalKey<NavigatorState>> branchKeys =
      <GlobalKey<NavigatorState>>[
    for (int i = 0; i < 5; i++) GlobalKey<NavigatorState>(),
  ];
  GoRoute page(String path, String text, [List<RouteBase>? routes]) => GoRoute(
        path: path,
        builder: (_, __) => Scaffold(body: Text(text)),
        routes: routes ?? const <RouteBase>[],
      );
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
              page('/library', 'Library page', <RouteBase>[
                page('album', 'Album page'),
              ]),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: branchKeys[1],
            routes: <RouteBase>[
              GoRoute(
                path: '/folders',
                builder: (_, __) => const FoldersScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: branchKeys[2],
            routes: <RouteBase>[
              page('/playlists', 'Playlists page', <RouteBase>[
                page('detail', 'Playlist page'),
              ]),
            ],
          ),
          for (int i = 3; i < 5; i++)
            StatefulShellBranch(
              navigatorKey: branchKeys[i],
              routes: <RouteBase>[page('/tab$i', 'Tab $i')],
            ),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        folderBrowsableSourcesProvider
            .overrideWithValue(<FolderBrowsableMusicSource>[_FolderSource()]),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (router, rootKey);
}

/// The bottom bar's destination labelled [label].
Finder _destination(String label) => find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    );

/// Back as Android 16 hands it to an app targeting API 36.
///
/// An app that opts out of predictive back
/// (`android:enableOnBackInvokedCallback="false"` in its manifest) gets the
/// old `Activity.onBackPressed`, which `FlutterActivity` forwards to the
/// framework as a pop of the route.
///
/// Otherwise `onBackPressed` is never called. `FlutterActivity` registers its
/// `OnBackAnimationCallback` only while the framework last told it that it
/// handles Back (`SystemNavigator.setFrameworkHandlesBack(true)`), and never
/// at launch; Back then arrives as a back gesture (start, progress, commit).
/// While the framework said it does not, Android keeps the Back and leaves
/// the app.
class _AndroidBack {
  _AndroidBack(this.tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
          _frameworkHandlesBack = call.arguments as bool;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    // The framework tells Android about Back only while the app is running.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }

  final WidgetTester tester;
  bool _frameworkHandlesBack = false;

  static final bool _optsOut = File('android/app/src/main/AndroidManifest.xml')
      .readAsStringSync()
      .contains('android:enableOnBackInvokedCallback="false"');

  /// A swipe from the left edge of the screen. Whether the app got it, rather
  /// than Android leaving the app with it.
  Future<bool> swipe() async {
    if (_optsOut) {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      return true;
    }
    if (!_frameworkHandlesBack) return false;
    await _send('startBackGesture', <String, Object?>{
      'touchOffset': <double>[2, 400],
      'progress': 0.0,
      'swipeEdge': 0,
    });
    await tester.pump();
    await _send('updateBackGestureProgress', <String, Object?>{
      'touchOffset': <double>[120, 400],
      'progress': 0.5,
      'swipeEdge': 0,
    });
    await tester.pump();
    await _send('commitBackGesture');
    await tester.pumpAndSettle();
    return true;
  }

  Future<void> _send(String method, [Map<String, Object?>? arguments]) {
    return tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.backGesture.name,
      const StandardMethodCodec()
          .encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
  }
}
