import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/shortcuts/shortcut_action.dart';
import 'package:linthra/app/shortcuts/shortcut_surface.dart';

/// The registry a surface claims a shortcut through (#391). Small, but the
/// hand-off rules are the part that goes wrong: a frame rebuilt in place
/// registers before the old one tears down, and a stale teardown must not take
/// the new claim with it.
void main() {
  test('nobody has claimed anything to begin with', () {
    final ShortcutSurface surface = ShortcutSurface();

    expect(surface.handlerFor(ShortcutAction.queue), isNull);
  });

  test('a claim is returned until it is withdrawn', () {
    final ShortcutSurface surface = ShortcutSurface();
    bool ran = false;
    bool handler() {
      ran = true;
      return true;
    }

    surface.bind(ShortcutAction.queue, handler);
    expect(surface.handlerFor(ShortcutAction.queue)?.call(), isTrue);
    expect(ran, isTrue);

    surface.unbind(ShortcutAction.queue, handler);
    expect(surface.handlerFor(ShortcutAction.queue), isNull);
  });

  test('claims do not leak between actions', () {
    final ShortcutSurface surface = ShortcutSurface();
    bool handler() => true;

    surface.bind(ShortcutAction.queue, handler);

    expect(surface.handlerFor(ShortcutAction.library), isNull);
  });

  test('the newest claim wins, and a late teardown cannot take it', () {
    final ShortcutSurface surface = ShortcutSurface();
    bool oldHandler() => true;
    bool newHandler() => false;

    surface.bind(ShortcutAction.queue, oldHandler);
    // What a rebuilt frame does: the replacement registers, then the one it
    // replaced is disposed and withdraws.
    surface.bind(ShortcutAction.queue, newHandler);
    surface.unbind(ShortcutAction.queue, oldHandler);

    expect(surface.handlerFor(ShortcutAction.queue)?.call(), isFalse);
  });
}
