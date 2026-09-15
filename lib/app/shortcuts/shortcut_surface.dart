import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'shortcut_action.dart';

/// Answers a shortcut on behalf of a surface that is on screen, or declines.
///
/// Returning false means "not mine right now" and hands the key back to the
/// app-level command, so a surface only has to describe the case it improves
/// on rather than reimplement the fallback.
typedef ShortcutSurfaceHandler = bool Function();

/// Where a mounted surface says it can answer a shortcut better than the
/// app-level command can (#391).
///
/// The obvious mechanism for this is a nested `Actions` inside the surface,
/// and it does not hold up. `Shortcuts` resolves an intent from wherever the
/// keyboard focus happens to sit, and focus is not something the navigation
/// frame controls: switch tabs away from a page that had pushed a route and
/// focus lands on the scope *above* the frame, at which point the frame's own
/// `Actions` silently stops being found and the app-level fallback answers
/// instead. The user gets a modal queue sheet over a window that has a queue
/// column, and Ctrl+L throws away the Library stack it was supposed to
/// restore.
///
/// This asks the question that was actually meant: is the frame on screen, and
/// does it want this key? Read at the moment a key is pressed and never
/// watched, so binding costs no rebuild and a surface can answer differently
/// as its layout changes.
class ShortcutSurface {
  final Map<ShortcutAction, ShortcutSurfaceHandler> _handlers =
      <ShortcutAction, ShortcutSurfaceHandler>{};

  /// Offers [handler] for [action] until [unbind]. The most recent claim wins,
  /// which is what makes a rebuild that replaces the surface safe: the new one
  /// registers before the old one tears down.
  void bind(ShortcutAction action, ShortcutSurfaceHandler handler) {
    _handlers[action] = handler;
  }

  /// Withdraws [handler], if it is still the one bound. Checking means a
  /// surface leaving *after* its replacement arrived cannot take the
  /// replacement's claim with it.
  void unbind(ShortcutAction action, ShortcutSurfaceHandler handler) {
    if (_handlers[action] == handler) _handlers.remove(action);
  }

  /// Whoever claimed [action], or null when nobody has.
  ShortcutSurfaceHandler? handlerFor(ShortcutAction action) =>
      _handlers[action];
}

final shortcutSurfaceProvider = Provider<ShortcutSurface>((ref) {
  return ShortcutSurface();
});
