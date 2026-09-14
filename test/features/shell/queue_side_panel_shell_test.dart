import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/widgets/queue_side_panel.dart';
import 'package:linthra/features/shell/home_shell.dart';
import 'package:linthra/shared/layout/pane_layout.dart';

import '../player/fake_playback_controller.dart';

/// The desktop queue column, as the frame hosts it (#416).
///
/// The rule this file pins: the *layout* decides whether the column exists.
/// Never the queue, never the platform channel, never the widget itself. A
/// window wide enough can keep the queue beside the page; a narrower one hands
/// the queue back to the sheet it has always had; Android keeps the phone
/// layout at any width. The queue's own behaviour is pinned next door, in
/// `test/features/player/queue_side_panel_test.dart`.

/// Comfortably wider than [queueSidePanelMinWindowWidth].
const Size _wideWindow = Size(1600, 900);

/// A desktop window with the rail but no room for a third column.
const Size _narrowDesktopWindow = Size(1280, 800);

const Track _current = Track(
  id: '1',
  title: 'Song One',
  uri: 'jellyfin:1',
  artistName: 'Artist A',
);

const Track _next = Track(
  id: '2',
  title: 'Song Two',
  uri: 'jellyfin:2',
  artistName: 'Artist A',
);

const PlaybackState _playing = PlaybackState(
  status: PlaybackStatus.playing,
  currentTrack: _current,
  upNext: <Track>[_next],
);

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

