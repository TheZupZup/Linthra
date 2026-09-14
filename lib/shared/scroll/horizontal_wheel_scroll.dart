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
/// Three rules keep it from taking input it has no claim on:
///
/// * a signal that already carries horizontal movement is left alone, because
///   the device could say "sideways" itself and the surface's own [Scrollable]
///   has already handled it;
/// * only a mouse gets its vertical scrolling borrowed at all. A wheel has one
///   axis and no way to ask for the other; a trackpad has both, so a vertical
///   two-finger swipe over the row means vertical and is chained on rather
///   than turned sideways. (On Linux the embedder may report a trackpad's
///   scrolling as a mouse's, in which case this changes nothing there — it is
///   still the right rule to write, and it is what makes the behaviour correct
///   wherever the two are distinguishable.)
/// * a signal that would not move the surface — it is at that end already — is
///   not claimed, so something else can have it. That is the same chaining
///   Flutter does between nested scrollables, and it is what keeps a shelf
///   from swallowing the wheel on a page that still has somewhere to go.
///
/// Where the shelf is *nested* in a scrolling page, that second rule needs no
/// help: the page is an ancestor, so an unclaimed signal reaches it on the way
/// out. A shelf that is a **sibling** of the list it belongs to — a row of
/// filter chips above a `ListView`, which is how the audiobook browser is
/// built — has no such ancestor, and an unclaimed signal reaches nothing at
/// all: the list is elsewhere on screen and simply is not on the pointer's
/// hit-test path. [chainTo] is that case. Give it the list's controller and a
/// notch at the end of the row carries on down the page, which is what the
/// same strip does in every other desktop app.
///
/// The shelf's own controller is owned here and handed to [builder] rather
/// than taken as a parameter, so the surface this scrolls and the surface it
/// is wrapped around cannot be two different things.
class HorizontalWheelScroll extends StatefulWidget {
  const HorizontalWheelScroll({
    required this.builder,
    this.chainTo,
    super.key,
  });

  /// Builds the horizontal surface, which must attach [ScrollController] to
  /// itself.
  final Widget Function(BuildContext context, ScrollController controller)
      builder;

  /// The vertical surface a notch falls through to once the row has no more
  /// room, when that surface is a sibling rather than an ancestor.
  ///
  /// Leave it null wherever the shelf sits inside the page it should chain to;
  /// the framework already does that part.
  final ScrollController? chainTo;

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
    // Down and right both mean "further along the row", in either text
    // direction: what is further along in Arabic is to the left, and it is
    // still what a wheel pulled towards the user should reveal.
    final double delta = scrollDeltaAlong(Axis.vertical, event.scrollDelta);
    // A wheel may borrow this row; anything that could have said "sideways"
    // and didn't goes straight to the list, if there is one to go to.
    final ScrollPosition? target = _firstThatMoves(
      delta,
      event.kind == PointerDeviceKind.mouse
          ? <ScrollController?>[_controller, widget.chainTo]
          : <ScrollController?>[widget.chainTo],
    );
    if (target == null) return;
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (PointerEvent _) => target.pointerScroll(delta),
    );
  }

  /// The first of [candidates] that [delta] would actually move, or null — in
  /// which case the signal is left alone for whatever the framework would have
  /// done with it.
  ScrollPosition? _firstThatMoves(
    double delta,
    List<ScrollController?> candidates,
  ) {
    for (final ScrollController? controller in candidates) {
      if (controller == null || !controller.hasClients) continue;
      final ScrollPosition position = controller.position;
      final double target = (position.pixels + delta)
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      if (target != position.pixels) return position;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: widget.builder(context, _controller),
    );
  }
}
