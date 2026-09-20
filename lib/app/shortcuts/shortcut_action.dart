import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'shortcut_binding.dart';
import 'shortcut_intents.dart';

/// Every action a Linthra keyboard shortcut can run.
///
/// This enum plus [ShortcutActions.definitions] is *the* registry: the defaults,
/// the names a person reads, and the intent each one dispatches all live here
/// and nowhere else. The dispatcher, the settings screen, persistence, and the
/// help window (#392) all read this same table, so a shortcut cannot be
/// documented as one thing and bound as another.
///
/// Deliberately absent: anything a media key does. Play/pause, next and
/// previous reach Linthra from the desktop through MPRIS (#398), which works
/// while the window is not focused and is what the user's keyboard already
/// sends. The entries below are the *in-window* equivalents, bound to ordinary
/// chords; [ShortcutBinding] refuses to bind a media key to any of them.
enum ShortcutAction {
  playPause,
  next,
  previous,
  search,
  library,
  queue,
  nowPlaying,
  shortcutsHelp,
}

/// The heading a shortcut is listed under (#392).
///
/// Part of the registry rather than of the help window, for the same reason
/// the labels and descriptions are: a group is a fact about the action, and a
/// second table mapping actions to headings somewhere else is exactly the
/// drift this feature exists to prevent.
///
/// The order below is the order they are shown in, so the help window's
/// grouping is the enum's and cannot depend on how a map happened to iterate.
enum ShortcutGroup {
  /// What is playing.
  playback('Playback'),

  /// Moving between Linthra's surfaces.
  navigation('Navigation'),

  /// Finding and opening your music. Search is here rather than under
  /// Navigation because what it searches is the library.
  library('Library'),

  /// This window, and anything else that explains the app to you.
  help('Help');

  const ShortcutGroup(this.label);

  /// The heading a person reads.
  final String label;
}

/// One action's fixed facts: what it is called, what it does, and what it is
/// bound to out of the box.
@immutable
class ShortcutActionDefinition {
  const ShortcutActionDefinition({
    required this.action,
    required this.group,
    required this.storageKey,
    required this.label,
    required this.description,
    required this.defaultBinding,
    required this.intent,
    this.aliases = const <ShortcutBinding>[],
  });

  final ShortcutAction action;

  /// The heading the help window lists this action under (#392).
  final ShortcutGroup group;

  /// The stable key this action's override is stored under. Never derived from
  /// the enum's name or index: renaming a value or reordering the enum must not
  /// silently move somebody's saved shortcut onto a different action.
  final String storageKey;

  /// The short name a settings row and the help window show.
  final String label;

  /// One line of what it does, shown in the help window (#392).
  final String description;

  final ShortcutBinding defaultBinding;

  /// The intent dispatched when it fires.
  final Intent intent;

  /// Extra combinations that always work, on top of whatever the user has
  /// bound, and which remapping does not move.
  ///
  /// Exactly one of these exists: Ctrl+F for search, which Linthra has always
  /// answered and which people who grew up on "find" press first. Rebinding
  /// search to something else should not quietly take that away. They still
  /// count as occupied for conflict detection, so nothing else can be bound
  /// over them.
  final List<ShortcutBinding> aliases;
}

/// One heading and the actions under it, as [ShortcutActions.grouped] hands
/// them over.
@immutable
class ShortcutGroupListing {
  const ShortcutGroupListing({required this.group, required this.actions});

  final ShortcutGroup group;

  /// Never empty: a group nothing is filed under is not listed at all.
  final List<ShortcutActionDefinition> actions;
}

