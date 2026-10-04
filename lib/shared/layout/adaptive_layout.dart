import 'package:flutter/widgets.dart';

/// How much horizontal room a surface actually has to lay itself out in.
///
/// Linthra adapts on *width*, not on `Platform.isLinux`: a 700 px Linux window
/// and a large foldable want the same layout, and a feature widget should not
/// have to know which OS it is drawn on to make that call. The desktop shell
/// (rail, dividers) already eats part of the window, so the classes are meant
/// to be resolved from the constraints a widget is given — see
/// [AdaptiveLayoutBuilder] — rather than from the raw window size.
///
/// The thresholds follow Material's window size classes, with the compact and
/// medium ones kept exactly where Android already behaves, so nothing about the
/// phone layout moves.
enum WindowSizeClass {
  /// Phones, and Linux windows narrow enough that one column is still right.
  compact,

  /// Small desktop windows, tablets, landscape phones: room for a second
  /// column of list rows, not yet for a second pane.
  medium,

  /// A normal desktop window (1280×720 and up): room for a real two-pane
  /// composition beside the navigation rail.
  expanded,

  /// 1920 and beyond, including ultrawide. Content is capped and centred here
  /// rather than stretched, so text lines stay readable.
  large;

  /// Whether this class is at least [other] wide, so callers can ask
  /// `sizeClass.isAtLeast(WindowSizeClass.expanded)` instead of comparing
  /// enum indices by hand.
  bool isAtLeast(WindowSizeClass other) => index >= other.index;
}

/// Lower bound of [WindowSizeClass.medium].
const double mediumWindowWidth = 600;

/// Lower bound of [WindowSizeClass.expanded]: the width where a second pane
/// starts to pay for itself next to the navigation rail.
const double expandedWindowWidth = 1000;

/// Lower bound of [WindowSizeClass.large].
const double largeWindowWidth = 1600;

/// Widest a single column of text or list rows is allowed to get.
///
/// Rows stretched across a 2560 px monitor put the title and the trailing
/// action a screen apart and read badly; capping and centring keeps them
/// scannable without leaving the desktop looking empty.
const double maxContentWidth = 1100;

/// Widest a settings form or card stack is allowed to get. Narrower than
/// [maxContentWidth]: a settings row is a label and a control, and pulling the
/// two apart across a monitor is exactly what makes a desktop app look like a
/// stretched phone.
const double maxFormWidth = 840;

/// Widest a two-pane composition is allowed to get before it stops growing and
/// centres instead. Generous enough that 1920 is used in full.
const double maxPaneLayoutWidth = 1800;

/// The size class for [width] logical pixels of available width.
///
/// Pure, so the breakpoints can be asserted without pumping a widget. A
/// non-finite or non-positive width (an unbounded or not-yet-measured box)
/// falls back to [WindowSizeClass.compact], which is the layout that works
/// everywhere.
WindowSizeClass windowSizeClassFor(double width) {
  if (!width.isFinite || width <= 0) return WindowSizeClass.compact;
  if (width >= largeWindowWidth) return WindowSizeClass.large;
  if (width >= expandedWindowWidth) return WindowSizeClass.expanded;
  if (width >= mediumWindowWidth) return WindowSizeClass.medium;
  return WindowSizeClass.compact;
}

/// Builds against the [WindowSizeClass] of the box the widget is given.
///
/// Prefer this over reading `MediaQuery.sizeOf(context)`: inside the desktop
/// shell a feature screen is narrower than the window by the width of the
/// navigation rail, and a sheet or split pane is narrower still.
class AdaptiveLayoutBuilder extends StatelessWidget {
  const AdaptiveLayoutBuilder({required this.builder, super.key});

  final Widget Function(
    BuildContext context,
    BoxConstraints constraints,
    WindowSizeClass sizeClass,
  ) builder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) => builder(
          context, constraints, windowSizeClassFor(constraints.maxWidth)),
    );
  }
}

/// Caps a single column of content at [maxWidth] and centres it.
///
/// A no-op below the cap, so phones and narrow windows are untouched; it only
/// engages once a window is wide enough that a full-bleed column would be hard
/// to read.
class AdaptiveContentWidth extends StatelessWidget {
  const AdaptiveContentWidth({
    required this.child,
    this.maxWidth = maxContentWidth,
    this.alignment = Alignment.topCenter,
    super.key,
  });

  final Widget child;
  final double maxWidth;

  /// Where the capped column sits once the box is wider than [maxWidth].
  /// Centred by default; a column under a start-aligned header aligns with it
  /// instead.
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
