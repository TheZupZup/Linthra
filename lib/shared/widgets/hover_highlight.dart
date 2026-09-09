import 'package:flutter/material.dart';

/// Tells a child whether a pointer is over it, so surfaces that ink cannot
/// reach can answer a hover themselves.
///
/// Most of Linthra hovers for free: a [ListTile], an [InkWell], a button or a
/// navigation destination all draw the theme's `hoverColor` as an ink overlay,
/// so one value in the theme covers rows, buttons, menus and the rail at once
/// (#385). This exists for the one case that does not work: a card whose child
/// is an opaque image. Ink is painted on the [Material] *behind* the child, so
/// an album cover hides the highlight and leaves a mouse user with feedback on
/// the label strip and nothing on the artwork they are actually pointing at.
///
/// It is deliberately a signal rather than a decoration: the card decides what
/// hovering looks like, and there is one [MouseRegion] to reason about instead
/// of one per surface. Nothing here fires on a touch device, so mobile is
/// untouched by construction.
class HoverHighlight extends StatefulWidget {
  const HoverHighlight({required this.builder, super.key});

  final Widget Function(BuildContext context, bool hovered) builder;

  @override
  State<HoverHighlight> createState() => _HoverHighlightState();
}

class _HoverHighlightState extends State<HoverHighlight> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      // The cursor is the other half of "this is interactive", and it costs
      // nothing to be right about it here.
      cursor: SystemMouseCursors.click,
      child: widget.builder(context, _hovered),
    );
  }
}

/// A subtle veil drawn over artwork while the pointer is on it.
///
/// The same weight as the theme's `hoverColor`, so a hovered cover and a
/// hovered row read as the same gesture rather than two different ideas. Quiet
/// on purpose: this says "clickable", not "selected".
class HoverArtworkVeil extends StatelessWidget {
  const HoverArtworkVeil({
    required this.hovered,
    required this.child,
    this.borderRadius,
    super.key,
  });

  final bool hovered;
  final Widget child;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        child,
        // Always in the tree, only ever opaque on hover: fading a decoration in
        // and out costs one animation instead of a layout change, so nothing
        // around the cover moves as the pointer crosses it.
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: hovered ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: borderRadius,
                  color: Theme.of(context).hoverColor,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
