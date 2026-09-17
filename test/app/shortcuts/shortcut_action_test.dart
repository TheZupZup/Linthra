import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/shortcuts/shortcut_action.dart';
import 'package:linthra/app/shortcuts/shortcut_binding.dart';
import 'package:linthra/app/shortcuts/shortcut_intents.dart';

/// The registry has to stay honest on its own, because everything else reads
/// it: the dispatcher installs it, settings edits it, storage keys off it, and
/// the help window (#392) prints it. A default that collided with another,
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

  test('#392\'s help window is an action of its own, on the conventional key',
      () {
    // The window is opened through the registry rather than by a chord wired
    // into the widget, which is what makes it listed, remappable, and
    // impossible to bind something else over.
    final ShortcutActionDefinition definition =
        ShortcutActions.definitionFor(ShortcutAction.shortcutsHelp);

    expect(definition.intent, isA<ShowKeyboardShortcutsIntent>());
    expect(
      definition.defaultBinding,
      const ShortcutBinding(LogicalKeyboardKey.slash, control: true),
      reason: 'Ctrl+/ is what people press to ask what the keys are',
    );
    expect(
      conflictsWithTextEditing(definition.defaultBinding),
      isFalse,
      reason: 'it has to answer from inside a search field too',
    );
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
        ShortcutAction.shortcutsHelp: 'shortcuts_help',
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

  test('grouped() lists every action exactly once', () {
    // The help window draws [grouped] and nothing else, so an action missing
    // from it is a shortcut that works and is not documented anywhere.
    final List<ShortcutAction> listed = <ShortcutAction>[
      for (final ShortcutGroupListing listing in ShortcutActions.grouped)
        for (final ShortcutActionDefinition d in listing.actions) d.action,
    ];
    expect(listed.toSet(), ShortcutAction.values.toSet());
    expect(listed.length, ShortcutAction.values.length,
        reason: 'an action is listed under two headings');
  });

  test('grouped() is deterministic: enum order outside, registry order in', () {
    final List<ShortcutGroupListing> grouped = ShortcutActions.grouped;

    expect(
      grouped.map((ShortcutGroupListing l) => l.group).toList(),
      <ShortcutGroup>[
        for (final ShortcutGroup group in ShortcutGroup.values)
          if (ShortcutActions.definitions
              .any((ShortcutActionDefinition d) => d.group == group))
            group,
      ],
      reason: 'headings must follow the enum, not map iteration order',
    );

    for (final ShortcutGroupListing listing in grouped) {
      expect(listing.actions, isNotEmpty, reason: 'empty heading drawn');
      final List<int> registryPositions = <int>[
        for (final ShortcutActionDefinition d in listing.actions)
          ShortcutActions.definitions.indexOf(d),
      ];
      final List<int> sorted = List<int>.from(registryPositions)..sort();
      expect(registryPositions, sorted,
          reason: '${listing.group.label} reorders the registry');
    }
  });

  test('two runs of grouped() agree', () {
    // It is a getter that rebuilds the list every call; two help windows
    // opened in one session must not disagree about the order.
    List<String> shape() {
      return <String>[
        for (final ShortcutGroupListing listing in ShortcutActions.grouped)
          '${listing.group.name}: '
              '${listing.actions.map(
                    (ShortcutActionDefinition d) => d.action.name,
                  ).join(',')}',
      ];
    }

    expect(shape(), shape());
  });

  test('every group has a heading a person can read', () {
    for (final ShortcutGroup group in ShortcutGroup.values) {
      expect(group.label, isNotEmpty, reason: group.name);
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
