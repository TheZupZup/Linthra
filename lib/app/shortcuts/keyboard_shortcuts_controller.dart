import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/keyboard_shortcut_preferences.dart';
import '../../data/repositories/keyboard_shortcut_preferences_provider.dart';
import 'shortcut_action.dart';
import 'shortcut_binding.dart';

/// Why a requested rebinding was refused, or [ShortcutUpdateStatus.applied]
/// when it was not.
enum ShortcutUpdateStatus {
  applied,

  /// The combination itself cannot be a shortcut — see [ShortcutBindingProblem].
  invalid,

  /// Another action already answers this combination.
  conflict,
}

/// The answer to "please bind this", carrying enough to explain a refusal
/// without the caller re-deriving it.
///
/// A result rather than an exception: a user typing a chord into a settings
/// field will hit a conflict routinely, and that is a normal answer to show
/// beside the field, not an error.
@immutable
class ShortcutUpdateResult {
  const ShortcutUpdateResult.applied()
      : status = ShortcutUpdateStatus.applied,
        problem = null,
        conflictsWith = null;

  const ShortcutUpdateResult.invalid(this.problem)
      : status = ShortcutUpdateStatus.invalid,
        conflictsWith = null;

  const ShortcutUpdateResult.conflict(this.conflictsWith)
      : status = ShortcutUpdateStatus.conflict,
        problem = null;

  final ShortcutUpdateStatus status;

  /// Set when [status] is [ShortcutUpdateStatus.invalid].
  final ShortcutBindingProblem? problem;

  /// Set when [status] is [ShortcutUpdateStatus.conflict]: the action that
  /// already has this combination.
  final ShortcutAction? conflictsWith;

  bool get isApplied => status == ShortcutUpdateStatus.applied;

  /// One sentence explaining a refusal, or null when there was none.
  ///
  /// Lives here so the settings screen, and any other surface that ever offers
  /// rebinding, cannot word the same refusal two different ways.
  String? get message {
    switch (status) {
      case ShortcutUpdateStatus.applied:
        return null;
      case ShortcutUpdateStatus.invalid:
        return describeShortcutProblem(problem!);
      case ShortcutUpdateStatus.conflict:
        final String other =
            ShortcutActions.definitionFor(conflictsWith!).label;
        return 'Already used by $other.';
    }
  }
}

