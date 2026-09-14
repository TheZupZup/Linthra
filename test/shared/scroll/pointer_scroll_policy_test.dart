import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/scroll/pointer_scroll_policy.dart';

/// The arithmetic behind Linthra's pointer scrolling (#396).
///
/// It is pure on purpose: a wheel notch, a trackpad's stream of small deltas
/// and the rule about which axis owns which input are all decidable without
/// pumping a widget, and every widget in `shared/scroll` is built on top of
/// what is asserted here.
void main() {
  group('which axis owns a scroll delta', () {
    test('a surface reads only the axis it scrolls along', () {
      const Offset diagonal = Offset(7, 11);
      expect(scrollDeltaAlong(Axis.vertical, diagonal), 11);
      expect(scrollDeltaAlong(Axis.horizontal, diagonal), 7);
    });

    test('a sideways flick over a vertical surface moves nothing', () {
      // The songs list must not scroll because a trackpad went sideways: the
      // vertical component is what it is entitled to, and that is zero.
      expect(scrollDeltaAlong(Axis.vertical, const Offset(40, 0)), 0);
      expect(isCrossAxisOnly(Axis.vertical, const Offset(40, 0)), isTrue);
    });

    test('a plain wheel over a horizontal surface is cross-axis', () {
      // The one case a horizontal shelf is allowed to claim, because a mouse
      // with a single wheel has no other way to reach the end of the row.
      expect(isCrossAxisOnly(Axis.horizontal, const Offset(0, 53)), isTrue);
    });

    test('a device that scrolls both ways is nobody else business', () {
      // A trackpad saying "down and a little sideways" is already handled by
      // the surface's own Scrollable on each axis; nothing may reinterpret it.
      expect(isCrossAxisOnly(Axis.horizontal, const Offset(3, 53)), isFalse);
      expect(isCrossAxisOnly(Axis.vertical, const Offset(3, 53)), isFalse);
    });

    test('no movement at all is not a cross-axis gesture', () {
      expect(isCrossAxisOnly(Axis.vertical, Offset.zero), isFalse);
      expect(isCrossAxisOnly(Axis.horizontal, Offset.zero), isFalse);
    });
  });

  group('counting wheel notches', () {
    test('one wheel click is one notch', () {
      final WheelNotches notches = WheelNotches();
      expect(notches.take(wheelNotchExtent), 1);
      expect(notches.take(-wheelNotchExtent), -1);
    });

    test('a trackpad adds up to the same notch a wheel jumps', () {
      // Ten small deltas are one physical gesture of the same size, so they
      // are worth one step — not ten, which is what stepping per event did and
      // is why a two-finger flick used to slam the volume to silence.
      final WheelNotches notches = WheelNotches();
      int steps = 0;
      for (int i = 0; i < 10; i++) {
        steps += notches.take(wheelNotchExtent / 10);
      }
      expect(steps, 1);
    });

    test('a partial notch is carried, not rounded away', () {
      final WheelNotches notches = WheelNotches(notchExtent: 10);
      expect(notches.take(6), 0);
      expect(notches.take(6), 1, reason: '12 of scrolling is one notch of 10');
      expect(notches.take(8), 1, reason: 'the carried 2 completes it');
    });

    test('a fast wheel spin in one event is worth every notch in it', () {
      final WheelNotches notches = WheelNotches(notchExtent: 10);
      expect(notches.take(35), 3);
      expect(notches.take(-35), -3);
    });

    test('turning around drops what was carried', () {
      // Otherwise a carried half-notch upwards eats the first notch of the
      // scroll back down, and the control reads as ignoring the input.
      final WheelNotches notches = WheelNotches(notchExtent: 10);
      expect(notches.take(9), 0);
      expect(notches.take(-10), -1);
    });

    test('letting go forgets a partial notch', () {
      final WheelNotches notches = WheelNotches(notchExtent: 10);
      expect(notches.take(9), 0);
      notches.reset();
      expect(notches.take(9), 0, reason: 'the 9 before the reset is gone');
      expect(notches.take(1), 1);
    });

    test('nothing scrolled is no notches', () {
      expect(WheelNotches().take(0), 0);
    });

    test('a pause long enough to be a new gesture drops the remainder', () {
      // A trackpad has no "I let go" in a scroll event, so a swipe that
      // stopped part of the way into a notch would otherwise keep that part
      // forever — and a separate small swipe later would complete it.
      final WheelNotches notches = WheelNotches(notchExtent: 10);
      expect(notches.take(9, at: Duration.zero), 0);
      expect(
        notches.take(9, at: WheelNotches.gestureGap * 2),
        0,
        reason: 'a new gesture starts from zero, so 9 is still short',
      );
      expect(notches.take(1, at: WheelNotches.gestureGap * 2), 1);
    });

    test('a gap inside one gesture keeps adding up', () {
      // Scrolling slowly on purpose is still one gesture; dropping the
      // remainder here would mean the control never moves at all.
      final WheelNotches notches = WheelNotches(notchExtent: 10);
      expect(notches.take(6, at: Duration.zero), 0);
      expect(
        notches.take(6, at: const Duration(milliseconds: 200)),
        1,
        reason: '200ms is a pause in a gesture, not the end of one',
      );
    });

    test('an untimed caller keeps the old behaviour', () {
      final WheelNotches notches = WheelNotches(notchExtent: 10);
      expect(notches.take(6), 0);
      expect(notches.take(6), 1);
    });
  });
}
