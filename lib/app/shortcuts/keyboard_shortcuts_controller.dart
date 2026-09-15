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

  /// Storage writes, one after another.
  ///
  /// Every method here publishes its new state first and lets the write
  /// follow, so two of them can be in flight at once: reset-all, and a
  /// rebinding the user started before its clear had finished. The
  /// `shared_preferences` store deletes the keys it snapshotted when its
  /// `clear()` began, so a `setOverride` landing in the middle of one is
  /// deleted by it — the session shows the new chord and the next launch does
  /// not. Chaining means the store only ever sees one write at a time, in the
  /// order the user asked for.
  Future<void> _writes = Future<void>.value();

  Future<void> _write(Future<void> Function() operation) {
    final Future<void> next = _writes.then((_) => operation());
    // The queue must survive a failed write, so the chain everything else
    // waits on swallows the error; the caller still sees it through [next].
    _writes = next.catchError((Object _) {});
    return next;
  }

  @override
  Future<Map<ShortcutAction, ShortcutBinding>> build() async {
    return _compose(await _store.overrides());
  }

  static Map<ShortcutAction, ShortcutBinding> _compose(
    Map<String, String> overrides,
  ) {
    // Parsed together, then applied together: the settings screen legitimately
    // writes a *swap*, where each action moves onto the chord the other is
    // leaving, and applying one at a time against the defaults would refuse
    // both halves of it.
    final Map<ShortcutAction, ShortcutBinding> stored =
        <ShortcutAction, ShortcutBinding>{};
    for (final ShortcutActionDefinition definition
        in ShortcutActions.definitions) {
      final ShortcutBinding? parsed =
          ShortcutBinding.parse(overrides[definition.storageKey]);
      if (parsed != null) stored[definition.action] = parsed;
    }

    // What storage cannot be trusted about is the table as a whole. A file
    // from a newer build, or one edited by hand, can name one chord twice, and
    // the activator map would then silently hand it to whichever action comes
    // first — leaving the other one displayed in settings and dead on the
    // keyboard. The override is the untrusted half, so it is the half that
    // goes; one at a time, because giving an action its default back can
    // collide with the next override in turn.
    while (true) {
      final ShortcutAction? offender = _firstUnusableOverride(stored);
      if (offender == null) break;
      stored.remove(offender);
    }

    return ShortcutActions.defaults..addAll(stored);
  }

  /// The first override in registry order that wants a chord something else
  /// already has, or null when the table is unambiguous.
  ///
  /// The *first* claim keeps the chord, so which override survives a duplicate
  /// does not depend on how the file happened to be written. An action with no
  /// override cannot be the offender: its default is the behaviour being
  /// fallen back to.
  static ShortcutAction? _firstUnusableOverride(
    Map<ShortcutAction, ShortcutBinding> stored,
  ) {
    final Map<ShortcutAction, ShortcutBinding> table = ShortcutActions.defaults
      ..addAll(stored);
    final Map<ShortcutBinding, ShortcutAction> claimed =
        <ShortcutBinding, ShortcutAction>{};
    for (final ShortcutActionDefinition definition
        in ShortcutActions.definitions) {
      final ShortcutBinding binding = table[definition.action]!;
      final ShortcutAction? owner =
          claimed[binding] ?? ShortcutActions.actionWithAlias(binding);
      if (owner != null && owner != definition.action) {
        if (stored.containsKey(definition.action)) return definition.action;
        if (stored.containsKey(owner)) return owner;
      }
      claimed.putIfAbsent(binding, () => definition.action);
    }
    return null;
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
    await _write(
      () => _store.setOverride(
        definition.storageKey,
        binding == definition.defaultBinding ? null : binding.storageValue,
      ),
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

  /// Returns one action to its default, or explains why it cannot.
  ///
  /// It goes through [setBinding] rather than writing the default straight in,
  /// because a default is not automatically free: remap Library off Ctrl+L,
  /// give Ctrl+L to Queue, and resetting Library would have put two actions on
  /// one chord, with the activator map silently handing it to whichever came
  /// first in the registry. Refusing says which action is in the way, and the
  /// user can move that one and try again.
  ///
  /// [resetAll] needs no such check: the shipped defaults are distinct by
  /// construction, and a test holds them to it.
  Future<ShortcutUpdateResult> resetToDefault(ShortcutAction action) {
    return setBinding(
      action,
      ShortcutActions.definitionFor(action).defaultBinding,
    );
  }

  /// Returns every action to its default, forgetting all overrides.
  Future<void> resetAll() async {
    state = AsyncData<Map<ShortcutAction, ShortcutBinding>>(
      ShortcutActions.defaults,
    );
    await _write(_store.clear);
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
