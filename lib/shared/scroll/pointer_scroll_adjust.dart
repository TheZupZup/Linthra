import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'pointer_scroll_policy.dart';

/// Makes a control take the wheel, and keeps the page out of it.
///
/// Two separate things go wrong when a slider sits inside a scrolling page,
/// and this widget is both fixes:
///
/// * **The wheel does two things at once.** A `Listener` that reads a scroll
///   signal does not *consume* it: the ancestor [Scrollable] registers with
///   the [PointerSignalResolver] and scrolls the page as well. So a notch over
///   the volume slider used to change the volume *and* scroll the library out
///   from under the pointer. Registering first is what claims it — pointer
///   signals are dispatched from the innermost hit target outwards, and the
///   first registration wins, so a control that asks for the signal takes it
///   off the page. That is also what a real desktop toolkit does: a GTK scale
///   answers the wheel and the window behind it stays put.
/// * **The page moves while the control is being held.** Mid-drag the pointer
///   wanders off a 14 px seek line easily, and a notch that lands anywhere
///   else scrolls whatever is underneath. While [adjusting] is set *and* the
///   pointer that started it is still down, every scroll signal in the app is
///   swallowed instead, so a drag that started on a control ends on that
///   control and nothing else moves.
///
///   Both halves of that condition are deliberate. Swallowing the app's wheel
///   is the most destructive thing this widget can do, so it is not left to a
///   control remembering to say when it is finished: the pointer's own up or
///   cancel always arrives — Flutter guarantees one or the other for a pointer
///   that went down — and that is what takes the shield away. A control whose
///   drag state got stuck can then still be wrong about itself, but it cannot
///   stop the rest of the app scrolling.
///
/// Steps are counted in whole wheel notches ([WheelNotches]) rather than per
/// event, so a trackpad's stream of small deltas moves a control at the same
/// rate a wheel does instead of slamming it end to end.
///
/// Nothing here is gated on a platform. A touch drag on the control is
/// untouched — it never produced a scroll signal to begin with — so Android
/// behaves exactly as it did, and a tablet with a mouse gets the desktop
/// behaviour for free.
class PointerScrollAdjust extends StatefulWidget {
  const PointerScrollAdjust({
    required this.onNotch,
    required this.child,
    this.enabled = true,
    this.adjusting = false,
    super.key,
  });

  /// Called with whole notches, positive when the scroll asked for *more* —
  /// wheel up, or a trackpad pushed away from the user.
  ///
  /// Call sites decide what a notch is worth. The rule Linthra follows is that
  /// one notch does what one arrow-key press does, so a control answers the
  /// wheel and the keyboard the same way.
  final ValueChanged<int> onNotch;

  /// Whether the control can be adjusted at all. A disabled control claims
  /// nothing, so the page scrolls under it as it would under any other inert
  /// widget.
  final bool enabled;

  /// Whether the control is being held right now — a drag in progress.
  ///
  /// Only ever *narrowed* by this widget: it shields nothing unless a pointer
  /// is genuinely down on the control as well, so a keyboard or assistive
  /// adjustment (which is over the instant it happens) never installs one.
  final bool adjusting;

  final Widget child;

  @override
  State<PointerScrollAdjust> createState() => _PointerScrollAdjustState();
}

class _PointerScrollAdjustState extends State<PointerScrollAdjust> {
  final WheelNotches _notches = WheelNotches();

  /// Pointers that went down on this control and have not come back up.
  ///
  /// A set rather than a flag: a second finger on a touch build must not end
  /// the first one's gesture when it lifts.
  final Set<int> _pointersDown = <int>{};

  void _onPointerDown(PointerDownEvent event) {
    if (_pointersDown.add(event.pointer)) setState(() {});
  }

  /// Up and cancel are the same answer: this pointer is no longer holding the
  /// control. The route was established when it went down, so this arrives
  /// wherever on screen the pointer has wandered to by then.
  void _onPointerReleased(PointerEvent event) {
    if (_pointersDown.remove(event.pointer)) setState(() {});
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (!widget.enabled || event is! PointerScrollEvent) return;
    // Claimed whether or not it completes a notch: a half-notch that fell
    // through to the page would make slow trackpad scrolling over a control
    // scroll the page a little and the control not at all.
    GestureBinding.instance.pointerSignalResolver.register(event, _apply);
  }

  void _apply(PointerEvent event) {
    final PointerScrollEvent scroll = event as PointerScrollEvent;
    // Both axes count. A horizontal wheel, or a sideways trackpad flick over a
    // horizontal slider, means the same thing as a vertical one; the vertical
    // axis wins when a device reports both, because that is the one every
    // mouse has.
    final double delta = scroll.scrollDelta.dy != 0.0
        ? scroll.scrollDelta.dy
        : scroll.scrollDelta.dx;
    // Scrolling up and scrolling left both mean "more": up is louder and later
    // everywhere, and a horizontal slider reads left to right.
    final int notches = _notches.take(-delta);
    if (notches != 0) widget.onNotch(notches);
  }

  @override
  Widget build(BuildContext context) {
    return _ScrollSignalShield(
      active: widget.enabled && widget.adjusting && _pointersDown.isNotEmpty,
      child: MouseRegion(
        // A partial notch belongs to the gesture that started it. Leaving the
        // control ends that gesture, so the next one starts from zero.
        opaque: false,
        onExit: (PointerExitEvent _) => _notches.reset(),
        child: Listener(
          onPointerSignal: _onPointerSignal,
          onPointerDown: _onPointerDown,
          onPointerUp: _onPointerReleased,
          onPointerCancel: _onPointerReleased,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Swallows every pointer scroll signal in the app while [active].
///
/// It works by hit-test order rather than by reaching for anything global: the
/// shield is an overlay entry, so it is in front of the whole app and its
/// [Listener] is the first thing a scroll signal reaches, which is what lets
/// it register with the [PointerSignalResolver] before any [Scrollable] can.
/// It is translucent, so it is invisible to every other kind of event — the
/// drag it exists to protect carries on through it untouched.
class _ScrollSignalShield extends StatefulWidget {
  const _ScrollSignalShield({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<_ScrollSignalShield> createState() => _ScrollSignalShieldState();
}

class _ScrollSignalShieldState extends State<_ScrollSignalShield> {
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    if (widget.active) _insert();
  }

  @override
  void didUpdateWidget(_ScrollSignalShield oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    if (widget.active) {
      _insert();
    } else {
      _remove();
    }
  }

  @override
  void dispose() {
    _remove();
    super.dispose();
  }

  void _insert() {
    if (_entry != null) return;
    // Inserting touches the overlay's own state, and this runs from a build.
    // A frame's delay costs nothing: the shield only matters from the second
    // event of a drag onwards.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || !widget.active || _entry != null) return;
      // Off the root overlay the app has no shield and simply behaves as it
      // did; nothing here is load-bearing enough to assert on.
      final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay == null) return;
      _entry = OverlayEntry(
        builder: (BuildContext context) => Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerSignal: _swallow,
          ),
        ),
      );
      overlay.insert(_entry!);
    });
  }

  void _remove() {
    _entry?.remove();
    _entry = null;
  }

  void _swallow(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (PointerEvent _) {},
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
