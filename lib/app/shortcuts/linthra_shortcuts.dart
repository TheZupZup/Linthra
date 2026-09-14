import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/playback_controller.dart';
import '../../features/library/widgets/quick_search_overlay.dart';
import '../../features/player/player_providers.dart';
import '../../features/player/widgets/queue_sheet.dart';
import '../../shared/focus/text_editing_focus.dart';
import '../routes.dart';
import 'keyboard_shortcuts_controller.dart';
import 'shortcut_action.dart';
import 'shortcut_binding.dart';
import 'shortcut_intents.dart';

/// The activators to install for [bindings], including the fixed aliases.
///
/// Pure, and exported, so a test can assert the app really is reachable by the
/// documented keys rather than by a private copy of them — and so the help
/// window in #392 can render the same table the dispatcher installed.
///
/// An alias is added only when nothing else already claims that combination.
/// Nothing in the shipped defaults can collide (the controller refuses to bind
/// over an alias), but a preferences file edited by hand could, and a
/// duplicate key in this map would be the last writer silently winning. The
/// user's own binding wins instead.
Map<ShortcutActivator, Intent> shortcutActivators(
  Map<ShortcutAction, ShortcutBinding> bindings,
) {
  final Map<ShortcutActivator, Intent> activators =
      <ShortcutActivator, Intent>{};
  final Set<ShortcutBinding> claimed = <ShortcutBinding>{};

  for (final ShortcutActionDefinition definition
      in ShortcutActions.definitions) {
    final ShortcutBinding binding =
        bindings[definition.action] ?? definition.defaultBinding;
    if (claimed.add(binding)) {
      activators[binding.activator] = definition.intent;
    }
  }
  for (final ShortcutActionDefinition definition
      in ShortcutActions.definitions) {
    for (final ShortcutBinding alias in definition.aliases) {
      if (claimed.add(alias)) activators[alias.activator] = definition.intent;
    }
  }
  return activators;
}

/// Binds Linthra's keyboard shortcuts over [child].
///
/// **Where it sits.** Above the router, wrapping everything the app ever shows,
/// rather than inside the navigation shell. Key events travel up from whatever
/// has focus, so a binding under the shell would be invisible to routes pushed
/// over it — the full-screen Now Playing screen above all, which is exactly
/// where a shortcut is most likely to be pressed. That position is also why it
/// takes [navigatorKey] instead of using its own context: above the router
/// there is no `Navigator` ancestor to show an overlay or a sheet on.
///
/// **Why it is not gated on the platform.** Linthra decides presentation on the
/// width it is given, not on `Platform.isLinux`, and a shortcut can only fire
/// when a real keyboard sends the chord. A phone is unaffected by construction,
/// while an Android tablet with a keyboard case gets the same bindings for
/// free — the rule the quick-search binding has always followed.
///
/// **What it does not do.** It never invents playback behaviour. Every action
/// forwards to the same `PlaybackController`, router and overlay the buttons
/// use, so a shortcut and the button beside it cannot drift.
class LinthraShortcuts extends ConsumerStatefulWidget {
  const LinthraShortcuts({
    required this.navigatorKey,
    required this.child,
    super.key,
  });

  /// The root navigator overlays and sheets are shown on (see
  /// [rootNavigatorKeyProvider]).
  final GlobalKey<NavigatorState> navigatorKey;

  final Widget child;

  @override
  ConsumerState<LinthraShortcuts> createState() => _LinthraShortcutsState();
}

class _LinthraShortcutsState extends ConsumerState<LinthraShortcuts> {
  /// Guards against a second overlay stacking on the first — pressing the
  /// search chord again while the overlay already has focus must be a no-op.
  bool _searchShowing = false;

  /// Null only before the navigator's first build, when there is nothing to act
  /// on yet; a dropped keystroke there is the right outcome.
  BuildContext? get _navigatorContext => widget.navigatorKey.currentContext;

  Future<void> _openSearch() async {
    if (_searchShowing) return;
    final BuildContext? context = _navigatorContext;
    if (context == null) return;
    _searchShowing = true;
    try {
      await showQuickSearch(context);
    } finally {
      _searchShowing = false;
    }
  }

  void _togglePlayPause() {
    final PlaybackController controller = ref.read(playbackControllerProvider);
    // The same call the now-playing bar's button makes, chosen off the same
    // state — no second idea of what "play/pause" means.
    unawaited(
      controller.state.isPlaying ? controller.pause() : controller.play(),
    );
  }

  void _skipToNext() {
    unawaited(ref.read(playbackControllerProvider).skipToNext());
  }

