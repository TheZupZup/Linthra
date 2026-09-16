import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/shortcuts/shortcut_action.dart';
import 'package:linthra/app/shortcuts/shortcut_surface.dart';

/// The registry a surface claims a shortcut through (#391).
///
/// Small, but the hand-off rules are the part that goes wrong. Claims stack,
/// because the queue sheet sits over the navigation frame and both have
/// something to say about the queue chord, and teardown order is not something
/// either of them can see.
void main() {
  test('nobody has claimed anything to begin with', () {
    final ShortcutSurface surface = ShortcutSurface();

    expect(surface.handlersFor(ShortcutAction.queue), isEmpty);
  });

  test('a claim is offered until it is withdrawn', () {
    final ShortcutSurface surface = ShortcutSurface();
    bool ran = false;
    bool handler() {
      ran = true;
      return true;
    }

    surface.bind(ShortcutAction.queue, handler);
    expect(surface.handlersFor(ShortcutAction.queue).single(), isTrue);
    expect(ran, isTrue);

    surface.unbind(ShortcutAction.queue, handler);
    expect(surface.handlersFor(ShortcutAction.queue), isEmpty);
  });

  test('claims do not leak between actions', () {
    final ShortcutSurface surface = ShortcutSurface();
    bool handler() => true;

    surface.bind(ShortcutAction.queue, handler);

    expect(surface.handlersFor(ShortcutAction.library), isEmpty);
  });

  test('the innermost claim is offered the key first', () {
    final ShortcutSurface surface = ShortcutSurface();
    // The frame first, the sheet over it second, which is the order they
    // appear on screen.
    bool frame() => true;
    bool sheet() => false;

    surface.bind(ShortcutAction.queue, frame);
    surface.bind(ShortcutAction.queue, sheet);

    expect(
      surface.handlersFor(ShortcutAction.queue),
      <Object>[sheet, frame],
      reason: 'most recently bound first',
    );
  });

  test('withdrawing the inner claim leaves the outer one standing', () {
    final ShortcutSurface surface = ShortcutSurface();
    bool frame() => true;
    bool sheet() => false;

    surface.bind(ShortcutAction.queue, frame);
    surface.bind(ShortcutAction.queue, sheet);
    surface.unbind(ShortcutAction.queue, sheet);

    expect(surface.handlersFor(ShortcutAction.queue), <Object>[frame]);
  });

  test('withdrawing in either order is safe', () {
    final ShortcutSurface surface = ShortcutSurface();
    bool first() => true;
    bool second() => false;

    surface.bind(ShortcutAction.queue, first);
    surface.bind(ShortcutAction.queue, second);
    // The outer one goes first, which is what happens when a rebuild replaces
    // a surface before the one it replaced has been disposed.
    surface.unbind(ShortcutAction.queue, first);
    expect(surface.handlersFor(ShortcutAction.queue), <Object>[second]);

    surface.unbind(ShortcutAction.queue, second);
    expect(surface.handlersFor(ShortcutAction.queue), isEmpty);

    // And withdrawing one nobody registered changes nothing.
    surface.unbind(ShortcutAction.queue, first);
    expect(surface.handlersFor(ShortcutAction.queue), isEmpty);
  });
}
