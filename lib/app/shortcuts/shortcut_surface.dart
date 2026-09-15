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
  final Map<ShortcutAction, List<ShortcutSurfaceHandler>> _handlers =
      <ShortcutAction, List<ShortcutSurfaceHandler>>{};

  /// Offers [handler] for [action] until [unbind].
  ///
  /// Claims stack rather than replace, because more than one surface can be on
  /// screen at once and the innermost is the one that knows best: the queue
  /// sheet sits over the navigation frame, and both have something to say
  /// about the queue chord. It also makes a rebuild that swaps a surface safe
  /// in either order, since the replacement's claim does not depend on the old
  /// one having gone first.
  void bind(ShortcutAction action, ShortcutSurfaceHandler handler) {
    _handlers
        .putIfAbsent(action, () => <ShortcutSurfaceHandler>[])
        .add(handler);
  }

  /// Withdraws [handler]. Withdrawing one nobody registered, or one already
  /// gone, is a no-op: teardown order is not something a surface can see.
  void unbind(ShortcutAction action, ShortcutSurfaceHandler handler) {
    final List<ShortcutSurfaceHandler>? claims = _handlers[action];
    if (claims == null) return;
    claims.remove(handler);
    if (claims.isEmpty) _handlers.remove(action);
  }

  /// Everyone who has claimed [action], most recently bound first, which is
  /// the order they should be offered the key in.
  List<ShortcutSurfaceHandler> handlersFor(ShortcutAction action) {
    final List<ShortcutSurfaceHandler>? claims = _handlers[action];
    if (claims == null) return const <ShortcutSurfaceHandler>[];
    return claims.reversed.toList(growable: false);
  }
}

final shortcutSurfaceProvider = Provider<ShortcutSurface>((ref) {
  return ShortcutSurface();
});
