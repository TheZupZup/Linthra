import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/playback_state.dart';
import '../../core/services/playback_controller.dart';
import '../../features/help/keyboard_shortcuts_help.dart';
import '../../features/library/widgets/quick_search_overlay.dart';
import '../../features/onboarding/onboarding_controller.dart';
import '../../features/player/player_providers.dart';
import '../../features/player/widgets/queue_sheet.dart';
import '../../shared/focus/text_editing_focus.dart';
import '../routes.dart';
import 'keyboard_shortcuts_controller.dart';
import 'shortcut_action.dart';
import 'shortcut_binding.dart';
import 'shortcut_intents.dart';
import 'shortcut_surface.dart';

/// The activators to install for [bindings], including the fixed aliases.
///
/// Pure, and exported, so a test can assert the app really is reachable by the
/// documented keys rather than by a private copy of them.
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

  /// The same promise for the help window (#392): its own chord is listed in
  /// it, so pressing it again while it is open is a thing people will do.
  bool _helpShowing = false;

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

  Future<void> _showShortcutsHelp() async {
    if (_helpShowing) return;
    final BuildContext? context = _navigatorContext;
    if (context == null) return;
    _helpShowing = true;
    try {
      // No focus node to hand back to: this can fire from anywhere, so the
      // helper returns the keyboard to whatever was holding it.
      await showKeyboardShortcutsHelp(context);
    } finally {
      _helpShowing = false;
    }
  }

  void _togglePlayPause() {
    final PlaybackController controller = ref.read(playbackControllerProvider);
    // Read exactly as the transport's own button reads it
    // (`playback_controls.dart`), both halves of it.
    //
    // The initial prepare is nobody's: the engine has no source installed yet,
    // so `play()` would resume whatever was loaded before the track the user
    // just picked. That is why the button is disabled here rather than showing
    // Play, and the chord has to stand down for the same reason.
    //
    // Buffering, on the other hand, counts as the playing side. A stalled
    // stream is the moment you most want to stop it, and reading `isPlaying`
    // alone made the shortcut call `play()` on something already trying to.
    final PlaybackState state = controller.state;
    if (state.status == PlaybackStatus.loading) return;
    final bool playing = state.isPlaying || state.isBuffering;
    unawaited(playing ? controller.pause() : controller.play());
  }

  void _skipToNext() {
    unawaited(ref.read(playbackControllerProvider).skipToNext());
  }

  void _skipToPrevious() {
    unawaited(ref.read(playbackControllerProvider).skipToPrevious());
  }

  /// The app-wide fallback for Library.
  ///
  /// A plain `go`, which resets the tab to its root and clears anything pushed
  /// over the frame. That is the honest answer from up here: the frame claims
  /// this action whenever it is the page on screen, precisely so the common
  /// case switches branches and keeps the tab's own stack.
  void _openLibrary() {
    final BuildContext? context = _navigatorContext;
    if (context == null) return;
    GoRouter.maybeOf(context)?.go(AppRoutes.library);
  }

  /// The app-wide fallback for the queue: the same sheet the phone opens and
  /// the same one the now-playing bar falls back to at narrow widths.
  ///
  /// Two surfaces answer [ToggleQueueIntent] before this ever runs, both
  /// through [ShortcutSurface]: an open queue sheet, which closes itself, and
  /// the navigation frame, which toggles the side column when this window has
  /// one. This is what happens when neither does.
  void _openQueue() {
    final BuildContext? context = _navigatorContext;
    if (context == null) return;
    // Only ever an *open*. Closing is the sheet's own business: it claims the
    // queue action through [ShortcutSurface] while it is up, so this runs only
    // when there is no sheet on screen to take away. That is what lets the
    // chord toggle a sheet the mini-player button opened, too — one queue,
    // however it was put there.
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
    // Nothing is bound until first-run setup is done. Onboarding is gated only
    // by the router's `initialLocation` — there is no redirect guard — so a
    // Ctrl+L from a focused onboarding control would have walked straight into
    // the library with setup half-finished, and the next launch would have
    // sent the user back to onboarding. None of these actions mean anything
    // before there is a library, so the whole map stands down.
    if (!ref.watch(onboardingControllerProvider)) return widget.child;

    final Map<ShortcutAction, ShortcutBinding> bindings =
        ref.watch(activeShortcutBindingsProvider);

    final ShortcutSurface surface = ref.read(shortcutSurfaceProvider);

    Action<T> command<T extends Intent>(
      ShortcutAction action,
      VoidCallback fallback,
    ) {
      return _ShortcutCommand<T>(
        binding: bindings[action] ??
            ShortcutActions.definitionFor(action).defaultBinding,
        run: () {
          // Surfaces that are on screen answer first, innermost outwards; one
          // that declines, or is not there, leaves the key to the fallback.
          // Read at press time, so a surface can change its mind as the window
          // is resized or a route is pushed over it.
          for (final ShortcutSurfaceHandler claimed
              in surface.handlersFor(action)) {
            if (claimed()) return;
          }
          fallback();
        },
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
          ShowKeyboardShortcutsIntent: command<ShowKeyboardShortcutsIntent>(
            ShortcutAction.shortcutsHelp,
            () => unawaited(_showShortcutsHelp()),
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
    if (!primaryFocusIsEditingText()) return true;
    // Judge the chord that actually fired, not the action's stored binding.
    // One action can answer to several chords — search has the fixed Ctrl+F
    // alias beside its remappable binding — and reading the binding alone
    // switched Ctrl+F off inside a text field whenever search had been
    // remapped onto something a field wanted, even though Ctrl+F is not a
    // chord any field uses.
    //
    // `null` means the keyboard is not holding a chord this app could bind,
    // which is what an `Actions.invoke` from a button looks like; the stored
    // binding is the honest answer there.
    final ShortcutBinding chord = pressedShortcutChord() ?? binding;
    return !conflictsWithTextEditing(chord);
  }

  @override
  Object? invoke(T intent) {
    run();
    return null;
  }
}
