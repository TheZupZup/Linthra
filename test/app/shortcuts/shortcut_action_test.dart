import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/shortcuts/shortcut_action.dart';
import 'package:linthra/app/shortcuts/shortcut_binding.dart';

/// The registry has to stay honest on its own, because everything else reads
/// it: the dispatcher installs it, settings edits it, storage keys off it, and
/// the help window in #392 will print it. A default that collided with another,
/// or a storage key that moved with an enum reorder, would be a bug nobody sees
/// until somebody's shortcut quietly starts doing the wrong thing.

void main() {
  test('every action has exactly one definition', () {
    expect(
      ShortcutActions.definitions.length,
      ShortcutAction.values.length,
      reason: 'an action was added to the enum but not to the registry',
    );
    for (final ShortcutAction action in ShortcutAction.values) {
      expect(
        ShortcutActions.definitions
            .where((ShortcutActionDefinition d) => d.action == action)
            .length,
        1,
        reason: '$action',
      );
    }
  });

  test('the issue\'s required actions are all covered', () {
    // #391 names these by hand; they are the reason the feature exists.
    for (final ShortcutAction action in <ShortcutAction>[
      ShortcutAction.playPause,
      ShortcutAction.next,
      ShortcutAction.previous,
      ShortcutAction.search,
      ShortcutAction.library,
      ShortcutAction.queue,
      ShortcutAction.nowPlaying,
    ]) {
      expect(ShortcutActions.definitionFor(action), isNotNull);
    }
  });

  test('storage keys are unique', () {
    final Set<String> keys = <String>{};
    for (final ShortcutActionDefinition d in ShortcutActions.definitions) {
      expect(keys.add(d.storageKey), isTrue,
          reason: 'duplicate ${d.storageKey}');
      expect(d.storageKey, isNotEmpty);
    }
  });

  test('storage keys are pinned, so an existing install keeps its shortcuts',
      () {
    // Written out rather than derived. If a rename or a reorder moves one of
    // these, somebody's saved shortcut lands on a different action — or is
    // silently forgotten — and this is the only place that would notice.
    expect(
      <ShortcutAction, String>{
        for (final ShortcutActionDefinition d in ShortcutActions.definitions)
          d.action: d.storageKey,
      },
      <ShortcutAction, String>{
        ShortcutAction.playPause: 'play_pause',
        ShortcutAction.next: 'next',
        ShortcutAction.previous: 'previous',
        ShortcutAction.search: 'search',
        ShortcutAction.library: 'library',
        ShortcutAction.queue: 'queue',
        ShortcutAction.nowPlaying: 'now_playing',
      },
    );
  });

  test('every default is a binding the app would accept', () {
    for (final ShortcutActionDefinition d in ShortcutActions.definitions) {
      expect(
        d.defaultBinding.problem,
        isNull,
        reason: '${d.label} ships a default the settings screen would refuse: '
            '${d.defaultBinding.label}',
      );
    }
  });

  test('no two defaults, and no alias, want the same combination', () {
    final Map<ShortcutBinding, String> claimed = <ShortcutBinding, String>{};
    for (final ShortcutActionDefinition d in ShortcutActions.definitions) {
      for (final ShortcutBinding binding in <ShortcutBinding>[
        d.defaultBinding,
        ...d.aliases,
      ]) {
        final String? owner = claimed[binding];
        expect(
          owner,
          isNull,
          reason: '${binding.label} is claimed by both $owner and ${d.label}',
        );
        claimed[binding] = d.label;
      }
    }
  });

  test('no default is bound to a media key', () {
    // Play/pause, next and previous reach Linthra through MPRIS. Binding a
    // media key here would be a second, worse path that only works while the
    // window has focus.
    for (final ShortcutActionDefinition d in ShortcutActions.definitions) {
      expect(
        d.defaultBinding.problem,
        isNot(ShortcutBindingProblem.mediaKey),
        reason: d.label,
      );
    }
  });

  test('nothing takes Ctrl+Q, which quits on Linux', () {
    for (final ShortcutActionDefinition d in ShortcutActions.definitions) {
      for (final ShortcutBinding binding in <ShortcutBinding>[
        d.defaultBinding,
        ...d.aliases,
      ]) {
        expect(binding.label, isNot('Ctrl + Q'), reason: d.label);
      }
    }
  });

  test('an alias is never a key a focused text field would want', () {
    // The dispatcher guards an action by its *primary* binding, so an alias
    // that was a text-editing key would be guarded by the wrong answer.
    for (final ShortcutActionDefinition d in ShortcutActions.definitions) {
      for (final ShortcutBinding alias in d.aliases) {
        expect(conflictsWithTextEditing(alias), isFalse, reason: alias.label);
        expect(alias.problem, isNull, reason: alias.label);
      }
    }
  });

  test('every action is described well enough for a help window', () {
    for (final ShortcutActionDefinition d in ShortcutActions.definitions) {
      expect(d.label, isNotEmpty);
      expect(d.description, isNotEmpty);
      expect(d.description.endsWith('.'), isTrue, reason: d.description);
    }
  });

  test('defaults() hands back every action', () {
    expect(
        ShortcutActions.defaults.keys.toSet(), ShortcutAction.values.toSet());
  });

  test('defaults() hands back a fresh map each time', () {
    // The controller mutates what it gets; a shared const map would leak one
    // user\'s remap into the "defaults" everybody else resets to.
    final map = ShortcutActions.defaults..remove(ShortcutAction.search);
    expect(map.containsKey(ShortcutAction.search), isFalse);
    expect(
      ShortcutActions.defaults.containsKey(ShortcutAction.search),
      isTrue,
    );
  });
}
