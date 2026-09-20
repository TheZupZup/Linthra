import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/shortcuts/keyboard_shortcuts_controller.dart';
import 'package:linthra/app/shortcuts/shortcut_action.dart';
import 'package:linthra/app/shortcuts/shortcut_binding.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_keyboard_shortcut_preferences.dart';
import 'package:linthra/data/repositories/keyboard_shortcut_preferences_provider.dart';
import 'package:linthra/features/help/keyboard_shortcuts_help.dart';
import 'package:linthra/shared/widgets/settings_section_header.dart';

/// The keyboard shortcuts help window (#392).
///
/// The point of the window is that it cannot lie: it reads the registry and
/// the live binding map, so what it shows is what the app answers. Most of
/// what is asserted below is therefore *derived* from the registry rather than
/// written out: a test that listed the shortcuts by hand would be the second
/// hard-coded table this feature exists to avoid.

/// Opens the window over a page with a button on it, and hands back that
/// button's focus node so focus restoration can be checked.
Future<FocusNode> _openHelp(
  WidgetTester tester, {
  Map<String, String> stored = const <String, String>{},
  HostPlatform host = HostPlatform.linux,
}) async {
  final FocusNode opener = FocusNode(debugLabel: 'opener');
  addTearDown(opener.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        keyboardShortcutPreferencesProvider.overrideWithValue(
          InMemoryKeyboardShortcutPreferences(initialOverrides: stored),
        ),
        hostPlatformProvider.overrideWithValue(host),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              return Center(
                child: TextButton(
                  focusNode: opener,
                  onPressed: () => showKeyboardShortcutsHelp(
                    context,
                    returnFocusTo: opener,
                  ),
                  child: const Text('Show all shortcuts'),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('Show all shortcuts'));
  await tester.pumpAndSettle();
  return opener;
}

/// The chord the window draws for [action], read off the screen.
String _shownBinding(WidgetTester tester, ShortcutAction action) {
  final ShortcutActionDefinition definition =
      ShortcutActions.definitionFor(action);
  final Finder row = find.ancestor(
    of: find.text(definition.label),
    matching: find.byType(MergeSemantics),
  );
  final Iterable<Text> texts = tester.widgetList<Text>(
    find.descendant(of: row, matching: find.byType(Text)),
  );
  // Label, description, chord, and the alias line when there is one.
  return texts.elementAt(2).data!;
}

/// What the controller says [action] is bound to right now.
ShortcutBinding _liveBinding(WidgetTester tester, ShortcutAction action) {
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  return container.read(activeShortcutBindingsProvider)[action]!;
}

void main() {
  group('what it lists', () {
    testWidgets('every action in the registry, with its default chord',
        (tester) async {
      await _openHelp(tester);

      for (final ShortcutActionDefinition definition
          in ShortcutActions.definitions) {
        expect(
          find.text(definition.label),
          findsOneWidget,
          reason: '${definition.label} is bound but not listed',
        );
        expect(
          _shownBinding(tester, definition.action),
          definition.defaultBinding.label,
          reason: definition.label,
        );
      }
    });

    testWidgets('the representative defaults read the way the docs say',
        (tester) async {
      // Spelled out rather than derived, once: a registry-driven test would
      // still pass if every default silently changed.
      await _openHelp(tester);

      expect(_shownBinding(tester, ShortcutAction.playPause), 'Ctrl + Space');
      expect(_shownBinding(tester, ShortcutAction.next), 'Ctrl + Right');
      expect(_shownBinding(tester, ShortcutAction.search), 'Ctrl + K');
      expect(_shownBinding(tester, ShortcutAction.library), 'Ctrl + L');
      expect(
        _shownBinding(tester, ShortcutAction.shortcutsHelp),
        'Ctrl + Slash',
      );
    });

    testWidgets('a fixed alias is shown beside the binding it sits next to',
        (tester) async {
      await _openHelp(tester);

      // Ctrl+F is not a second shortcut to learn, so it reads as a second way
      // to press the one that is there.
      expect(find.text('or Ctrl + F'), findsOneWidget);
    });

    testWidgets('and says where media keys went, and where to remap',
        (tester) async {
      await _openHelp(tester);

      expect(
        find.textContaining('Media keys are handled by your desktop'),
        findsOneWidget,
      );
      expect(
          find.textContaining('Settings → Music & playback'), findsOneWidget);
    });

    testWidgets('but does not point a phone at a card it does not have',
        (tester) async {
      // The window is not gated on the platform (a tablet with a keyboard
      // case sends the chord like any other keyboard), but the remapping card
      // is desktop-only, so the pointer to it has to be too.
      await _openHelp(tester, host: HostPlatform.android);

      expect(
        find.textContaining('Media keys are handled by your desktop'),
        findsOneWidget,
      );
      expect(find.textContaining('Settings → Music & playback'), findsNothing);
    });
  });

  group('grouping', () {
    testWidgets('headings are the registry\'s, in the registry\'s order',
        (tester) async {
      await _openHelp(tester);

      expect(
        tester
            .widgetList<SettingsSectionHeader>(
              find.byType(SettingsSectionHeader),
            )
            .map((SettingsSectionHeader header) => header.title)
            .toList(),
        ShortcutActions.grouped
            .map((ShortcutGroupListing listing) => listing.group.label)
            .toList(),
      );
    });

    testWidgets('and the same window opened twice groups the same way',
        (tester) async {
      await _openHelp(tester);
      List<String> headings() => tester
          .widgetList<SettingsSectionHeader>(find.byType(SettingsSectionHeader))
          .map((SettingsSectionHeader header) => header.title)
          .toList();
      final List<String> first = headings();

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show all shortcuts'));
      await tester.pumpAndSettle();

      expect(headings(), first);
      expect(first, isNotEmpty);
    });

    testWidgets('every action sits under its own heading', (tester) async {
      await _openHelp(tester);

      // Read positionally: a row belongs to the last heading drawn above it.
      final List<Element> ordered = <Element>[
        ...find.byType(SettingsSectionHeader).evaluate(),
        ...find.byType(MergeSemantics).evaluate(),
      ]..sort((Element a, Element b) {
          final double ay =
              tester.getTopLeft(find.byElementPredicate((e) => e == a)).dy;
          final double by =
              tester.getTopLeft(find.byElementPredicate((e) => e == b)).dy;
          return ay.compareTo(by);
        });

      String? heading;
      final Map<String, List<String>> seen = <String, List<String>>{};
      for (final Element element in ordered) {
        final Widget widget = element.widget;
        if (widget is SettingsSectionHeader) {
          heading = widget.title;
          seen.putIfAbsent(heading, () => <String>[]);
          continue;
        }
        final Finder label = find.descendant(
          of: find.byElementPredicate((Element e) => e == element),
          matching: find.byType(Text),
        );
        seen[heading!]!.add(tester.widget<Text>(label.first).data!);
      }

      expect(seen, <String, List<String>>{
        for (final ShortcutGroupListing listing in ShortcutActions.grouped)
          listing.group.label: <String>[
            for (final ShortcutActionDefinition d in listing.actions) d.label,
          ],
      });
    });
  });

  group('remapped bindings', () {
    testWidgets('a stored override is shown instead of the default',
        (tester) async {
      await _openHelp(
        tester,
        stored: <String, String>{
          'library': const ShortcutBinding(
            LogicalKeyboardKey.keyB,
            control: true,
            shift: true,
          ).storageValue,
        },
      );

      expect(_shownBinding(tester, ShortcutAction.library), 'Ctrl + Shift + B');
      expect(
        find.text('Ctrl + L'),
        findsNothing,
        reason: 'the default it was remapped off is gone from the window',
      );
    });

    testWidgets('a remap made while the window is open updates it live',
        (tester) async {
      await _openHelp(tester);
      expect(_shownBinding(tester, ShortcutAction.queue), 'Ctrl + U');

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      await container
          .read(keyboardShortcutsControllerProvider.notifier)
          .setBinding(
            ShortcutAction.queue,
            const ShortcutBinding(LogicalKeyboardKey.f7),
          );
      await tester.pumpAndSettle();

      expect(_shownBinding(tester, ShortcutAction.queue), 'F7');
    });

    testWidgets('resetting one action puts its default back in the window',
        (tester) async {
      await _openHelp(
        tester,
        stored: <String, String>{
          'now_playing':
              const ShortcutBinding(LogicalKeyboardKey.f8).storageValue,
        },
      );
      expect(_shownBinding(tester, ShortcutAction.nowPlaying), 'F8');

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      await container
          .read(keyboardShortcutsControllerProvider.notifier)
          .resetToDefault(ShortcutAction.nowPlaying);
      await tester.pumpAndSettle();

      expect(_shownBinding(tester, ShortcutAction.nowPlaying), 'Ctrl + P');
    });

    testWidgets('and reset-all puts every default back', (tester) async {
      await _openHelp(
        tester,
        stored: <String, String>{
          'search': const ShortcutBinding(LogicalKeyboardKey.f9).storageValue,
          'queue': const ShortcutBinding(
            LogicalKeyboardKey.keyJ,
            control: true,
          ).storageValue,
        },
      );
      expect(_shownBinding(tester, ShortcutAction.search), 'F9');
      expect(_shownBinding(tester, ShortcutAction.queue), 'Ctrl + J');

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      await container
          .read(keyboardShortcutsControllerProvider.notifier)
          .resetAll();
      await tester.pumpAndSettle();

      for (final ShortcutActionDefinition definition
          in ShortcutActions.definitions) {
        expect(
          _shownBinding(tester, definition.action),
          definition.defaultBinding.label,
          reason: definition.label,
        );
      }
    });
  });

  group('one table, not two', () {
    testWidgets('every row matches the map the dispatcher installs',
        (tester) async {
      // The guard against a second hard-coded table: whatever the live map
      // says, down to a chord nothing ships with, is what the window draws.
      await _openHelp(
        tester,
        stored: <String, String>{
          'play_pause': const ShortcutBinding(
            LogicalKeyboardKey.f5,
            alt: true,
          ).storageValue,
          'previous': const ShortcutBinding(
            LogicalKeyboardKey.pageUp,
            meta: true,
          ).storageValue,
        },
      );

      for (final ShortcutActionDefinition definition
          in ShortcutActions.definitions) {
        expect(
          _shownBinding(tester, definition.action),
          _liveBinding(tester, definition.action).label,
          reason: definition.label,
        );
      }
      expect(_shownBinding(tester, ShortcutAction.playPause), 'Alt + F5');
      expect(
        _shownBinding(tester, ShortcutAction.previous),
        'Super + Page Up',
      );
    });
  });

  group('keyboard', () {
    testWidgets('it opens with the keyboard inside it', (tester) async {
      await _openHelp(tester);

      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byWidget(
            FocusManager.instance.primaryFocus!.context!.widget,
          ),
        ),
        findsOneWidget,
        reason: 'the window must be readable without reaching for the mouse',
      );
    });

    testWidgets('Tab reaches Close, and Enter on it closes the window',
        (tester) async {
      await _openHelp(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find
              .byWidget(FocusManager.instance.primaryFocus!.context!.widget),
          matching: find.text('Close'),
        ),
        findsOneWidget,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('Escape closes it', (tester) async {
      await _openHelp(tester);
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('the list scrolls from the keyboard, without reaching Close',
        (tester) async {
      // A window taller than the screen is the normal case once a few groups
      // are in it, and the keyboard has to be able to reach the bottom. This
      // is what the autofocused stop *inside* the scroll view buys: Flutter
      // looks for a Scrollable above whatever holds the keyboard, so a focus
      // stop outside it would leave these keys doing nothing.
      tester.view.physicalSize = const Size(700, 380);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await _openHelp(tester);
      final ScrollableState scrollable = tester.state(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Scrollable),
        ),
      );
      expect(scrollable.position.maxScrollExtent, greaterThan(0));

      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      final double afterPage = scrollable.position.pixels;
      expect(afterPage, greaterThan(0));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(scrollable.position.pixels, lessThan(afterPage));
    });
  });

  group('focus', () {
    testWidgets('closing hands the keyboard back to what opened it',
        (tester) async {
      final FocusNode opener = await _openHelp(tester);
      expect(opener.hasFocus, isFalse, reason: 'the window has it while open');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(
        opener.hasFocus,
        isTrue,
        reason: 'a click never focused the button, so Flutter has nothing to '
            'restore on its own, so the window has to hand it back',
      );
    });

    testWidgets('and it does the same when Close is used', (tester) async {
      final FocusNode opener = await _openHelp(tester);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      expect(opener.hasFocus, isTrue);
    });

    testWidgets('a control that went away while it was open strands nothing',
        (tester) async {
      // The control named as the way back can be removed out from under the
      // window, and its [FocusNode] disposed with it. A node keeps the last
      // context it was attached to even then, so the window has to ask whether
      // that context is still mounted rather than whether it exists.
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            keyboardShortcutPreferencesProvider.overrideWithValue(
              InMemoryKeyboardShortcutPreferences(),
            ),
          ],
          child: const MaterialApp(home: _DisappearingOpener()),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('drop the page'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(AlertDialog), findsNothing);

      // And the keyboard still works on what is left, rather than being
      // pointed at a control that is no longer on screen.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
      expect(focused?.mounted, isTrue);
      expect(
        find.descendant(
          of: find.byWidget(focused!.widget),
          matching: find.text('drop the page'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('with nothing named, it goes back to whatever held it',
        (tester) async {
      final FocusNode elsewhere = FocusNode(debugLabel: 'elsewhere');
      addTearDown(elsewhere.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            keyboardShortcutPreferencesProvider.overrideWithValue(
              InMemoryKeyboardShortcutPreferences(),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Focus(
                focusNode: elsewhere,
                child: Builder(
                  builder: (BuildContext context) => TextButton(
                    onPressed: () => showKeyboardShortcutsHelp(context),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      elsewhere.requestFocus();
      await tester.pumpAndSettle();
      expect(elsewhere.hasFocus, isTrue);

      // The shortcut path: fired from wherever the user happened to be, with
      // no control to name.
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(elsewhere.hasFocus, isTrue);
    });
  });

  group('narrow windows', () {
    testWidgets('a phone-width window lays out without overflowing',
        (tester) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await _openHelp(tester);

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('and a long action name wraps instead of pushing the chord off',
        (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      // Every modifier at once on the longest key name the app labels: the
      // widest chord the rules allow.
      await _openHelp(
        tester,
        stored: <String, String>{
          'queue': const ShortcutBinding(
            LogicalKeyboardKey.pageDown,
            control: true,
            shift: true,
            alt: true,
            meta: true,
          ).storageValue,
        },
      );

      expect(
        _shownBinding(tester, ShortcutAction.queue),
        'Ctrl + Alt + Shift + Super + Page Down',
      );
      expect(tester.takeException(), isNull);
    });
  });
}

/// A page that can remove the button the help window was told to return focus
/// to, disposing its [FocusNode] with it, while the window is still open.
class _DisappearingOpener extends StatefulWidget {
  const _DisappearingOpener();

  @override
  State<_DisappearingOpener> createState() => _DisappearingOpenerState();
}

class _DisappearingOpenerState extends State<_DisappearingOpener> {
  bool _present = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: <Widget>[
          if (_present) const _OpenerButton(),
          TextButton(
            onPressed: () => setState(() => _present = false),
            child: const Text('drop the page'),
          ),
        ],
      ),
    );
  }
}

/// Owns the node, and disposes it when it leaves the tree, which is what
/// every control in the app that opens the window does.
class _OpenerButton extends StatefulWidget {
  const _OpenerButton();

  @override
  State<_OpenerButton> createState() => _OpenerButtonState();
}

class _OpenerButtonState extends State<_OpenerButton> {
  final FocusNode _node = FocusNode(debugLabel: 'disappearing opener');

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextButton(
      focusNode: _node,
      onPressed: () => showKeyboardShortcutsHelp(context, returnFocusTo: _node),
      child: const Text('open'),
    );
  }
}
