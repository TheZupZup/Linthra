import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/hub/settings_categories.dart';
import 'package:linthra/features/settings/hub/settings_detail_scaffold.dart';
import 'package:linthra/features/settings/settings_panes.dart';
import 'package:linthra/features/settings/settings_screen.dart';
import 'package:linthra/features/shell/home_shell.dart';

import '../player/fake_playback_controller.dart';

/// Settings on a wide window (#753): the categories in a sidebar and the open
/// page beside them, on the same routes a phone walks one page at a time.
///
/// The frame is the app's own (the tab shell, the Settings tab's page
/// navigator and [SettingsPanes]), with simple stand-in pages so a test can
/// tell exactly which one is open without the providers the real ones need.

const Size _wide = Size(1400, 900);
// Tall enough that the hub's whole list is built, so every row can be tapped.
const Size _narrow = Size(500, 1400);

Widget _page(String title, {List<Widget> children = const <Widget>[]}) =>
    SettingsDetailScaffold(
      title: title,
      children: <Widget>[Text('$title body'), ...children],
    );

GoRouter _router({String initialLocation = AppRoutes.settings}) {
  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final GlobalKey<NavigatorState> pagesKey = GlobalKey<NavigatorState>();
  final List<GlobalKey<NavigatorState>> branchKeys =
      <GlobalKey<NavigatorState>>[
    for (int i = 0; i < 5; i++) GlobalKey<NavigatorState>(),
  ];
  GoRoute leaf(String path, String title, {List<Widget>? children}) => GoRoute(
        path: path,
        builder: (_, __) =>
            _page(title, children: children ?? const <Widget>[]),
      );

  return GoRouter(
    navigatorKey: rootKey,
    initialLocation: initialLocation,
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.onboarding,
        builder: (_, __) => const Scaffold(body: Text('TOUR')),
      ),
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
                path: AppRoutes.library,
                builder: (BuildContext context, __) => Scaffold(
                  body: Column(
                    children: <Widget>[
                      const Text('LIBRARY'),
                      TextButton(
                        onPressed: () =>
                            context.go(AppRoutes.settingsConnections),
                        child: const Text('Open Connections'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          for (int i = 1; i < 4; i++)
            StatefulShellBranch(
              navigatorKey: branchKeys[i],
              routes: <RouteBase>[
                GoRoute(
                  path: '/tab$i',
                  builder: (_, __) => Scaffold(body: Text('Tab $i')),
                ),
              ],
            ),
          StatefulShellBranch(
            navigatorKey: branchKeys[4],
            routes: <RouteBase>[
              ShellRoute(
                navigatorKey: pagesKey,
                builder: (_, __, Widget child) =>
                    SettingsPanes(navigatorKey: pagesKey, child: child),
                routes: <RouteBase>[
                  GoRoute(
                    path: AppRoutes.settings,
                    builder: (_, __) => const SettingsScreen(),
                    routes: <RouteBase>[
                      leaf(
                        'connections',
                        'Connections',
                        children: <Widget>[
                          const TextField(key: Key('server_address')),
                          Builder(
                            builder: (BuildContext context) => TextButton(
                              onPressed: () =>
                                  context.push(AppRoutes.audiobooks),
                              child: const Text('Browse audiobooks'),
                            ),
                          ),
                        ],
                      ),
                      leaf('audiobooks', 'Audiobooks'),
                      leaf('playback', 'Music & playback'),
                      leaf('cache', 'Cache & data'),
                      leaf('downloads', 'Offline & downloads'),
                      leaf('appearance', 'App icon & branding'),
                      leaf('diagnostics', 'Diagnostics & support'),
                      leaf(
                        'about',
                        'About',
                        children: <Widget>[
                          Builder(
                            builder: (BuildContext context) => TextButton(
                              onPressed: () =>
                                  context.push(AppRoutes.settingsSupport),
                              child: const Text('Support Linthra'),
                            ),
                          ),
                        ],
                      ),
                      leaf('support', 'Support'),
                      leaf('report-bug', 'Report a bug'),
                    ],
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

Future<GoRouter> _pump(
  WidgetTester tester, {
  Size size = _wide,
  String initialLocation = AppRoutes.settings,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final GoRouter router = _router(initialLocation: initialLocation);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

Future<void> _resize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  await tester.pumpAndSettle();
}

final Finder _sidebar = find.byKey(const Key('settings_sidebar'));

Finder _inSidebar(String text) =>
    find.descendant(of: _sidebar, matching: find.text(text));

/// The title of the page open beside the sidebar (or on its own when narrow).
String? _openPage(WidgetTester tester) {
  final Iterable<AppBar> bars = tester.widgetList<AppBar>(find.byType(AppBar));
  final AppBar? top = bars.isEmpty ? null : bars.last;
  final Widget? title = top?.title;
  return title is Text ? title.data : null;
}

String? _selected(WidgetTester tester) {
  for (final ListTile tile in tester.widgetList<ListTile>(find.descendant(
    of: _sidebar,
    matching: find.byType(ListTile),
  ))) {
    if (tile.selected) return (tile.title! as Text).data;
  }
  return null;
}

void main() {
  group('a narrow window keeps the phone flow', () {
    testWidgets('the hub lists the categories and a row pushes its page',
        (tester) async {
      await _pump(tester, size: _narrow);

      expect(_sidebar, findsNothing);
      expect(find.text('Connections'), findsOneWidget);

      await tester.tap(find.text('Cache & data'));
      await tester.pumpAndSettle();

      expect(_openPage(tester), 'Cache & data');
      expect(find.text('Connections'), findsNothing);
      // Back is there, and leads to the hub.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Connections'), findsOneWidget);
    });
  });

  group('an expanded window', () {
    testWidgets('shows the categories beside an empty pane', (tester) async {
      await _pump(tester);

      expect(_sidebar, findsOneWidget);
      for (final String title in <String>[
        'Connections',
        'Music & playback',
        'Cache & data',
        'Offline & downloads',
        'Appearance',
        'Welcome tour',
        'Diagnostics & support',
        'About',
      ]) {
        expect(_inSidebar(title), findsOneWidget, reason: title);
      }
      expect(find.text('Pick a category to see its settings.'), findsOneWidget);
      expect(_selected(tester), isNull);
    });

    testWidgets('a category opens beside the sidebar and is selected',
        (tester) async {
      await _pump(tester);

      await tester.tap(_inSidebar('Cache & data'));
      await tester.pumpAndSettle();

      expect(_sidebar, findsOneWidget);
      expect(_openPage(tester), 'Cache & data');
      expect(_selected(tester), 'Cache & data');
      // The sidebar is the way back to every category, so the page itself
      // offers no Back.
      expect(find.byType(BackButton), findsNothing);
    });

    testWidgets('picking another category replaces the page, not stacks it',
        (tester) async {
      final GoRouter router = await _pump(tester);

      await tester.tap(_inSidebar('Cache & data'));
      await tester.pumpAndSettle();
      await tester.tap(_inSidebar('About'));
      await tester.pumpAndSettle();

      expect(_openPage(tester), 'About');
      expect(_selected(tester), 'About');
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        AppRoutes.settingsAbout,
      );

      // One Back leaves the category for the hub, not for Cache & data.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Pick a category to see its settings.'), findsOneWidget);
      expect(_selected(tester), isNull);
    });

    testWidgets('a page opened from a category stays in the pane',
        (tester) async {
      await _pump(tester);
      await tester.tap(_inSidebar('About'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Support Linthra'));
      await tester.pumpAndSettle();

      expect(_sidebar, findsOneWidget);
      expect(_openPage(tester), 'Support');
      expect(_selected(tester), 'About');
      // A page inside a category does go back, to the category.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(_openPage(tester), 'About');
    });

    testWidgets('Back from a nested page goes to its category, not Library',
        (tester) async {
      await _pump(tester);
      await tester.tap(_inSidebar('Connections'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Browse audiobooks'));
      await tester.pumpAndSettle();
      expect(_openPage(tester), 'Audiobooks');
      expect(_selected(tester), 'Connections');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(_openPage(tester), 'Connections');
      expect(find.text('LIBRARY'), findsNothing);
    });

    testWidgets('the welcome tour still opens over the app', (tester) async {
      await _pump(tester);

      await tester.tap(_inSidebar('Welcome tour'));
      await tester.pumpAndSettle();

      expect(find.text('TOUR'), findsOneWidget);
    });
  });

  group('links into Settings select their category', () {
    testWidgets('a deep link to a category', (tester) async {
      await _pump(tester, initialLocation: AppRoutes.settingsDiagnostics);

      expect(_openPage(tester), 'Diagnostics & support');
      expect(_selected(tester), 'Diagnostics & support');
    });

    testWidgets('a deep link to a page inside one', (tester) async {
      await _pump(tester, initialLocation: AppRoutes.settingsSupport);

      expect(_openPage(tester), 'Support');
      expect(_selected(tester), 'About');
    });

    testWidgets('a row on another screen', (tester) async {
      await _pump(tester, initialLocation: AppRoutes.library);

      await tester.tap(find.text('Open Connections'));
      await tester.pumpAndSettle();

      expect(_openPage(tester), 'Connections');
      expect(_selected(tester), 'Connections');
    });
  });

  group('resizing', () {
    testWidgets('keeps the open page, and what was typed into it', (
      tester,
    ) async {
      await _pump(tester);
      await tester.tap(_inSidebar('Connections'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('server_address')),
        'music.example',
      );

      await _resize(tester, _narrow);
      expect(_sidebar, findsNothing);
      expect(_openPage(tester), 'Connections');
      expect(find.text('music.example'), findsOneWidget);
      // On its own the page needs Back again.
      expect(find.byType(BackButton), findsOneWidget);

      await _resize(tester, _wide);
      expect(_sidebar, findsOneWidget);
      expect(_openPage(tester), 'Connections');
      expect(_selected(tester), 'Connections');
      expect(find.text('music.example'), findsOneWidget);
    });

    testWidgets('a page pushed while narrow is beside the sidebar once wide',
        (tester) async {
      await _pump(tester, size: _narrow);
      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Support Linthra'));
      await tester.pumpAndSettle();

      await _resize(tester, _wide);

      expect(_openPage(tester), 'Support');
      expect(_selected(tester), 'About');
    });

    testWidgets('the hub comes back as the list when the pane goes', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.text('Pick a category to see its settings.'), findsOneWidget);

      await _resize(tester, _narrow);

      expect(find.text('Pick a category to see its settings.'), findsNothing);
      expect(find.text('Cache & data'), findsOneWidget);
    });
  });

  group('the keyboard', () {
    testWidgets('Enter on a sidebar row opens it and leaves focus there', (
      tester,
    ) async {
      await _pump(tester);

      Focus.of(tester.element(_inSidebar('About'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(_openPage(tester), 'About');
      expect(
        Focus.of(tester.element(_inSidebar('About'))).hasPrimaryFocus,
        isTrue,
      );
    });

    testWidgets('a click into the page after that keeps its focus', (
      tester,
    ) async {
      await _pump(tester);

      Focus.of(tester.element(_inSidebar('Connections'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('server_address')));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasPrimaryFocus,
        isTrue,
      );
    });

    testWidgets('Tab goes from the sidebar into the page', (tester) async {
      await _pump(tester);
      await tester.tap(_inSidebar('Connections'));
      await tester.pumpAndSettle();

      Focus.of(tester.element(_inSidebar('About'))).requestFocus();
      await tester.pump();
      // Past the last sidebar row, the next stop is in the page beside it.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
      expect(focused, isNotNull);
      expect(
        find.descendant(of: _sidebar, matching: find.byWidget(focused!.widget)),
        findsNothing,
      );
      expect(
        focused.findAncestorWidgetOfExactType<SettingsDetailScaffold>(),
        isNotNull,
      );
    });

    testWidgets('focus in the sidebar moves to the page when it goes', (
      tester,
    ) async {
      await _pump(tester);
      await tester.tap(_inSidebar('Connections'));
      await tester.pumpAndSettle();
      Focus.of(tester.element(_inSidebar('Connections'))).requestFocus();
      await tester.pump();

      await _resize(tester, _narrow);

      final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
      expect(focused, isNotNull);
      // Somewhere in the Settings pages, so the next Tab goes on from there
      // rather than from the top of the app.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<SettingsDetailScaffold>(),
        isNotNull,
      );
    });

    testWidgets('focus in the page survives the sidebar coming and going', (
      tester,
    ) async {
      await _pump(tester);
      await tester.tap(_inSidebar('Connections'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('server_address')));
      await tester.pump();

      FocusNode field() =>
          tester.widget<EditableText>(find.byType(EditableText)).focusNode;
      expect(field().hasPrimaryFocus, isTrue);

      await _resize(tester, _narrow);
      expect(field().hasPrimaryFocus, isTrue);
      await _resize(tester, _wide);
      expect(field().hasPrimaryFocus, isTrue);
    });
  });

  group('selectedSettingsCategory', () {
    // A test of the pure rule, without a widget tree: the categories need a
    // context only for one subtitle.
    testWidgets('follows the first category page in the stack', (tester) async {
      late List<SettingsCategory> categories;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              categories = settingsCategories(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      String? pick(List<String> stack) =>
          selectedSettingsCategory(categories, stack)?.title;

      expect(pick(<String>[AppRoutes.settings]), isNull);
      expect(
        pick(<String>[AppRoutes.settings, AppRoutes.settingsCache]),
        'Cache & data',
      );
      // Support from the theme card stays under Appearance.
      expect(
        pick(<String>[
          AppRoutes.settings,
          AppRoutes.settingsAppearance,
          AppRoutes.settingsSupport,
        ]),
        'Appearance',
      );
      // On its own, Support belongs to About.
      expect(
        pick(<String>[AppRoutes.settings, AppRoutes.settingsSupport]),
        'About',
      );
      expect(
        pick(<String>[AppRoutes.settings, AppRoutes.audiobooks]),
        'Connections',
      );
      expect(
        pick(<String>[AppRoutes.settings, AppRoutes.reportBug]),
        'Diagnostics & support',
      );
      // The tour is not a page, so it never selects anything.
      expect(pick(<String>[AppRoutes.onboardingReplay]), isNull);
    });
  });
}
