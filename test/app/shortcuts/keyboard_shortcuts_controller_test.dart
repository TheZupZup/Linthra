import 'dart:async';

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

/// A combination nothing ships with, for tests that just need a free one.
const ShortcutBinding _ctrlJ =
    ShortcutBinding(LogicalKeyboardKey.keyJ, control: true);

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

/// A store that can be held mid-write, fail one, and say what order it saw.
class _SlowStore implements KeyboardShortcutPreferences {
  final InMemoryKeyboardShortcutPreferences _inner =
      InMemoryKeyboardShortcutPreferences();
  final List<String> order = <String>[];
  Completer<void>? _gate;
  bool failNextWrite = false;

  set slow(bool value) => _gate = value ? Completer<void>() : null;

  void release() {
    final Completer<void>? gate = _gate;
    _gate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  Future<void> _wait() async {
    final Completer<void>? gate = _gate;
    if (gate != null) await gate.future;
  }

  @override
  Future<Map<String, String>> overrides() => _inner.overrides();

  @override
  Future<void> setOverride(String storageKey, String? binding) async {
    await _wait();
    order.add('set:$storageKey');
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('storage is unavailable');
    }
    await _inner.setOverride(storageKey, binding);
  }

  @override
  Future<void> clear() async {
    await _wait();
    order.add('clear');
    await _inner.clear();
  }
}

