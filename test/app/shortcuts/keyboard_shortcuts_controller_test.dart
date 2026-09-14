import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/shortcuts/keyboard_shortcuts_controller.dart';
import 'package:linthra/app/shortcuts/shortcut_action.dart';
import 'package:linthra/app/shortcuts/shortcut_binding.dart';
import 'package:linthra/core/repositories/keyboard_shortcut_preferences.dart';
import 'package:linthra/data/repositories/in_memory_keyboard_shortcut_preferences.dart';
import 'package:linthra/data/repositories/keyboard_shortcut_preferences_provider.dart';

/// Remapping, refusing, remembering and resetting (#391).
///
/// The controller is the only thing that composes defaults with what the user
/// saved, so this is where "my shortcut came back after a restart" and "it let
/// me bind two actions to the same keys" are either true or not.

const ShortcutBinding _ctrlG =
    ShortcutBinding(LogicalKeyboardKey.keyG, control: true);
const ShortcutBinding _ctrlK =
    ShortcutBinding(LogicalKeyboardKey.keyK, control: true);
const ShortcutBinding _ctrlF =
    ShortcutBinding(LogicalKeyboardKey.keyF, control: true);
const ShortcutBinding _bareG = ShortcutBinding(LogicalKeyboardKey.keyG);

/// A container over [store], so a test can build a *second* one on the same
/// storage — which is what "survives a restart" actually means.
ProviderContainer _container(KeyboardShortcutPreferences store) {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      keyboardShortcutPreferencesProvider.overrideWithValue(store),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<KeyboardShortcutsController> _ready(ProviderContainer container) async {
  await container.read(keyboardShortcutsControllerProvider.future);
  return container.read(keyboardShortcutsControllerProvider.notifier);
}

void main() {
  test('with nothing saved, every action is on its default', () async {
    final ProviderContainer container =
        _container(InMemoryKeyboardShortcutPreferences());
    final KeyboardShortcutsController controller = await _ready(container);

    expect(controller.current, ShortcutActions.defaults);
    for (final ShortcutAction action in ShortcutAction.values) {
      expect(controller.isOverridden(action), isFalse);
    }
  });

  test('a remap is applied and reported as applied', () async {
    final ProviderContainer container =
        _container(InMemoryKeyboardShortcutPreferences());
    final KeyboardShortcutsController controller = await _ready(container);

    final ShortcutUpdateResult result =
        await controller.setBinding(ShortcutAction.library, _ctrlG);

    expect(result.isApplied, isTrue);
    expect(result.message, isNull);
    expect(controller.current[ShortcutAction.library], _ctrlG);
    expect(controller.isOverridden(ShortcutAction.library), isTrue);
  });

  test('a remap survives a restart', () async {
    final InMemoryKeyboardShortcutPreferences store =
        InMemoryKeyboardShortcutPreferences();

    final KeyboardShortcutsController first = await _ready(_container(store));
    await first.setBinding(ShortcutAction.library, _ctrlG);

    // A second container over the same storage is what a relaunch looks like.
    final KeyboardShortcutsController restarted =
        await _ready(_container(store));

    expect(restarted.current[ShortcutAction.library], _ctrlG);
    expect(restarted.isOverridden(ShortcutAction.library), isTrue);
    // And nothing else moved.
    expect(
      restarted.current[ShortcutAction.search],
      ShortcutActions.definitionFor(ShortcutAction.search).defaultBinding,
    );
  });

  test('only the overrides are stored, never the whole table', () async {
    final InMemoryKeyboardShortcutPreferences store =
        InMemoryKeyboardShortcutPreferences();
    final KeyboardShortcutsController controller = await _ready(
      _container(store),
    );

    await controller.setBinding(ShortcutAction.library, _ctrlG);

    // So that changing a default in a later release reaches everyone who never
    // disagreed with it.
    expect(await store.overrides(), <String, String>{
      'library': _ctrlG.storageValue,
    });
  });

  test('typing the original combination back removes the override', () async {
    final InMemoryKeyboardShortcutPreferences store =
        InMemoryKeyboardShortcutPreferences();
    final KeyboardShortcutsController controller = await _ready(
      _container(store),
    );
    final ShortcutBinding original =
        ShortcutActions.definitionFor(ShortcutAction.library).defaultBinding;

    await controller.setBinding(ShortcutAction.library, _ctrlG);
    await controller.setBinding(ShortcutAction.library, original);

    expect(await store.overrides(), isEmpty);
    expect(controller.isOverridden(ShortcutAction.library), isFalse);
  });

  group('refusals', () {
    test('an invalid combination is refused, with the reason', () async {
      final ProviderContainer container =
          _container(InMemoryKeyboardShortcutPreferences());
      final KeyboardShortcutsController controller = await _ready(container);

      final ShortcutUpdateResult result =
          await controller.setBinding(ShortcutAction.library, _bareG);

      expect(result.status, ShortcutUpdateStatus.invalid);
      expect(result.problem, ShortcutBindingProblem.needsModifier);
      expect(result.message, contains('Ctrl'));
      expect(
        controller.current[ShortcutAction.library],
        isNot(_bareG),
        reason: 'a refused binding must not be applied anyway',
      );
    });

    test('a media key is refused as MPRIS territory', () async {
      final ProviderContainer container =
          _container(InMemoryKeyboardShortcutPreferences());
      final KeyboardShortcutsController controller = await _ready(container);

      final ShortcutUpdateResult result = await controller.setBinding(
        ShortcutAction.playPause,
        const ShortcutBinding(LogicalKeyboardKey.mediaPlayPause),
      );

      expect(result.status, ShortcutUpdateStatus.invalid);
      expect(result.problem, ShortcutBindingProblem.mediaKey);
      expect(result.message, contains('desktop'));
    });

    test('a combination another action has is refused, and names it', () async {
      final ProviderContainer container =
          _container(InMemoryKeyboardShortcutPreferences());
      final KeyboardShortcutsController controller = await _ready(container);

      // Ctrl+K is search's default.
      final ShortcutUpdateResult result =
          await controller.setBinding(ShortcutAction.library, _ctrlK);

      expect(result.status, ShortcutUpdateStatus.conflict);
      expect(result.conflictsWith, ShortcutAction.search);
      expect(result.message, 'Already used by Search.');
      expect(controller.current[ShortcutAction.library], isNot(_ctrlK));
    });

    test('a fixed alias counts as taken', () async {
      final ProviderContainer container =
          _container(InMemoryKeyboardShortcutPreferences());
      final KeyboardShortcutsController controller = await _ready(container);

      // Ctrl+F is not search's *binding*, it is its always-on alias. Binding
      // something else to it would quietly stop search answering it.
      final ShortcutUpdateResult result =
          await controller.setBinding(ShortcutAction.queue, _ctrlF);

      expect(result.status, ShortcutUpdateStatus.conflict);
      expect(result.conflictsWith, ShortcutAction.search);
    });

    test('rebinding an action to what it already has is fine', () async {
      final ProviderContainer container =
          _container(InMemoryKeyboardShortcutPreferences());
      final KeyboardShortcutsController controller = await _ready(container);

      final ShortcutUpdateResult result =
          await controller.setBinding(ShortcutAction.search, _ctrlK);

      expect(result.isApplied, isTrue,
          reason: 'an action cannot conflict with itself');
    });

    test('a combination freed by a remap becomes available', () async {
      final ProviderContainer container =
          _container(InMemoryKeyboardShortcutPreferences());
      final KeyboardShortcutsController controller = await _ready(container);

      await controller.setBinding(ShortcutAction.search, _ctrlG);
      final ShortcutUpdateResult result =
          await controller.setBinding(ShortcutAction.library, _ctrlK);

      expect(result.isApplied, isTrue);
      expect(controller.current[ShortcutAction.library], _ctrlK);
    });
  });

  group('reset', () {
    test('one action goes back, and forgets its stored override', () async {
      final InMemoryKeyboardShortcutPreferences store =
          InMemoryKeyboardShortcutPreferences();
      final KeyboardShortcutsController controller = await _ready(
        _container(store),
      );

      await controller.setBinding(ShortcutAction.library, _ctrlG);
      await controller.resetToDefault(ShortcutAction.library);

      expect(
        controller.current[ShortcutAction.library],
        ShortcutActions.definitionFor(ShortcutAction.library).defaultBinding,
      );
      expect(controller.isOverridden(ShortcutAction.library), isFalse);
      expect(await store.overrides(), isEmpty);
    });

    test('resetting everything leaves the stock table', () async {
      final InMemoryKeyboardShortcutPreferences store =
          InMemoryKeyboardShortcutPreferences();
      final KeyboardShortcutsController controller = await _ready(
        _container(store),
      );

      await controller.setBinding(ShortcutAction.library, _ctrlG);
      await controller.setBinding(
        ShortcutAction.queue,
        const ShortcutBinding(LogicalKeyboardKey.keyJ, control: true),
      );
      await controller.resetAll();

      expect(controller.current, ShortcutActions.defaults);
      expect(await store.overrides(), isEmpty);
    });

    test('a reset survives a restart too', () async {
      final InMemoryKeyboardShortcutPreferences store =
          InMemoryKeyboardShortcutPreferences();
      final KeyboardShortcutsController controller = await _ready(
        _container(store),
      );
      await controller.setBinding(ShortcutAction.library, _ctrlG);
      await controller.resetAll();

      final KeyboardShortcutsController restarted =
          await _ready(_container(store));
      expect(restarted.current, ShortcutActions.defaults);
    });
  });

  group('storage that cannot be trusted', () {
    test('an unparseable override falls back to the default', () async {
      final KeyboardShortcutsController controller = await _ready(
        _container(
          InMemoryKeyboardShortcutPreferences(
            initialOverrides: <String, String>{'library': 'not-a-binding'},
          ),
        ),
      );

      expect(
        controller.current[ShortcutAction.library],
        ShortcutActions.definitionFor(ShortcutAction.library).defaultBinding,
      );
    });

    test('an override today\'s rules would refuse falls back too', () async {
      final KeyboardShortcutsController controller = await _ready(
        _container(
          InMemoryKeyboardShortcutPreferences(
            initialOverrides: <String, String>{
              'library': _bareG.storageValue,
            },
          ),
        ),
      );

      expect(
        controller.current[ShortcutAction.library],
        ShortcutActions.definitionFor(ShortcutAction.library).defaultBinding,
      );
    });

    test('an override for an action that no longer exists is ignored',
        () async {
      final KeyboardShortcutsController controller = await _ready(
        _container(
          InMemoryKeyboardShortcutPreferences(
            initialOverrides: <String, String>{
              'from_a_newer_build': _ctrlG.storageValue,
              'library': _ctrlG.storageValue,
            },
          ),
        ),
      );

      expect(controller.current[ShortcutAction.library], _ctrlG);
      expect(controller.current.length, ShortcutAction.values.length);
    });
  });
}
