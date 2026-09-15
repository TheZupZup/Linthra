import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/shortcuts/shortcut_action.dart';
import 'package:linthra/app/shortcuts/shortcut_binding.dart';
import 'package:linthra/core/repositories/keyboard_shortcut_preferences.dart';
import 'package:linthra/data/repositories/in_memory_keyboard_shortcut_preferences.dart';
import 'package:linthra/data/repositories/keyboard_shortcut_preferences_provider.dart';
import 'package:linthra/features/settings/desktop/keyboard_shortcuts_section.dart';

/// Remapping as a user does it (#391): open the row, press the keys, and be
/// told plainly when the combination cannot be used.

/// A store whose writes never finish until the test says so, which is the
/// window the dialog has to hold the door shut for.
class _SlowStore implements KeyboardShortcutPreferences {
  final InMemoryKeyboardShortcutPreferences _inner =
      InMemoryKeyboardShortcutPreferences();
  final Completer<void> _write = Completer<void>();

  /// When set, the held write fails instead of completing.
  bool fail = false;

  /// When set, [clear] throws the way a failing preferences plugin would.
  bool failClear = false;

  void finishWrite() => _write.complete();

  @override
  Future<Map<String, String>> overrides() => _inner.overrides();

  @override
  Future<void> setOverride(String storageKey, String? binding) async {
    await _write.future;
    if (fail) throw StateError('storage is unavailable');
    await _inner.setOverride(storageKey, binding);
  }

  @override
  Future<void> clear() async {
    if (failClear) throw StateError('storage is unavailable');
    await _inner.clear();
  }
}

