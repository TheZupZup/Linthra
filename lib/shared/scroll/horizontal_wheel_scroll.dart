import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'pointer_scroll_policy.dart';

/// Lets a plain mouse wheel scroll a surface that only goes sideways.
///
/// [Scrollable] reads only the axis it scrolls along — a horizontal one takes
/// `dx` and ignores `dy` — which is the right rule almost everywhere: it is
/// what stops a sideways trackpad flick from scrolling the songs list, and
/// there is no honest way to guess whether a vertical notch over a nested
/// horizontal strip was meant for the strip or for the page behind it.
///
/// A shelf that is the *only* thing under the pointer is the exception, and
/// every desktop toolkit treats it as one: a wheel over a horizontal-only
/// surface moves that surface. Without this, a mouse with one wheel simply
/// cannot reach the far end of such a row — the content is there, and the only
/// input the user has does nothing.
///
/// Two rules keep it from taking input it has no claim on:
///
/// * a signal that already carries horizontal movement is left alone, because
///   the device could say "sideways" itself and the surface's own [Scrollable]
///   has already handled it;
/// * a signal that would not move the surface — it is at that end already — is
///   not claimed, so the page scrolls instead. That is the same chaining
///   Flutter does between nested scrollables, and it is what keeps a shelf
///   from swallowing the wheel on a page that still has somewhere to go.
///
/// The controller is owned here and handed to [builder] rather than taken as a
/// parameter, so the surface this scrolls and the surface it is wrapped around
/// cannot be two different things.
class HorizontalWheelScroll extends StatefulWidget {
  const HorizontalWheelScroll({required this.builder, super.key});

  /// Builds the horizontal surface, which must attach [ScrollController] to
  /// itself.
  final Widget Function(BuildContext context, ScrollController controller)
      builder;

  @override
  State<HorizontalWheelScroll> createState() => _HorizontalWheelScrollState();
}

class _HorizontalWheelScrollState extends State<HorizontalWheelScroll> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!isCrossAxisOnly(Axis.horizontal, event.scrollDelta)) return;
    if (!_controller.hasClients) return;
    final ScrollPosition position = _controller.position;
    // Down and right both mean "further along the row", in either text
    // direction: what is further along in Arabic is to the left, and it is
    // still what a wheel pulled towards the user should reveal.
    final double delta = scrollDeltaAlong(Axis.vertical, event.scrollDelta);
    final double target = (position.pixels + delta)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target == position.pixels) return;
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (PointerEvent _) => position.pointerScroll(delta),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: widget.builder(context, _controller),
    );
  }
}