  void _skipToPrevious() {
    unawaited(ref.read(playbackControllerProvider).skipToPrevious());
  }

  void _openLibrary() {
    final BuildContext? context = _navigatorContext;
    if (context == null) return;
    GoRouter.maybeOf(context)?.go(AppRoutes.library);
  }

  /// The app-wide fallback for the queue: the same sheet the phone opens and
  /// the same one the now-playing bar falls back to at narrow widths.
  ///
  /// A wide desktop window answers [ToggleQueueIntent] before this ever runs —
  /// `HomeShell` installs its own action for the side column, and `Actions` is
  /// resolved from the focused widget upward. This is what happens when the
  /// shell is not an ancestor of the keyboard, which is the case on any route
  /// pushed over it.
  void _openQueue() {
    final BuildContext? context = _navigatorContext;
    if (context == null) return;
    unawaited(showQueueSheet(context));
  }

  void _openNowPlaying() {
    final BuildContext? context = _navigatorContext;
    if (context == null) return;
    final GoRouter? router = GoRouter.maybeOf(context);
    if (router == null) return;
    // Pressing it again while the player is already up must not stack a second
    // copy of it — the same promise the search overlay makes.
    //
    // Read off the top of the match list rather than off
    // `currentConfiguration.uri`: an imperative `push` leaves that uri on the
    // location underneath, so a guard written against it would never fire and
    // every press would add another player. The top match is also the honest
    // answer when the player was opened by tapping the now-playing bar rather
    // than by this shortcut.
    final RouteMatchBase top =
        router.routerDelegate.currentConfiguration.matches.last;
    if (top.matchedLocation == AppRoutes.player) return;
    router.push(AppRoutes.player);
  }

  @override
  Widget build(BuildContext context) {
    final Map<ShortcutAction, ShortcutBinding> bindings =
        ref.watch(activeShortcutBindingsProvider);

    Action<T> command<T extends Intent>(
      ShortcutAction action,
      VoidCallback run,
    ) {
      return _ShortcutCommand<T>(
        binding: bindings[action] ??
            ShortcutActions.definitionFor(action).defaultBinding,
        run: run,
      );
    }

    return Shortcuts(
      shortcuts: shortcutActivators(bindings),
      child: Actions(
        actions: <Type, Action<Intent>>{
          TogglePlayPauseIntent: command<TogglePlayPauseIntent>(
            ShortcutAction.playPause,
            _togglePlayPause,
          ),
          SkipToNextIntent: command<SkipToNextIntent>(
            ShortcutAction.next,
            _skipToNext,
          ),
          SkipToPreviousIntent: command<SkipToPreviousIntent>(
            ShortcutAction.previous,
            _skipToPrevious,
          ),
          OpenQuickSearchIntent: command<OpenQuickSearchIntent>(
            ShortcutAction.search,
            () => unawaited(_openSearch()),
          ),
          OpenLibraryIntent: command<OpenLibraryIntent>(
            ShortcutAction.library,
            _openLibrary,
          ),
          ToggleQueueIntent: command<ToggleQueueIntent>(
            ShortcutAction.queue,
            _openQueue,
          ),
          OpenNowPlayingIntent: command<OpenNowPlayingIntent>(
            ShortcutAction.nowPlaying,
            _openNowPlaying,
          ),
        },
        child: widget.child,
      ),
    );
  }
}

/// One shortcut's action, with the "don't hijack typing" rule attached.
///
/// The rule lives in [isEnabled] rather than in [invoke] on purpose. A disabled
/// action makes `Shortcuts` report the key as *unhandled*, so the event carries
/// on to the text field and the character is typed. Swallowing it in `invoke`
/// would leave the user with a shortcut that did nothing and a letter that
/// never arrived.
class _ShortcutCommand<T extends Intent> extends Action<T> {
  _ShortcutCommand({required this.binding, required this.run});

  /// The combination this action currently answers, which is what decides
  /// whether a focused text field owns it.
  ///
  /// The action's own binding, not the key actually pressed, because an
  /// `Action` is never told which activator matched. The only combination this
  /// distinction could matter for is a fixed alias, and a test holds the
  /// registry to aliases that are not text-editing keys — so in any shipped
  /// configuration the two answers are the same one.
  final ShortcutBinding binding;

  final VoidCallback run;

  @override
  bool isEnabled(T intent) {
    if (!conflictsWithTextEditing(binding)) return true;
    return !primaryFocusIsEditingText();
  }

  @override
  Object? invoke(T intent) {
    run();
    return null;
  }
}
