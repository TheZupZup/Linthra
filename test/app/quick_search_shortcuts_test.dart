import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/router.dart';
import 'package:linthra/app/shortcuts/linthra_shortcuts.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/shell/home_shell.dart';

import '../features/library/fake_music_library_repository.dart';
import '../features/player/fake_playback_controller.dart';

/// Quick search's own bindings, kept passing across the move to the
/// configurable registry (#391). Ctrl+K and Ctrl+F must still reach the overlay
/// from anywhere, including from inside a text field — that is where people
/// press them.
///
/// A branch screen with a text field, so the shortcut is exercised in the state
/// it actually has to survive: a user who is already typing somewhere.
class _BranchScreen extends StatelessWidget {
  const _BranchScreen(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('$label screen'),
            const SizedBox(
              width: 200,
              child: TextField(key: Key('branch_field')),
            ),
            TextButton(
              onPressed: () => context.push('/player'),
              child: const Text('open player'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Stands in for the real Now Playing screen: a top-level route pushed *over*
/// the navigation shell, which is the case a binding inside the shell misses.
class _PlayerScreen extends StatelessWidget {
  const _PlayerScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: Text('player screen')));
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
                  builder: (_, __) => _BranchScreen(labels[i]),
                ),
              ],
            ),
        ],
      ),
      // Outside the shell, exactly like the real player route.
      GoRoute(
        path: '/player',
        builder: (_, __) => const _PlayerScreen(),
      ),
    ],
  );
}

Future<void> _pumpApp(WidgetTester tester) async {
  final List<GlobalKey<NavigatorState>> branchKeys =
      <GlobalKey<NavigatorState>>[
    for (int i = 0; i < 5; i++) GlobalKey<NavigatorState>(),
  ];

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository()),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
      ],
      // Mirrors how LinthraApp mounts the binding: the same root navigator key
      // the router is built on, wrapped around the router's output by
      // MaterialApp.router's builder. Anything lower in the tree would miss the
      // routes pushed over the shell.
      child: Consumer(
        builder: (BuildContext context, WidgetRef ref, _) {
          final GlobalKey<NavigatorState> rootKey =
              ref.watch(rootNavigatorKeyProvider);
          return MaterialApp.router(
            routerConfig: _router(rootKey, branchKeys),
            builder: (BuildContext context, Widget? child) => LinthraShortcuts(
              navigatorKey: rootKey,
              child: child ?? const SizedBox.shrink(),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pressChord(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

Finder get _overlayField => find.byKey(const Key('quick_search_field'));

void main() {
  group('Quick search shortcuts', () {
    testWidgets('Ctrl+K opens the overlay from inside the shell',
        (tester) async {
      await _pumpApp(tester);

      expect(_overlayField, findsNothing);

      await _pressChord(tester, LogicalKeyboardKey.keyK);

      expect(_overlayField, findsOneWidget);
      // The tab underneath keeps its place: nothing navigated.
      expect(find.text('Library screen'), findsOneWidget);
    });

    testWidgets('Ctrl+F opens it too', (tester) async {
      await _pumpApp(tester);

      await _pressChord(tester, LogicalKeyboardKey.keyF);

      expect(_overlayField, findsOneWidget);
    });

    testWidgets('the shortcut works from any tab, not just Library',
        (tester) async {
      await _pumpApp(tester);

      await tester.tap(find.text('Playlists'));
      await tester.pumpAndSettle();
      expect(find.text('Playlists screen'), findsOneWidget);

      await _pressChord(tester, LogicalKeyboardKey.keyK);

      expect(_overlayField, findsOneWidget);
      expect(find.text('Playlists screen'), findsOneWidget);
    });

    testWidgets('it opens even while a field on the page has focus',
        (tester) async {
      await _pumpApp(tester);

      await tester.tap(find.byKey(const Key('branch_field')));
      await tester.pumpAndSettle();

      await _pressChord(tester, LogicalKeyboardKey.keyK);

      expect(_overlayField, findsOneWidget);
    });

    testWidgets('it reaches routes pushed over the shell, like Now Playing',
        (tester) async {
      await _pumpApp(tester);

      await tester.tap(find.text('open player'));
      await tester.pumpAndSettle();
      expect(find.text('player screen'), findsOneWidget);

      await _pressChord(tester, LogicalKeyboardKey.keyK);

      expect(
        _overlayField,
        findsOneWidget,
        reason: 'the binding sits above the router, so the full-screen player '
            'route is still a descendant of it',
      );
      expect(find.text('player screen'), findsOneWidget);
    });

    testWidgets('pressing it again while open does not stack a second overlay',
        (tester) async {
      await _pumpApp(tester);

      await _pressChord(tester, LogicalKeyboardKey.keyK);
      await _pressChord(tester, LogicalKeyboardKey.keyK);

      expect(_overlayField, findsOneWidget);

      // One Escape is enough to get back to the app.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(_overlayField, findsNothing);
      expect(find.text('Library screen'), findsOneWidget);
    });
  });
}