/// The registry.
abstract final class ShortcutActions {
  /// Every action's definition, in the order a settings screen lists them:
  /// what is playing, then your music, then where to go, then the window that
  /// explains the lot. The help window reads [grouped] instead, which is this
  /// same list under its headings.
  ///
  /// The defaults avoid three things on purpose. Nothing is bound bare, so no
  /// shortcut can eat a keystroke meant as typing. Nothing uses Ctrl+Q, which
  /// quits on Linux. Nothing uses Escape, which the app needs for closing
  /// dialogs, leaving a selection and dismissing quick search.
  static const List<ShortcutActionDefinition> definitions =
      <ShortcutActionDefinition>[
    ShortcutActionDefinition(
      action: ShortcutAction.playPause,
      group: ShortcutGroup.playback,
      storageKey: 'play_pause',
      label: 'Play / pause',
      description: 'Start or pause whatever is loaded.',
      // Ctrl+Space rather than bare Space: #390 made every button and row
      // keyboard-activatable, and Space is how you activate the focused one.
      defaultBinding: ShortcutBinding(
        LogicalKeyboardKey.space,
        control: true,
      ),
      intent: TogglePlayPauseIntent(),
    ),
    ShortcutActionDefinition(
      action: ShortcutAction.next,
      group: ShortcutGroup.playback,
      storageKey: 'next',
      label: 'Next track',
      description: 'Skip to the next track in the queue.',
      defaultBinding: ShortcutBinding(
        LogicalKeyboardKey.arrowRight,
        control: true,
      ),
      intent: SkipToNextIntent(),
    ),
    ShortcutActionDefinition(
      action: ShortcutAction.previous,
      group: ShortcutGroup.playback,
      storageKey: 'previous',
      label: 'Previous track',
      description: 'Go back to the previous track.',
      defaultBinding: ShortcutBinding(
        LogicalKeyboardKey.arrowLeft,
        control: true,
      ),
      intent: SkipToPreviousIntent(),
    ),
    ShortcutActionDefinition(
      action: ShortcutAction.search,
      group: ShortcutGroup.library,
      storageKey: 'search',
      label: 'Search',
      description: 'Open quick search.',
      defaultBinding: ShortcutBinding(LogicalKeyboardKey.keyK, control: true),
      aliases: <ShortcutBinding>[
        ShortcutBinding(LogicalKeyboardKey.keyF, control: true),
      ],
      intent: OpenQuickSearchIntent(),
    ),
    ShortcutActionDefinition(
      action: ShortcutAction.library,
      group: ShortcutGroup.library,
      storageKey: 'library',
      label: 'Library',
      description: 'Go to the Library tab.',
      defaultBinding: ShortcutBinding(LogicalKeyboardKey.keyL, control: true),
      intent: OpenLibraryIntent(),
    ),
    ShortcutActionDefinition(
      action: ShortcutAction.queue,
      group: ShortcutGroup.navigation,
      storageKey: 'queue',
      label: 'Queue',
      description: 'Show or hide what is up next.',
      defaultBinding: ShortcutBinding(LogicalKeyboardKey.keyU, control: true),
      intent: ToggleQueueIntent(),
    ),
    ShortcutActionDefinition(
      action: ShortcutAction.nowPlaying,
      group: ShortcutGroup.navigation,
      storageKey: 'now_playing',
      label: 'Now Playing',
      description: 'Open the full-screen player.',
      defaultBinding: ShortcutBinding(LogicalKeyboardKey.keyP, control: true),
      intent: OpenNowPlayingIntent(),
    ),
    ShortcutActionDefinition(
      action: ShortcutAction.shortcutsHelp,
      group: ShortcutGroup.help,
      storageKey: 'shortcuts_help',
      // Not "Keyboard shortcuts": that is the name of the settings card this
      // row sits in and of the window it opens, and a row that repeats its own
      // heading says nothing.
      label: 'Shortcut help',
      description: 'Show every shortcut and what it is bound to.',
      // Ctrl+/ is what a decade of web apps have trained people to press for
      // "what are the keys here", and it goes through the registry like every
      // other action rather than being hard-coded into the help window: it is
      // remappable, it is listed, and it cannot be bound over by accident.
      //
      // Shift+/, the "?" people also reach for, is deliberately not
      // offered: Shift plus a printable key is a capital letter, which is the
      // one thing [ShortcutBinding] refuses outright.
      defaultBinding: ShortcutBinding(LogicalKeyboardKey.slash, control: true),
      intent: ShowKeyboardShortcutsIntent(),
    ),
  ];

  /// [definitions] split into the headings the help window shows, in
  /// [ShortcutGroup] order, with registry order kept inside each one.
  ///
  /// Deterministic twice over: the groups come from the enum's declaration
  /// order and the rows from the registry's, so neither depends on map
  /// iteration or on where an action happens to sit in the list. A group with
  /// nothing in it is left out rather than drawn as an empty heading.
  static List<ShortcutGroupListing> get grouped {
    return <ShortcutGroupListing>[
      for (final ShortcutGroup group in ShortcutGroup.values)
        if (definitions.any((ShortcutActionDefinition d) => d.group == group))
          ShortcutGroupListing(
            group: group,
            actions: <ShortcutActionDefinition>[
              for (final ShortcutActionDefinition d in definitions)
                if (d.group == group) d,
            ],
          ),
    ];
  }

  /// The definition for [action]. Total: the registry lists every enum value,
  /// and a test holds it to that.
  static ShortcutActionDefinition definitionFor(ShortcutAction action) {
    return definitions.firstWhere(
      (ShortcutActionDefinition d) => d.action == action,
    );
  }

  /// The out-of-the-box bindings, as the map the dispatcher and the controller
  /// both start from.
  static Map<ShortcutAction, ShortcutBinding> get defaults {
    return <ShortcutAction, ShortcutBinding>{
      for (final ShortcutActionDefinition d in definitions)
        d.action: d.defaultBinding,
    };
  }

  /// The action whose fixed alias is [binding], or `null`. Used by conflict
  /// detection so nothing can be bound over Ctrl+F.
  static ShortcutAction? actionWithAlias(ShortcutBinding binding) {
    for (final ShortcutActionDefinition d in definitions) {
      if (d.aliases.contains(binding)) return d.action;
    }
    return null;
  }
}
