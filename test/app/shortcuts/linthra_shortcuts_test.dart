import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/router.dart';
import 'package:linthra/app/shortcuts/keyboard_shortcuts_controller.dart';
import 'package:linthra/app/shortcuts/linthra_shortcuts.dart';
import 'package:linthra/app/shortcuts/shortcut_action.dart';
import 'package:linthra/app/shortcuts/shortcut_binding.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_keyboard_shortcut_preferences.dart';
import 'package:linthra/data/repositories/keyboard_shortcut_preferences_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/onboarding/onboarding_controller.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/widgets/queue_sheet.dart';
import 'package:linthra/features/shell/home_shell.dart';

import '../../features/library/fake_music_library_repository.dart';
import '../../features/player/fake_playback_controller.dart';

/// Dispatch: what actually happens when a key is pressed (#391).
///
/// The rules that matter are the ones a user would notice going wrong. A
/// shortcut has to run the *same* code the button beside it runs; it has to
/// fire once however long the key is held; it has to stand down when the
/// keyboard is inside a text field and the field wanted that key; and a remap
/// has to take effect without a restart.

const Track _current = Track(
  id: '1',
  title: 'Song One',
  uri: 'jellyfin:1',
  artistName: 'Artist A',
);

const PlaybackState _playing = PlaybackState(
  status: PlaybackStatus.playing,
  currentTrack: _current,
);

const PlaybackState _paused = PlaybackState(
  status: PlaybackStatus.paused,
  currentTrack: _current,
);

/// A stalled stream. Not playing, not paused — and the moment you most want
/// the play/pause key to stop it.
const PlaybackState _buffering = PlaybackState(
  status: PlaybackStatus.buffering,
  currentTrack: _current,
);

/// The initial prepare: a track picked, its source not installed yet.
const PlaybackState _loading = PlaybackState(
  status: PlaybackStatus.loading,
  currentTrack: _current,
);

/// A wide Linux window: the frame draws the rail and can host the queue column.
const Size _wideDesktop = Size(1600, 900);

/// A phone-shaped window: the queue is a sheet.
const Size _phone = Size(420, 900);

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
    // Starts away from Library so "go to Library" has somewhere to go from.
    initialLocation: '/playlists',
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
                    // Somewhere inside the branch, so "switching tabs kept my
                    // place" is a thing a test can see.
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
      GoRoute(
        path: '/player',
        builder: (_, __) => const Scaffold(
          body: Center(child: Text('player screen')),
        ),
      ),
    ],
  );
}

class _Harness {
  _Harness(this.playback, this.router);
  final FakePlaybackController playback;
  final GoRouter router;

  /// Which tab the shell is on.
  String get location => router.routerDelegate.currentConfiguration.uri.path;

  /// What is actually on top, which is *not* [location] once something has
  /// been pushed over the shell: an imperative push leaves the configuration's
  /// uri on the page underneath.
  String get topRoute =>
      router.routerDelegate.currentConfiguration.matches.last.matchedLocation;

  /// How deep the stack is, so "pressing it twice did not push twice" can be
  /// asserted rather than eyeballed — two identical player screens look like
  /// one.
  int get stackDepth =>
      router.routerDelegate.currentConfiguration.matches.length;
}