/// No two actions may end up on the same combination, whatever storage said.
void _expectNoDuplicates(Map<ShortcutAction, ShortcutBinding> table) {
  expect(
    table.values.toSet().length,
    table.length,
    reason: 'two actions share a chord: $table',
  );
  for (final MapEntry<ShortcutAction, ShortcutBinding> entry in table.entries) {
    final ShortcutAction? alias = ShortcutActions.actionWithAlias(entry.value);
    expect(
      alias == null || alias == entry.key,
      isTrue,
      reason: '${entry.key} sits on $alias\'s fixed alias',
    );
  }
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

    test('a reset that would collide is refused, and names the blocker',
        () async {
      final InMemoryKeyboardShortcutPreferences store =
          InMemoryKeyboardShortcutPreferences();
      final KeyboardShortcutsController controller = await _ready(
        _container(store),
      );
      final ShortcutBinding libraryDefault =
          ShortcutActions.definitionFor(ShortcutAction.library).defaultBinding;

      // Move Library off its default, then park Queue on the vacated chord.
      await controller.setBinding(ShortcutAction.library, _ctrlG);
      await controller.setBinding(ShortcutAction.queue, libraryDefault);

      final ShortcutUpdateResult result =
          await controller.resetToDefault(ShortcutAction.library);

      expect(result.status, ShortcutUpdateStatus.conflict);
      expect(result.conflictsWith, ShortcutAction.queue);
      expect(result.message, 'Already used by Queue.');
      // Nothing moved: two actions on one chord is the outcome being avoided.
      expect(controller.current[ShortcutAction.library], _ctrlG);
      expect(controller.current[ShortcutAction.queue], libraryDefault);
    });

    test('and goes through once the blocker moves away', () async {
      final KeyboardShortcutsController controller = await _ready(
        _container(InMemoryKeyboardShortcutPreferences()),
      );
      final ShortcutBinding libraryDefault =
          ShortcutActions.definitionFor(ShortcutAction.library).defaultBinding;

      await controller.setBinding(ShortcutAction.library, _ctrlG);
      await controller.setBinding(ShortcutAction.queue, libraryDefault);
      await controller.setBinding(
        ShortcutAction.queue,
        const ShortcutBinding(LogicalKeyboardKey.keyJ, control: true),
      );

      final ShortcutUpdateResult result =
          await controller.resetToDefault(ShortcutAction.library);

      expect(result.isApplied, isTrue);
      expect(controller.current[ShortcutAction.library], libraryDefault);
      expect(controller.isOverridden(ShortcutAction.library), isFalse);
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

  group('writes are serialized', () {
    test('a rebinding started during reset-all is not erased by it', () async {
      // The controller publishes before it writes, so both were in flight at
      // once; `clear()` deletes the keys it snapshotted when it began, and a
      // `setOverride` landing in the middle of one used to be deleted by it.
      final _SlowStore store = _SlowStore();
      final KeyboardShortcutsController controller = await _ready(
        _container(store),
      );
      await controller.setBinding(ShortcutAction.library, _ctrlG);
      store.order.clear();
      store.slow = true;

      final Future<void> reset = controller.resetAll();
      final Future<ShortcutUpdateResult> rebind =
          controller.setBinding(ShortcutAction.library, _ctrlJ);
      store.release();
      await Future.wait<void>(<Future<void>>[reset, rebind]);

      expect(controller.current[ShortcutAction.library], _ctrlJ);
      expect(
        await store.overrides(),
        <String, String>{'library': _ctrlJ.storageValue},
        reason: 'the write the user made last is the one on disk',
      );
      expect(
        store.order,
        <String>['clear', 'set:library'],
        reason: 'and the store saw them one at a time, in that order',
      );
    });

    test('a failed write does not wedge the ones behind it', () async {
      final _SlowStore store = _SlowStore()..failNextWrite = true;
      final KeyboardShortcutsController controller = await _ready(
        _container(store),
      );

      await expectLater(
        controller.setBinding(ShortcutAction.library, _ctrlG),
        throwsA(isA<StateError>()),
      );
      await controller.setBinding(ShortcutAction.library, _ctrlJ);

      expect(
        await store.overrides(),
        <String, String>{'library': _ctrlJ.storageValue},
      );
    });
  });

  group('storage that cannot be trusted', () {
    test('a key with no Flutter constant survives a restart', () async {
      // A character a non-US layout produces arrives as a Unicode-plane key
      // that `findKeyByKeyId` does not know. It recorded and dispatched fine
      // and then came back as the default on the next launch.
      const LogicalKeyboardKey accented =
          LogicalKeyboardKey(0xe9 | LogicalKeyboardKey.unicodePlane);
      expect(
        LogicalKeyboardKey.findKeyByKeyId(accented.keyId),
        isNull,
        reason: 'the premise: Flutter has no constant for this one',
      );
      const ShortcutBinding binding = ShortcutBinding(accented, control: true);
      expect(binding.isValid, isTrue);

      final InMemoryKeyboardShortcutPreferences store =
          InMemoryKeyboardShortcutPreferences();
      final KeyboardShortcutsController controller = await _ready(
        _container(store),
      );
      await controller.setBinding(ShortcutAction.library, binding);

      final KeyboardShortcutsController restarted =
          await _ready(_container(store));
      expect(restarted.current[ShortcutAction.library], binding);
    });

    test('an id from a plane this build knows nothing about is dropped',
        () async {
      final KeyboardShortcutsController controller = await _ready(
        _container(
          InMemoryKeyboardShortcutPreferences(
            initialOverrides: <String, String>{
              // Not a real key: a plane Flutter does not define, which is a
              // value to fall back from rather than to guess at.
              'library': 'ctrl+${0xfe00000000 | 0x41}',
            },
          ),
        ),
      );

      expect(
        controller.current[ShortcutAction.library],
        ShortcutActions.definitionFor(ShortcutAction.library).defaultBinding,
      );
    });

    test('an override that collides with a default is dropped', () async {
      // Queue parked on Search's default. Nothing in the app writes this, but
      // a hand-edited file or one from a newer build can, and the activator
      // map would otherwise hand Ctrl+K to whichever came first and leave the
      // other showing a chord that does nothing.
      final KeyboardShortcutsController controller = await _ready(
        _container(
          InMemoryKeyboardShortcutPreferences(
            initialOverrides: <String, String>{'queue': _ctrlK.storageValue},
          ),
        ),
      );

      expect(controller.current[ShortcutAction.search], _ctrlK);
      expect(
        controller.current[ShortcutAction.queue],
        ShortcutActions.definitionFor(ShortcutAction.queue).defaultBinding,
      );
      _expectNoDuplicates(controller.current);
    });

    test('and one that collides with a fixed alias goes the same way',
        () async {
      final KeyboardShortcutsController controller = await _ready(
        _container(
          InMemoryKeyboardShortcutPreferences(
            // Ctrl+F is Search's alias, so Queue can never really have it.
            initialOverrides: <String, String>{'queue': _ctrlF.storageValue},
          ),
        ),
      );

      expect(
        controller.current[ShortcutAction.queue],
        ShortcutActions.definitionFor(ShortcutAction.queue).defaultBinding,
      );
    });

    test('two overrides on one chord leave the first claimant holding it',
        () async {
      final KeyboardShortcutsController controller = await _ready(
        _container(
          InMemoryKeyboardShortcutPreferences(
            initialOverrides: <String, String>{
              'search': _ctrlG.storageValue,
              'queue': _ctrlG.storageValue,
            },
          ),
        ),
      );

      expect(controller.current[ShortcutAction.search], _ctrlG);
      expect(
        controller.current[ShortcutAction.queue],
        ShortcutActions.definitionFor(ShortcutAction.queue).defaultBinding,
      );
      _expectNoDuplicates(controller.current);
    });

    test('a swap written by the settings screen survives intact', () async {
      // Both halves move onto the chord the other is leaving. Checking one
      // override at a time against the defaults would have refused both and
      // quietly undone a configuration the user really made.
      final ShortcutBinding searchDefault =
          ShortcutActions.definitionFor(ShortcutAction.search).defaultBinding;
      final ShortcutBinding queueDefault =
          ShortcutActions.definitionFor(ShortcutAction.queue).defaultBinding;
      final KeyboardShortcutsController controller = await _ready(
        _container(
          InMemoryKeyboardShortcutPreferences(
            initialOverrides: <String, String>{
              'search': queueDefault.storageValue,
              'queue': searchDefault.storageValue,
            },
          ),
        ),
      );

      expect(controller.current[ShortcutAction.search], queueDefault);
      expect(controller.current[ShortcutAction.queue], searchDefault);
      _expectNoDuplicates(controller.current);
    });

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
