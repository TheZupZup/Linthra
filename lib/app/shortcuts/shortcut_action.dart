import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'shortcut_binding.dart';
import 'shortcut_intents.dart';

/// Every action a Linthra keyboard shortcut can run.
///
/// This enum plus [ShortcutActions.definitions] is *the* registry: the defaults,
/// the names a person reads, and the intent each one dispatches all live here
/// and nowhere else. The dispatcher, the settings screen, persistence, and the
/// help window planned in #392 all read this same table, so a shortcut cannot
/// be documented as one thing and bound as another.
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
}

/// One action's fixed facts: what it is called, what it does, and what it is
/// bound to out of the box.
@immutable
class ShortcutActionDefinition {
  const ShortcutActionDefinition({
    required this.action,
    required this.storageKey,
    required this.label,
    required this.description,
    required this.defaultBinding,
    required this.intent,
    this.aliases = const <ShortcutBinding>[],
  });

  final ShortcutAction action;

  /// The stable key this action's override is stored under. Never derived from
  /// the enum's name or index: renaming a value or reordering the enum must not
  /// silently move somebody's saved shortcut onto a different action.
  final String storageKey;

  /// The short name a settings row and the help window show.
  final String label;

  /// One line of what it does, for the help window (#392).
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

/// The registry.
abstract final class ShortcutActions {
  /// Every action's definition, in the order a settings screen or help window
  /// should list them: what is playing, then where to go.
  ///
  /// The defaults avoid three things on purpose. Nothing is bound bare, so no
  /// shortcut can eat a keystroke meant as typing. Nothing uses Ctrl+Q, which
  /// quits on Linux. Nothing uses Escape, which the app needs for closing
  /// dialogs, leaving a selection and dismissing quick search.
  static const List<ShortcutActionDefinition> definitions =
      <ShortcutActionDefinition>[
    ShortcutActionDefinition(
      action: ShortcutAction.playPause,
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
      storageKey: 'library',
      label: 'Library',
      description: 'Go to the Library tab.',
      defaultBinding: ShortcutBinding(LogicalKeyboardKey.keyL, control: true),
      intent: OpenLibraryIntent(),
    ),
    ShortcutActionDefinition(
      action: ShortcutAction.queue,
      storageKey: 'queue',
      label: 'Queue',
      description: 'Show or hide what is up next.',
      defaultBinding: ShortcutBinding(LogicalKeyboardKey.keyU, control: true),
      intent: ToggleQueueIntent(),
    ),
    ShortcutActionDefinition(
      action: ShortcutAction.nowPlaying,
      storageKey: 'now_playing',
      label: 'Now Playing',
      description: 'Open the full-screen player.',
      defaultBinding: ShortcutBinding(LogicalKeyboardKey.keyP, control: true),
      intent: OpenNowPlayingIntent(),
    ),
  ];

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