Future<_Harness> _pumpApp(
  WidgetTester tester, {
  PlaybackState playback = _playing,
  Map<String, String> storedOverrides = const <String, String>{},
  Size size = _wideDesktop,
  TargetPlatform platform = TargetPlatform.linux,
  bool onboardingCompleted = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  final List<GlobalKey<NavigatorState>> branchKeys =
      <GlobalKey<NavigatorState>>[
    for (int i = 0; i < 5; i++) GlobalKey<NavigatorState>(),
  ];
  final FakePlaybackController controller =
      FakePlaybackController(initial: playback);
  addTearDown(controller.dispose);
  GoRouter? router;

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository()),
        playbackControllerProvider.overrideWithValue(controller),
        // The dispatcher stands down until first-run setup is finished, so
        // every dispatch test has to say that it is.
        onboardingBootstrapProvider
            .overrideWith((ref) async => onboardingCompleted),
        keyboardShortcutPreferencesProvider.overrideWithValue(
          InMemoryKeyboardShortcutPreferences(
            initialOverrides: storedOverrides,
          ),
        ),
      ],
      // Mirrors how LinthraApp mounts the binding: above the router, on the
      // same root navigator key, so routes pushed over the shell are still
      // descendants of it.
      child: Consumer(
        builder: (BuildContext context, WidgetRef ref, _) {
          final GlobalKey<NavigatorState> rootKey =
              ref.watch(rootNavigatorKeyProvider);
          router ??= _router(rootKey, branchKeys);
          return MaterialApp.router(
            theme: ThemeData(platform: platform),
            routerConfig: router!,
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
  return _Harness(controller, router!);
}

/// Presses [key] with Ctrl held, the way every default binding is shaped.
Future<void> _pressCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  group('the defaults dispatch', () {
    testWidgets('Ctrl+Space pauses what is playing', (tester) async {
      final _Harness app = await _pumpApp(tester);

      await _pressCtrl(tester, LogicalKeyboardKey.space);

      expect(app.playback.pauseCount, 1);
      expect(app.playback.playCount, 0);
    });

    testWidgets('and plays what is paused', (tester) async {
      final _Harness app = await _pumpApp(tester, playback: _paused);

      await _pressCtrl(tester, LogicalKeyboardKey.space);

      expect(app.playback.playCount, 1);
      expect(app.playback.pauseCount, 0);
    });

    testWidgets('Ctrl+Right and Ctrl+Left move through the queue',
        (tester) async {
      final _Harness app = await _pumpApp(tester);

      await _pressCtrl(tester, LogicalKeyboardKey.arrowRight);
      await _pressCtrl(tester, LogicalKeyboardKey.arrowLeft);

      expect(app.playback.skipCount, 1);
      expect(app.playback.previousCount, 1);
    });

    testWidgets('Ctrl+L goes to the Library tab', (tester) async {
      final _Harness app = await _pumpApp(tester);
      expect(app.location, '/playlists');

      await _pressCtrl(tester, LogicalKeyboardKey.keyL);

      expect(app.location, '/library');
      expect(find.text('Library screen'), findsOneWidget);
    });

    testWidgets('and brings back whatever Library had open', (tester) async {
      final _Harness app = await _pumpApp(tester);
      app.router.go('/library/detail');
      await tester.pumpAndSettle();
      expect(find.text('Library detail'), findsOneWidget);

      // Away to another tab, the way a rail click goes...
      await tester.tap(find.text('Playlists'));
      await tester.pumpAndSettle();
      expect(find.text('Playlists screen'), findsOneWidget);

      await _pressCtrl(tester, LogicalKeyboardKey.keyL);

      expect(
        find.text('Library detail'),
        findsOneWidget,
        reason: 'the shortcut switches the branch, so the tab keeps its own '
            'stack — a plain go() would have thrown the detail page away',
      );
      expect(app.location, '/library/detail');
    });

    testWidgets('and pressing it again goes back to the top of Library',
        (tester) async {
      final _Harness app = await _pumpApp(tester);
      app.router.go('/library/detail');
      await tester.pumpAndSettle();

      // Already on Library: the same thing a second rail click does.
      await _pressCtrl(tester, LogicalKeyboardKey.keyL);

      expect(app.location, '/library');
      expect(find.text('Library screen'), findsOneWidget);
    });

    testWidgets('Ctrl+Space stops a stream that is still buffering',
        (tester) async {
      final _Harness app = await _pumpApp(tester, playback: _paused);
      // Pushed in after the first frame has settled: a buffering transport
      // spins, and a spinner never lets pumpAndSettle finish.
      app.playback.emit(_buffering);
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(
        app.playback.pauseCount,
        1,
        reason: 'buffering is the playing side, exactly as the transport '
            'button reads it',
      );
      expect(app.playback.playCount, 0);
    });

    testWidgets('but stands down while a track is still being prepared',
        (tester) async {
      final _Harness app = await _pumpApp(tester, playback: _paused);
      app.playback.emit(_loading);
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(
        app.playback.playCount,
        0,
        reason: 'no source is installed yet, so play() would resume whatever '
            'was loaded before — which is why the transport button is '
            'disabled here too',
      );
      expect(app.playback.pauseCount, 0);
    });

    testWidgets('Ctrl+K opens quick search', (tester) async {
      await _pumpApp(tester);

      await _pressCtrl(tester, LogicalKeyboardKey.keyK);

      expect(find.byKey(const Key('quick_search_field')), findsOneWidget);
    });

    testWidgets('Ctrl+P opens Now Playing, and will not stack a second one',
        (tester) async {
      final _Harness app = await _pumpApp(tester);

      await _pressCtrl(tester, LogicalKeyboardKey.keyP);
      expect(app.topRoute, '/player');
      expect(find.text('player screen'), findsOneWidget);
      final int depth = app.stackDepth;

      await _pressCtrl(tester, LogicalKeyboardKey.keyP);

      // Two players stacked look exactly like one, so the stack is what has to
      // be checked.
      expect(app.stackDepth, depth);
      // And one press back is enough to leave.
      app.router.pop();
      await tester.pumpAndSettle();
      expect(find.text('player screen'), findsNothing);
    });
  });

  group('the queue shortcut follows whichever host this window has', () {
    testWidgets('a wide desktop window toggles the column, not a sheet',
        (tester) async {
      await _pumpApp(tester);

      await _pressCtrl(tester, LogicalKeyboardKey.keyU);

      expect(find.byType(QueueSheet), findsOneWidget);
      expect(
        find.byType(BottomSheet),
        findsNothing,
        reason: 'the frame has a column, so nothing should have been shown '
            'over the page',
      );

      // And it is a toggle: pressing again puts it away.
      await _pressCtrl(tester, LogicalKeyboardKey.keyU);
      expect(find.byType(QueueSheet), findsNothing);
    });

    testWidgets('a phone-sized window opens the sheet it has always used',
        (tester) async {
      await _pumpApp(tester, size: _phone, platform: TargetPlatform.android);

      await _pressCtrl(tester, LogicalKeyboardKey.keyU);

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(QueueSheet), findsOneWidget);
    });

    testWidgets('and a phone-sized window toggles that sheet back off',
        (tester) async {
      await _pumpApp(tester, size: _phone, platform: TargetPlatform.android);

      await _pressCtrl(tester, LogicalKeyboardKey.keyU);
      expect(find.byType(QueueSheet), findsOneWidget);

      await _pressCtrl(tester, LogicalKeyboardKey.keyU);

      expect(
        find.byType(QueueSheet),
        findsNothing,
        reason: 'a toggle that stacked a second sheet would not be a toggle',
      );
    });

    testWidgets('and still the column after the keyboard has wandered off',
        (tester) async {
      // Regression: the frame used to claim the queue through a nested
      // `Actions`, which is resolved from wherever the focus happens to be.
      // Leaving a tab that had a page pushed inside it parks the focus on the
      // scope *above* the frame, and from there the frame stopped being found
      // at all: a modal sheet appeared over a window that has a column.
      final _Harness app = await _pumpApp(tester);
      app.router.go('/library/detail');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Playlists'));
      await tester.pumpAndSettle();

      await _pressCtrl(tester, LogicalKeyboardKey.keyU);

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(QueueSheet), findsOneWidget);
    });

    testWidgets('a route pushed over the sheet is not what the chord closes',
        (tester) async {
      // Regression: the toggle used to pop the top of the navigator, which
      // after a Ctrl+P is Now Playing, not the sheet. The user pressed the
      // queue chord and lost the player instead.
      final _Harness app = await _pumpApp(
        tester,
        size: _phone,
        platform: TargetPlatform.android,
      );

      await _pressCtrl(tester, LogicalKeyboardKey.keyU);
      expect(find.byType(QueueSheet), findsOneWidget);
      await _pressCtrl(tester, LogicalKeyboardKey.keyP);
      expect(app.topRoute, '/player');

      await _pressCtrl(tester, LogicalKeyboardKey.keyU);

      expect(app.topRoute, '/player', reason: 'the player stays put');
      expect(
        find.byType(QueueSheet),
        findsOneWidget,
        reason: 'the buried sheet is replaced by one the user can see',
      );
      // And the stale one really was taken out, not left to surface again:
      // close the visible sheet, leave the player, and there is nothing
      // underneath.
      await _pressCtrl(tester, LogicalKeyboardKey.keyU);
      expect(find.byType(QueueSheet), findsNothing);
      expect(app.topRoute, '/player');
      app.router.pop();
      await tester.pumpAndSettle();
      expect(find.byType(QueueSheet), findsNothing);
    });

    testWidgets('a second press while it is still closing takes nothing else',
        (tester) async {
      final _Harness app = await _pumpApp(
        tester,
        size: _phone,
        platform: TargetPlatform.android,
      );
      await _pressCtrl(tester, LogicalKeyboardKey.keyU);
      expect(find.byType(QueueSheet), findsOneWidget);

      // Close it, then press again before it has finished leaving. The sheet
      // is still on the navigator at this point, so a toggle that waited for
      // the future to complete would have popped the page underneath.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(app.location, '/playlists');
      expect(find.text('Playlists screen'), findsOneWidget);
      expect(
        find.byType(QueueSheet),
        findsOneWidget,
        reason: 'the second press is an open, the way a toggle reads',
      );
    });

    testWidgets('and closes a sheet a button opened, not a second one',
        (tester) async {
      // The sheet claims the chord itself while it is up, so it does not
      // matter who opened it. Tracking only the sheets the shortcut opened
      // meant a button-opened queue got a second sheet stacked on it.
      // A desktop window wide enough for the rail but not for the column, so
      // the mini-player's queue button is the sheet-opening one.
      await _pumpApp(tester, size: const Size(1000, 900));
      await tester.tap(find.byTooltip('Queue'));
      await tester.pumpAndSettle();
      expect(find.byType(QueueSheet), findsOneWidget);

      await _pressCtrl(tester, LogicalKeyboardKey.keyU);

      expect(find.byType(QueueSheet), findsNothing);
    });

    testWidgets('over Now Playing, where the frame is not an ancestor',
        (tester) async {
      await _pumpApp(tester);
      await tester.tap(find.text('open player'));
      await tester.pumpAndSettle();

      await _pressCtrl(tester, LogicalKeyboardKey.keyU);

      // The shell cannot answer from up there, so the app-level fallback does.
      expect(find.byType(BottomSheet), findsOneWidget);

      // The fallback is a toggle too.
      await _pressCtrl(tester, LogicalKeyboardKey.keyU);
      expect(find.byType(QueueSheet), findsNothing);
    });
  });

  group('typing wins', () {
    testWidgets('Ctrl+Right moves the caret instead of skipping a track',
        (tester) async {
      final _Harness app = await _pumpApp(tester);

      await tester.tap(find.byKey(const Key('branch_field')));
      await tester.pumpAndSettle();
      await _pressCtrl(tester, LogicalKeyboardKey.arrowRight);

      expect(
        app.playback.skipCount,
        0,
        reason: 'Ctrl+Right is "next word" in a field, and the field had focus',
      );
    });

    testWidgets('Ctrl+Space does not toggle playback while typing',
        (tester) async {
      final _Harness app = await _pumpApp(tester);

      await tester.tap(find.byKey(const Key('branch_field')));
      await tester.pumpAndSettle();
      await _pressCtrl(tester, LogicalKeyboardKey.space);

      expect(app.playback.pauseCount, 0);
    });

    testWidgets('but Ctrl+K still opens search from inside a field',
        (tester) async {
      await _pumpApp(tester);

      await tester.tap(find.byKey(const Key('branch_field')));
      await tester.pumpAndSettle();
      await _pressCtrl(tester, LogicalKeyboardKey.keyK);

      expect(
        find.byKey(const Key('quick_search_field')),
        findsOneWidget,
        reason: 'the rule is not "no shortcuts while typing" — a field never '
            'wanted Ctrl+K',
      );
    });

    testWidgets('the frame\'s own queue action stands down too',
        (tester) async {
      // Ctrl+A is "select all" in a field. The shell answers the queue intent
      // before the app-level command does, so it has to carry the same rule.
      await _pumpApp(
        tester,
        storedOverrides: <String, String>{
          'queue': const ShortcutBinding(LogicalKeyboardKey.keyA, control: true)
              .storageValue,
        },
      );

      await tester.tap(find.byKey(const Key('branch_field')));
      await tester.pumpAndSettle();
      await _pressCtrl(tester, LogicalKeyboardKey.keyA);

      expect(find.byType(QueueSheet), findsNothing);

      // And it is only standing down for the field: away from it, the remap
      // works.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await _pressCtrl(tester, LogicalKeyboardKey.keyA);
      expect(find.byType(QueueSheet), findsOneWidget);
    });

    testWidgets('a fixed alias keeps working when the remap would not',
        (tester) async {
      // Search moved onto a chord a field owns. Ctrl+F is not that chord, and
      // no field wants it, so the alias must still answer from inside one.
      await _pumpApp(
        tester,
        storedOverrides: <String, String>{
          'search':
              const ShortcutBinding(LogicalKeyboardKey.keyA, control: true)
                  .storageValue,
        },
      );

      await tester.tap(find.byKey(const Key('branch_field')));
      await tester.pumpAndSettle();
      await _pressCtrl(tester, LogicalKeyboardKey.keyF);

      expect(find.byKey(const Key('quick_search_field')), findsOneWidget);
    });

    testWidgets('leaving the field gives the shortcut back', (tester) async {
      final _Harness app = await _pumpApp(tester);

      await tester.tap(find.byKey(const Key('branch_field')));
      await tester.pumpAndSettle();
      await _pressCtrl(tester, LogicalKeyboardKey.arrowRight);
      expect(app.playback.skipCount, 0);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await _pressCtrl(tester, LogicalKeyboardKey.arrowRight);

      expect(app.playback.skipCount, 1);
    });
  });

  group('exactly once', () {
    testWidgets('holding the key does not skip the whole queue',
        (tester) async {
      final _Harness app = await _pumpApp(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      // What an auto-repeating key sends: further downs with no up between.
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(app.playback.skipCount, 1);
    });

    testWidgets('one press is one action, not one per modifier side',
        (tester) async {
      final _Harness app = await _pumpApp(tester);

      await _pressCtrl(tester, LogicalKeyboardKey.arrowRight);

      expect(app.playback.skipCount, 1);
    });
  });

  group('remapping', () {
    testWidgets('a stored override dispatches instead of the default',
        (tester) async {
      const ShortcutBinding ctrlJ =
          ShortcutBinding(LogicalKeyboardKey.keyJ, control: true);
      final _Harness app = await _pumpApp(
        tester,
        storedOverrides: <String, String>{'next': ctrlJ.storageValue},
      );

      await _pressCtrl(tester, LogicalKeyboardKey.keyJ);
      expect(app.playback.skipCount, 1);

      // And the default it replaced no longer does anything.
      await _pressCtrl(tester, LogicalKeyboardKey.arrowRight);
      expect(app.playback.skipCount, 1);
    });

    testWidgets('a remap takes effect while the app is running',
        (tester) async {
      final _Harness app = await _pumpApp(tester);
      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      await container.read(keyboardShortcutsControllerProvider.future);

      await container
          .read(keyboardShortcutsControllerProvider.notifier)
          .setBinding(
            ShortcutAction.next,
            const ShortcutBinding(LogicalKeyboardKey.keyJ, control: true),
          );
      await tester.pumpAndSettle();

      await _pressCtrl(tester, LogicalKeyboardKey.keyJ);

      expect(app.playback.skipCount, 1, reason: 'no restart should be needed');
    });

    testWidgets('resetting brings the default back', (tester) async {
      final _Harness app = await _pumpApp(
        tester,
        storedOverrides: <String, String>{
          'next': const ShortcutBinding(LogicalKeyboardKey.keyJ, control: true)
              .storageValue,
        },
      );
      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      await container.read(keyboardShortcutsControllerProvider.future);

      await container
          .read(keyboardShortcutsControllerProvider.notifier)
          .resetAll();
      await tester.pumpAndSettle();

      await _pressCtrl(tester, LogicalKeyboardKey.arrowRight);

      expect(app.playback.skipCount, 1);
    });
  });

  group('first run', () {
    testWidgets('nothing is bound until onboarding is finished',
        (tester) async {
      final _Harness app = await _pumpApp(tester, onboardingCompleted: false);

      await _pressCtrl(tester, LogicalKeyboardKey.space);
      await _pressCtrl(tester, LogicalKeyboardKey.keyL);

      expect(app.playback.pauseCount, 0);
      expect(
        app.location,
        '/playlists',
        reason: 'the router gates onboarding on its initial location alone, '
            'so a shortcut out of it would leave setup half-finished',
      );
    });
  });

  test('the frame agrees with the shortcut about which branch Library is', () {
    // A const constructor cannot assert this, and getting it wrong would send
    // Ctrl+L to Folders.
    expect(
      HomeShell.destinationLabels[HomeShell.libraryBranchIndex],
      'Library',
    );
  });

  test('the activator table is what the registry says it is', () {
    final Map<ShortcutActivator, Intent> activators =
        shortcutActivators(ShortcutActions.defaults);

    // One entry per action, plus the single fixed alias.
    expect(activators.length, ShortcutAction.values.length + 1);

    // Compared field by field: SingleActivator does not implement ==, so a
    // freshly built one is never the same map key as the installed one.
    bool installed(ShortcutBinding binding) {
      final SingleActivator wanted = binding.activator;
      return activators.keys.whereType<SingleActivator>().any(
            (SingleActivator a) =>
                a.trigger == wanted.trigger &&
                a.control == wanted.control &&
                a.shift == wanted.shift &&
                a.alt == wanted.alt &&
                a.meta == wanted.meta,
          );
    }

    for (final ShortcutActionDefinition d in ShortcutActions.definitions) {
      expect(
        installed(d.defaultBinding),
        isTrue,
        reason: '${d.label} is not reachable by its own default',
      );
      for (final ShortcutBinding alias in d.aliases) {
        expect(installed(alias), isTrue, reason: '${d.label} alias');
      }
    }
  });
}