Future<InMemoryKeyboardShortcutPreferences> _pumpCard(
  WidgetTester tester, {
  Map<String, String> stored = const <String, String>{},
}) async {
  final InMemoryKeyboardShortcutPreferences store =
      InMemoryKeyboardShortcutPreferences(initialOverrides: stored);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        keyboardShortcutPreferencesProvider.overrideWithValue(store),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: KeyboardShortcutsSettingsSection(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

/// Opens the recorder for [label] and types [key] with [modifier] held.
Future<void> _record(
  WidgetTester tester,
  String label,
  LogicalKeyboardKey key, {
  LogicalKeyboardKey? modifier = LogicalKeyboardKey.controlLeft,
}) async {
  await tester.tap(find.byTooltip('Change the $label shortcut'));
  await tester.pumpAndSettle();

  if (modifier != null) await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (modifier != null) await tester.sendKeyUpEvent(modifier);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('every action is listed with what it is bound to',
      (tester) async {
    await _pumpCard(tester);

    for (final ShortcutActionDefinition d in ShortcutActions.definitions) {
      expect(find.text(d.label), findsOneWidget, reason: d.label);
      expect(
        find.text(d.defaultBinding.label),
        findsOneWidget,
        reason: '${d.label} should show ${d.defaultBinding.label}',
      );
    }
  });

  testWidgets('recording a free combination saves it', (tester) async {
    final InMemoryKeyboardShortcutPreferences store = await _pumpCard(tester);

    await _record(tester, 'Library', LogicalKeyboardKey.keyG);
    expect(find.text('Ctrl + G'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Ctrl + G'), findsOneWidget);
    expect(
      await store.overrides(),
      <String, String>{
        'library': const ShortcutBinding(LogicalKeyboardKey.keyG, control: true)
            .storageValue,
      },
    );
  });

  testWidgets('a combination another action has cannot be saved',
      (tester) async {
    await _pumpCard(tester);

    // Ctrl+K is Search's.
    await _record(tester, 'Library', LogicalKeyboardKey.keyK);

    expect(find.text('Already used by Search.'), findsOneWidget);
    final FilledButton save = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Save'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(save.onPressed, isNull, reason: 'Save must be unavailable');
  });

  testWidgets('a bare key is refused, and says what to do about it',
      (tester) async {
    await _pumpCard(tester);

    await _record(tester, 'Library', LogicalKeyboardKey.keyG, modifier: null);

    expect(find.textContaining('Add Ctrl'), findsOneWidget);
  });

  testWidgets('a media key is refused as the desktop\'s business',
      (tester) async {
    await _pumpCard(tester);

    await _record(
      tester,
      'Play / pause',
      LogicalKeyboardKey.mediaPlayPause,
      modifier: null,
    );

    // Scoped to the dialog: the card's own caption also mentions media keys,
    // which is the point — the same rule, said once as guidance and once as a
    // refusal.
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('Media keys'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('holding only a modifier waits instead of complaining',
      (tester) async {
    await _pumpCard(tester);

    await tester.tap(find.byTooltip('Change the Library shortcut'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.text('Press the keys you want to use'), findsOneWidget);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });

  testWidgets('cancelling changes nothing', (tester) async {
    final InMemoryKeyboardShortcutPreferences store = await _pumpCard(tester);

    await _record(tester, 'Library', LogicalKeyboardKey.keyG);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Ctrl + L'), findsOneWidget);
    expect(await store.overrides(), isEmpty);
  });

  group('reset', () {
    testWidgets('a row can only be reset when it has been changed',
        (tester) async {
      await _pumpCard(tester);

      IconButton resetFor(String label) => tester.widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('Reset $label to its default'),
              matching: find.byType(IconButton),
            ),
          );

      expect(resetFor('Library').onPressed, isNull);

      await _record(tester, 'Library', LogicalKeyboardKey.keyG);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(resetFor('Library').onPressed, isNotNull);
    });

    testWidgets('resetting a row puts its default back', (tester) async {
      final InMemoryKeyboardShortcutPreferences store = await _pumpCard(tester);

      await _record(tester, 'Library', LogicalKeyboardKey.keyG);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Reset Library to its default'));
      await tester.pumpAndSettle();

      expect(find.text('Ctrl + L'), findsOneWidget);
      expect(find.text('Ctrl + G'), findsNothing);
      expect(await store.overrides(), isEmpty);
    });

    testWidgets('a reset the user has made impossible says so instead',
        (tester) async {
      // Library off its default, then Queue parked on the chord Library used
      // to have. Resetting Library now would put two actions on Ctrl+L.
      final InMemoryKeyboardShortcutPreferences store = await _pumpCard(
        tester,
        stored: <String, String>{
          'library':
              const ShortcutBinding(LogicalKeyboardKey.keyG, control: true)
                  .storageValue,
          'queue': const ShortcutBinding(LogicalKeyboardKey.keyL, control: true)
              .storageValue,
        },
      );

      await tester.tap(find.byTooltip('Reset Library to its default'));
      await tester.pumpAndSettle();

      expect(
        find.text('Could not reset Library. Already used by Queue.'),
        findsOneWidget,
      );
      expect(find.text('Ctrl + G'), findsOneWidget, reason: 'nothing moved');
      expect(
        (await store.overrides())['library'],
        const ShortcutBinding(LogicalKeyboardKey.keyG, control: true)
            .storageValue,
      );
    });

    testWidgets('a reset-all that cannot be written says so', (tester) async {
      // The defaults are already showing and the button has gone quiet with
      // them, so without a message the only clue would be the overrides
      // coming back on the next launch.
      // The save itself has to go through; only the clear fails.
      final _SlowStore store = _SlowStore()..finishWrite();
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            keyboardShortcutPreferencesProvider.overrideWithValue(store),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: KeyboardShortcutsSettingsSection(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _record(tester, 'Library', LogicalKeyboardKey.keyG);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      store.failClear = true;

      await tester.tap(find.text('Reset all to defaults'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('could not be written'),
        findsOneWidget,
        reason: 'the failure has to reach the user somehow',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('reset all is offered only when something was changed',
        (tester) async {
      final InMemoryKeyboardShortcutPreferences store = await _pumpCard(tester);

      TextButton resetAll() => tester.widget<TextButton>(
            find.ancestor(
              of: find.text('Reset all to defaults'),
              matching: find.byType(TextButton),
            ),
          );
      expect(resetAll().onPressed, isNull);

      await _record(tester, 'Library', LogicalKeyboardKey.keyG);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(resetAll().onPressed, isNotNull);

      await tester.tap(find.text('Reset all to defaults'));
      await tester.pumpAndSettle();

      expect(await store.overrides(), isEmpty);
      for (final ShortcutActionDefinition d in ShortcutActions.definitions) {
        expect(find.text(d.defaultBinding.label), findsOneWidget);
      }
    });
  });

  group('the recorder stays escapable', () {
    testWidgets('Tab moves the keyboard on instead of being recorded',
        (tester) async {
      await _pumpCard(tester);
      await tester.tap(find.byTooltip('Change the Library shortcut'));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(
        find.text('Press the keys you want to use'),
        findsOneWidget,
        reason: 'Tab is reserved, so recording it would only strand the user',
      );
      expect(
        FocusManager.instance.primaryFocus?.context,
        isNotNull,
        reason: 'and the keyboard has to have gone somewhere',
      );

      // Escape still gets out, which is the other half of the same promise.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Press the keys you want to use'), findsNothing);
    });

    testWidgets('and no dismissal gets out from under a pending save',
        (tester) async {
      // The binding is applied the moment Save is pressed; only the write to
      // storage is slow. A Cancel or an Escape in that window would look like
      // it undid something it cannot undo.
      final _SlowStore store = _SlowStore();
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            keyboardShortcutPreferencesProvider.overrideWithValue(store),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: KeyboardShortcutsSettingsSection(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _record(tester, 'Library', LogicalKeyboardKey.keyG);
      await tester.tap(find.text('Save'));
      await tester.pump();

      expect(
        tester
            .widget<TextButton>(
              find.ancestor(
                of: find.text('Cancel'),
                matching: find.byType(TextButton),
              ),
            )
            .onPressed,
        isNull,
        reason: 'Cancel is off while the write is in flight',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Save'), findsOneWidget, reason: 'Escape is held too');

      store.finishWrite();
      await tester.pumpAndSettle();

      expect(find.text('Save'), findsNothing, reason: 'and then it closes');
      expect(await store.overrides(), <String, String>{
        'library': const ShortcutBinding(LogicalKeyboardKey.keyG, control: true)
            .storageValue,
      });
    });

    testWidgets('a write that fails lets the user out again', (tester) async {
      // The door is held shut while `_saving`, so an unhandled failure would
      // have trapped the user in the modal until they restarted the app.
      final _SlowStore store = _SlowStore()..fail = true;
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            keyboardShortcutPreferencesProvider.overrideWithValue(store),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: KeyboardShortcutsSettingsSection(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _record(tester, 'Library', LogicalKeyboardKey.keyG);
      await tester.tap(find.text('Save'));
      await tester.pump();
      store.finishWrite();
      await tester.pumpAndSettle();

      expect(
        find.text('Could not save this. It will work until you restart.'),
        findsOneWidget,
      );
      // And the way out is open again, by either route.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Save'), findsNothing);
      // The binding is live for this session even though the write failed.
      expect(find.text('Ctrl + G'), findsOneWidget);
    });

    testWidgets('Save cannot be pressed twice', (tester) async {
      final InMemoryKeyboardShortcutPreferences store = await _pumpCard(tester);

      await _record(tester, 'Library', LogicalKeyboardKey.keyG);
      // Two taps inside one frame, the way an impatient double-click arrives.
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.ancestor(
                of: find.text('Save'),
                matching: find.byType(FilledButton),
              ),
            )
            .onPressed,
        isNull,
        reason: 'the write is already on its way',
      );
      await tester.pumpAndSettle();

      expect(find.text('Save'), findsNothing, reason: 'the dialog closed');
      expect(await store.overrides(), <String, String>{
        'library': const ShortcutBinding(LogicalKeyboardKey.keyG, control: true)
            .storageValue,
      });
    });
  });

  testWidgets('a long chord does not push the row off a narrow window',
      (tester) async {
    // 420 px is the narrowest window Linthra supports, and every modifier at
    // once on a long key name is a combination the rules accept.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 900);
    addTearDown(tester.view.reset);
    await _pumpCard(
      tester,
      stored: <String, String>{
        'library': const ShortcutBinding(
          LogicalKeyboardKey.pageDown,
          control: true,
          shift: true,
          alt: true,
          meta: true,
        ).storageValue,
      },
    );

    expect(tester.takeException(), isNull);
    // The controls have to stay reachable: a clipped reset button would trap
    // the user on the very binding that caused the overflow.
    for (final String tooltip in <String>[
      'Change the Library shortcut',
      'Reset Library to its default',
    ]) {
      final Rect rect = tester.getRect(find.byTooltip(tooltip));
      expect(rect.right, lessThanOrEqualTo(420), reason: tooltip);
      expect(rect.left, greaterThanOrEqualTo(0), reason: tooltip);
    }
  });

  testWidgets('a stored override is what the card shows', (tester) async {
    await _pumpCard(
      tester,
      stored: <String, String>{
        'queue': const ShortcutBinding(LogicalKeyboardKey.keyJ, control: true)
            .storageValue,
      },
    );

    expect(find.text('Ctrl + J'), findsOneWidget);
    expect(find.text('Ctrl + U'), findsNothing);
  });

  testWidgets('the card says media keys are not its business', (tester) async {
    await _pumpCard(tester);
    expect(find.textContaining('Media keys are handled'), findsOneWidget);
  });
}