Future<FakePlaybackController> _pumpShell(
  WidgetTester tester, {
  required TargetPlatform platform,
  required Size size,
  PlaybackState playback = _playing,
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
      FakePlaybackController(initial: playback);
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider.overrideWithValue(controller),
      ],
      child: MaterialApp.router(
        theme: ThemeData(platform: platform),
        routerConfig: _router(rootKey, branchKeys),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _resize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  await tester.pumpAndSettle();
}

/// Whether whatever holds focus sits inside a [T].
bool _focusedInside<T extends Widget>() {
  final BuildContext? context = FocusManager.instance.primaryFocus?.context;
  return context != null && context.findAncestorWidgetOfExactType<T>() != null;
}

/// The icon button behind a tooltip. `find.byTooltip` lands on the [Tooltip]
/// the button builds, which is one step below the button itself.
IconButton _button(WidgetTester tester, String tooltip) {
  return tester.widget<IconButton>(
    find
        .ancestor(
          of: find.byTooltip(tooltip),
          matching: find.byType(IconButton),
        )
        .first,
  );
}

/// Puts the keyboard on the control behind [tooltip], the way Tab would.
void _focusButton(WidgetTester tester, String tooltip) {
  Focus.of(
    tester.element(
      find.descendant(
        of: find.byTooltip(tooltip),
        matching: find.byType(Icon),
      ),
    ),
  ).requestFocus();
}

void main() {
  testWidgets('a wide desktop window can keep the queue beside the page',
      (WidgetTester tester) async {
    await _pumpShell(
      tester,
      platform: TargetPlatform.linux,
      size: _wideWindow,
    );

    // Closed until asked for: the column costs the page real width, and that
    // is the listener's call.
    expect(find.byType(QueueSidePanel), findsNothing);

    await tester.tap(find.byTooltip('Show queue'));
    await tester.pumpAndSettle();

    expect(find.byType(QueueSidePanel), findsOneWidget);
    expect(find.text('Song One'), findsWidgets);
    expect(find.text('Song Two'), findsOneWidget);
    // Beside the page, not over it: the library is still readable next to it.
    expect(find.text('Library screen'), findsOneWidget);
    expect(
      tester.getRect(find.text('Library screen')).right,
      lessThanOrEqualTo(tester.getRect(find.byType(QueueSidePanel)).left),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the page keeps room for its own detail pane beside the column',
      (WidgetTester tester) async {
    await _pumpShell(
      tester,
      platform: TargetPlatform.linux,
      size: const Size(queueSidePanelMinWindowWidth, 900),
    );

    await tester.tap(find.byTooltip('Show queue'));
    await tester.pumpAndSettle();

    // At the narrowest window that hosts the column at all, what is left for
    // the page is still a two-pane width. A queue that costs the library its
    // detail pane has taken more than it gave.
    final double railRight = tester.getRect(find.byType(NavigationRail)).right;
    final double panelLeft = tester.getRect(find.byType(QueueSidePanel)).left;
    // Minus the two hairline dividers the shell draws around the page.
    expect(panelLeft - railRight - 2, greaterThanOrEqualTo(listDetailMinWidth));
  });

  testWidgets('either control collapses it again', (WidgetTester tester) async {
    await _pumpShell(
      tester,
      platform: TargetPlatform.linux,
      size: _wideWindow,
    );

    await tester.tap(find.byTooltip('Show queue'));
    await tester.pumpAndSettle();
    // The column's own close button.
    await tester.tap(find.byTooltip('Close queue'));
    await tester.pumpAndSettle();
    expect(find.byType(QueueSidePanel), findsNothing);

    await tester.tap(find.byTooltip('Show queue'));
    await tester.pumpAndSettle();
    // And the bar's toggle, which is lit while the column is open.
    await tester.tap(find.byTooltip('Hide queue'));
    await tester.pumpAndSettle();
    expect(find.byType(QueueSidePanel), findsNothing);
    expect(find.byTooltip('Show queue'), findsOneWidget);
  });

  testWidgets('narrowing takes the column away and widening brings it back',
      (WidgetTester tester) async {
    final FakePlaybackController controller = await _pumpShell(
      tester,
      platform: TargetPlatform.linux,
      size: _wideWindow,
    );

    await tester.tap(find.byTooltip('Show queue'));
    await tester.pumpAndSettle();
    expect(find.byType(QueueSidePanel), findsOneWidget);

    await _resize(tester, _narrowDesktopWindow);

    expect(find.byType(QueueSidePanel), findsNothing);
    // Playback is untouched by a resize, and the queue is still one click away
    // as the sheet it has always been.
    expect(controller.state.currentTrack, _current);
    expect(controller.pauseCount, 0);
    expect(find.byTooltip('Queue'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Widening finds it open where it was left, rather than closed.
    await _resize(tester, _wideWindow);
    expect(find.byType(QueueSidePanel), findsOneWidget);
  });

  testWidgets('a narrow desktop window keeps the queue sheet',
      (WidgetTester tester) async {
    await _pumpShell(
      tester,
      platform: TargetPlatform.linux,
      size: _narrowDesktopWindow,
    );

    expect(find.byTooltip('Show queue'), findsNothing);
    await tester.tap(find.byTooltip('Queue'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(QueueSidePanel), findsNothing);
  });

  testWidgets('a wide Android window keeps the phone layout',
      (WidgetTester tester) async {
    await _pumpShell(
      tester,
      platform: TargetPlatform.android,
      size: _wideWindow,
    );

    // No rail, no column, no toggle: a big tablet is still the phone layout.
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(QueueSidePanel), findsNothing);
    expect(find.byTooltip('Show queue'), findsNothing);

    await tester.tap(find.byTooltip('Queue'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
  });

  testWidgets('Tab reaches the column after the page and before the rail',
      (WidgetTester tester) async {
    await _pumpShell(
      tester,
      platform: TargetPlatform.linux,
      size: _wideWindow,
    );

    await tester.tap(find.byTooltip('Show queue'));
    await tester.pumpAndSettle();

    Focus.of(tester.element(find.text('Open Library detail'))).requestFocus();
    await tester.pump();

    int panelStop = -1;
    int railStop = -1;
    for (int i = 0; i < 16; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      if (panelStop < 0 && _focusedInside<QueueSidePanel>()) panelStop = i;
      if (railStop < 0 && _focusedInside<NavigationRail>()) railStop = i;
    }

    expect(panelStop, isNonNegative, reason: 'the column is never reached');
    expect(railStop, isNonNegative, reason: 'the rail is never reached');
    expect(panelStop, lessThan(railStop));
  });

  group('closing the column keeps the keyboard (#390)', () {
    testWidgets('the ✕ hands focus back to the button that reopens it',
        (WidgetTester tester) async {
      await _pumpShell(
        tester,
        platform: TargetPlatform.linux,
        size: _wideWindow,
      );
      await tester.tap(find.byTooltip('Show queue'));
      await tester.pumpAndSettle();

      // Reach the ✕ the way a keyboard user would, then press it.
      _focusButton(tester, 'Close queue');
      await tester.pump();
      expect(_focusedInside<QueueSidePanel>(), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.byType(QueueSidePanel), findsNothing);
      // Not nowhere, and not back at the top of the page: the control that
      // opens the column again, which is where the user is standing.
      expect(find.byTooltip('Show queue'), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus,
        _button(tester, 'Show queue').focusNode,
      );
    });

    testWidgets('narrowing the window past the column does the same',
        (WidgetTester tester) async {
      await _pumpShell(
        tester,
        platform: TargetPlatform.linux,
        size: _wideWindow,
      );
      await tester.tap(find.byTooltip('Show queue'));
      await tester.pumpAndSettle();
      _focusButton(tester, 'Close queue');
      await tester.pump();

      // A resize is not something the user thought of as leaving the column,
      // so it must not be what loses their place in the frame.
      await _resize(tester, _narrowDesktopWindow);

      expect(find.byType(QueueSidePanel), findsNothing);
      expect(
        FocusManager.instance.primaryFocus,
        _button(tester, 'Queue').focusNode,
      );
    });

    testWidgets('opening it leaves focus on the button', (tester) async {
      await _pumpShell(
        tester,
        platform: TargetPlatform.linux,
        size: _wideWindow,
      );
      _focusButton(tester, 'Show queue');
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.byType(QueueSidePanel), findsOneWidget);
      // Opening a pane is not a reason to move the keyboard into it: the next
      // Tab walks into the column, which is the ordinary way in.
      expect(
        FocusManager.instance.primaryFocus,
        _button(tester, 'Hide queue').focusNode,
      );
    });
  });
}