/// The live shortcut map: defaults with the user's overrides on top.
///
/// This is the single source the dispatcher binds, the settings screen edits,
/// and the help window planned in #392 will read. Nothing else composes
/// defaults with overrides, so what the app answers and what it says it answers
/// cannot drift apart.
///
/// The map is always complete — every [ShortcutAction] has a binding — so no
/// caller has to handle a missing one. An override that no longer parses, or
/// that today's rules would refuse, is dropped on read and the action keeps its
/// default: a preferences file from a newer build, or one edited by hand,
/// degrades to stock behaviour rather than to a broken keyboard.
class KeyboardShortcutsController
    extends AsyncNotifier<Map<ShortcutAction, ShortcutBinding>> {
  KeyboardShortcutPreferences get _store =>
      ref.read(keyboardShortcutPreferencesProvider);

  @override
  Future<Map<ShortcutAction, ShortcutBinding>> build() async {
    return _compose(await _store.overrides());
  }

  static Map<ShortcutAction, ShortcutBinding> _compose(
    Map<String, String> overrides,
  ) {
    final Map<ShortcutAction, ShortcutBinding> bindings =
        ShortcutActions.defaults;
    for (final ShortcutActionDefinition definition
        in ShortcutActions.definitions) {
      final ShortcutBinding? stored =
          ShortcutBinding.parse(overrides[definition.storageKey]);
      if (stored != null) bindings[definition.action] = stored;
    }
    return bindings;
  }

  /// The bindings as they stand, or the defaults while storage is still being
  /// read.
  ///
  /// The app is usable during that first frame or two, and defaulting is the
  /// right answer for it: a user who has never remapped anything sees exactly
  /// what they will keep seeing, and one who has sees their own binding a
  /// moment later.
  Map<ShortcutAction, ShortcutBinding> get current =>
      state.valueOrNull ?? ShortcutActions.defaults;

  /// Binds [binding] to [action], or explains why it cannot.
  ///
  /// Rebinding to the combination the action already has is applied rather than
  /// reported as a conflict with itself.
  Future<ShortcutUpdateResult> setBinding(
    ShortcutAction action,
    ShortcutBinding binding,
  ) async {
    final ShortcutBindingProblem? problem = binding.problem;
    if (problem != null) return ShortcutUpdateResult.invalid(problem);

    final ShortcutAction? clash = conflictFor(action, binding);
    if (clash != null) return ShortcutUpdateResult.conflict(clash);

    final Map<ShortcutAction, ShortcutBinding> next =
        Map<ShortcutAction, ShortcutBinding>.from(current)..[action] = binding;
    state = AsyncData<Map<ShortcutAction, ShortcutBinding>>(next);
    final ShortcutActionDefinition definition =
        ShortcutActions.definitionFor(action);
    // Written back as null when it matches the default, so a user who
    // remaps and then types the original combination back is left with no
    // override at all — and keeps following the default if a later release
    // changes it.
    await _store.setOverride(
      definition.storageKey,
      binding == definition.defaultBinding ? null : binding.storageValue,
    );
    return const ShortcutUpdateResult.applied();
  }

  /// The action [binding] already belongs to, or null when it is free.
  ///
  /// [action] itself is excluded — an action never conflicts with its own
  /// current binding. Fixed aliases count as occupied, so nothing can be bound
  /// over Ctrl+F and quietly stop search answering it.
  ShortcutAction? conflictFor(ShortcutAction action, ShortcutBinding binding) {
    for (final MapEntry<ShortcutAction, ShortcutBinding> entry
        in current.entries) {
      if (entry.key == action) continue;
      if (entry.value == binding) return entry.key;
    }
    final ShortcutAction? alias = ShortcutActions.actionWithAlias(binding);
    if (alias != null && alias != action) return alias;
    return null;
  }

  /// Returns one action to its default.
  Future<void> resetToDefault(ShortcutAction action) async {
    final ShortcutActionDefinition definition =
        ShortcutActions.definitionFor(action);
    final Map<ShortcutAction, ShortcutBinding> next =
        Map<ShortcutAction, ShortcutBinding>.from(current)
          ..[action] = definition.defaultBinding;
    state = AsyncData<Map<ShortcutAction, ShortcutBinding>>(next);
    await _store.setOverride(definition.storageKey, null);
  }

  /// Returns every action to its default, forgetting all overrides.
  Future<void> resetAll() async {
    state = AsyncData<Map<ShortcutAction, ShortcutBinding>>(
      ShortcutActions.defaults,
    );
    await _store.clear();
  }

  /// Whether [action] is currently on something other than its default, so the
  /// settings row can offer a reset only where there is something to reset.
  bool isOverridden(ShortcutAction action) =>
      current[action] != ShortcutActions.definitionFor(action).defaultBinding;
}

final keyboardShortcutsControllerProvider = AsyncNotifierProvider<
    KeyboardShortcutsController, Map<ShortcutAction, ShortcutBinding>>(
  KeyboardShortcutsController.new,
);

/// The bindings the dispatcher should install right now.
///
/// Separate from the controller so a widget can watch *just the map* and not
/// rebuild on the loading/data transition, and so a test can override the whole
/// set in one line without standing up storage.
final activeShortcutBindingsProvider =
    Provider<Map<ShortcutAction, ShortcutBinding>>((ref) {
  return ref.watch(keyboardShortcutsControllerProvider).valueOrNull ??
      ShortcutActions.defaults;
});
