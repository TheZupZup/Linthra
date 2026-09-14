import 'package:flutter/widgets.dart';

/// How Linthra reads a pointer's scroll input, in one place.
///
/// Everything here is pure and platform-free on purpose. Scrolling is the last
/// part of the desktop work that could plausibly have grown an `isLinux` check
/// in every list, and it does not need one: a wheel notch is a wheel notch
/// whether the window is on GNOME or on a tablet with a mouse plugged in, and
/// the widgets in this directory key on the *signal* rather than on the host.
///
/// The one place a platform is named at all is [AppScrollBehavior], which is
/// the app's single `ScrollConfiguration` and answers Material's own
/// per-platform questions (physics, overscroll decoration) once for the whole
/// app.

/// One mouse-wheel notch, in logical pixels.
///
/// The GTK embedder scales a wheel click by its `kScrollOffsetMultiplier`,
/// which is 53, and the framework hands the delta on in *logical* pixels:
/// `PointerEventConverter` divides the engine's physical delta by the device
/// pixel ratio before the event reaches a widget. One click is therefore the
/// same 53 logical pixels at 100% scaling, at 150% and at 200%, and anything
/// measured against this constant is scale-independent by construction rather
/// than by a correction factor somebody has to remember to apply.
///
/// It is a step size rather than a promise about hardware: a device that
/// reports something else completes a notch sooner or later and nothing here
/// breaks, because [WheelNotches] carries the remainder either way.
///
/// A trackpad is the same signal at a finer grain. Two-finger scrolling on
/// Linux arrives as a stream of scroll events carrying fractional deltas
/// rather than as one 53 px jump, which is what the counter below is for: the
/// same gesture adds up to the same number of steps, it just gets there
/// smoothly.
const double wheelNotchExtent = 53.0;

/// The part of [scrollDelta] a surface that scrolls along [axis] is entitled
/// to.
///
/// Deliberately *not* "whichever axis moved furthest". A sideways flick on a
/// trackpad over the songs list has to do nothing at all, rather than scroll
/// the list because vertical was the only way it could move; horizontal input
/// belongs to horizontal surfaces, and where the UI has a real one
/// [HorizontalWheelScroll] claims it explicitly.
///
/// This is the same rule [Scrollable] applies to its own axis, written down so
/// the widgets here cannot drift from it.
double scrollDeltaAlong(Axis axis, Offset scrollDelta) => switch (axis) {
      Axis.horizontal => scrollDelta.dx,
      Axis.vertical => scrollDelta.dy,
    };

/// Whether [scrollDelta] moved only across [axis] — a sideways wheel or
/// trackpad flick over a vertical surface, or a vertical one over a horizontal
/// surface.
bool isCrossAxisOnly(Axis axis, Offset scrollDelta) {
  final double along = scrollDeltaAlong(axis, scrollDelta);
  final double across = scrollDeltaAlong(flipAxis(axis), scrollDelta);
  return along == 0.0 && across != 0.0;
}

/// Turns a stream of scroll deltas into whole wheel notches.
///
/// A control with a handful of steps — volume, a seek position — cannot take
/// its input raw. A mouse wheel delivers one [wheelNotchExtent] jump per click,
/// but a trackpad delivers the *same gesture* as dozens of small deltas, so a
/// control that steps once per event jumps a notch per event and a two-finger
/// flick slams the volume from half to silent. Counting notches instead makes
/// both devices agree: one notch of physical scrolling is one step, whether it
/// arrived in one event or in forty.
///
/// The remainder is carried, so slow trackpad scrolling accumulates instead of
/// being rounded away to nothing. A change of direction drops it: a carried
/// half-notch upward must not eat the first notch of a downward scroll, which
/// would read as the control ignoring the input.
class WheelNotches {
  WheelNotches({this.notchExtent = wheelNotchExtent})
      : assert(notchExtent > 0, 'a notch has to have a size');

  /// How much scrolling makes one step. Overridable so a test can work in
  /// round numbers rather than in multiples of 53.
  final double notchExtent;

  double _carried = 0.0;

  /// Slack, in logical pixels, on "did that complete a notch".
  ///
  /// Ten trackpad deltas of a tenth of a notch each add up to
  /// 52.99999999999999, and a gesture that is a notch to the pixel has to
  /// count as one rather than sit there waiting for another event. A
  /// hundredth of a logical pixel is far below anything a person can aim.
  static const double _tolerance = 0.01;

  /// The whole notches [delta] completes, signed the same way as [delta].
  ///
  /// Returns 0 while a gesture is still adding up to its first notch.
  int take(double delta) {
    if (delta == 0.0) return 0;
    if (_carried != 0.0 && delta.isNegative != _carried.isNegative) {
      _carried = 0.0;
    }
    _carried += delta;
    final int magnitude = ((_carried.abs() + _tolerance) / notchExtent).floor();
    if (magnitude == 0) return 0;
    final int notches = _carried.isNegative ? -magnitude : magnitude;
    _carried -= notches * notchExtent;
    if (_carried.abs() < _tolerance) _carried = 0.0;
    return notches;
  }

  /// Forgets a partial notch. Call this when the gesture is over — the pointer
  /// left the control, or the control was let go — so the next one starts from
  /// zero rather than from someone else's leftovers.
  void reset() => _carried = 0.0;
}
