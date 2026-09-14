import 'package:flutter/material.dart';

import '../../app/dimens.dart';

/// How thick Linthra draws the keyboard focus ring.
///
/// Two logical pixels is the thinnest ring that still reads as deliberate at
/// desktop density, where a row is already only 56 px tall.
const double focusRingWidth = 2;

/// Identifies the drawn ring.
///
/// A row is full of decorations (artwork placeholders, status glyphs, a
/// selection tint), so "is this surface showing a focus ring" is not a question
/// a test can answer by looking for a bordered box. This key answers it
/// exactly.
const Key focusRingKey = Key('focus-ring');

/// Whether [mode] is the one where a focus ring belongs on screen.
///
/// This is the whole reason nothing in this file asks which platform it is on.
/// Flutter tracks *how the user is driving*: a touch means
/// [FocusHighlightMode.touch], a key or a mouse means
/// [FocusHighlightMode.traditional]. So "show a focus ring" is a question
/// about the input device, which is the question we actually mean. A phone
/// never leaves touch mode on its own, so mobile is unchanged by construction;
/// an Android tablet with a keyboard case starts showing rings the moment Tab
/// is pressed, which is exactly right and costs nothing to support.
bool showsFocusRing(FocusHighlightMode mode) =>
    mode == FocusHighlightMode.traditional;

/// Draws Linthra's keyboard focus ring around whatever inside it holds focus.
///
/// Material's own focus feedback is an ink overlay, and Linthra has two
/// problems with it. It is a veil, so the album grid hides it: ink is painted
/// on the [Material] *behind* the card, and an opaque cover sits over it, the
/// same blind spot [HoverHighlight] exists for. And a veil is the wrong shape
/// for the job anyway: hover is already a veil (`hoverColor`) and selection is
/// already a tint (`selectedTileColor`), so a third veil would leave the three
/// states telling the user roughly the same thing at three alphas.
///
/// So focus gets its own vocabulary: an outline, in the accent colour, that
/// nothing else in the app uses. It is drawn as an overlay rather than as a
/// border in the layout, so a control does not resize or shift the row around
/// it as focus arrives.
///
/// It takes no focus node. The ring watches a [Focus] node of its own that
/// cannot be focused itself, which reports `hasFocus` whenever *anything
/// inside* holds the keyboard, so it wraps a [ListTile], an [InkWell], a card
/// or a whole row without the widget inside having to be rewritten to hand a
/// node out. The ring around a row therefore also lights up for a control
/// inside that row (its overflow menu, say), which is the right answer: it
/// says where in the list the keyboard is.
///
/// That node is a real one, so `Focus.of` from somewhere under a ring answers
/// with it rather than with whatever holds the keyboard. Anything that needs a
/// surface's own node should read it where it is created, not look it up from
/// deep inside. That is the same care any widget that wraps another in a
/// [Focus] already calls for.
class FocusRing extends StatefulWidget {
  const FocusRing({
    required this.child,
    this.borderRadius,
    this.enabled = true,
    super.key,
  });

  final Widget child;

  /// Corner radius of the ring. Defaults to [AppRadii.sm], the radius list
  /// rows and small controls already use.
  final BorderRadius? borderRadius;

  /// Lets a host turn the ring off without dropping this widget from the tree
  /// (and with it the element identity of everything below).
  final bool enabled;

  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing> {
  bool _focused = false;
  late bool _keyboardDriven;

  @override
  void initState() {
    super.initState();
    _keyboardDriven = showsFocusRing(FocusManager.instance.highlightMode);
    FocusManager.instance.addHighlightModeListener(_onHighlightModeChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightModeChanged);
    super.dispose();
  }

  void _onHighlightModeChanged(FocusHighlightMode mode) {
    final bool keyboardDriven = showsFocusRing(mode);
    if (!mounted || keyboardDriven == _keyboardDriven) return;
    setState(() => _keyboardDriven = keyboardDriven);
  }

  void _onFocusChange(bool focused) {
    if (focused == _focused) return;
    setState(() => _focused = focused);
  }

  @override
  Widget build(BuildContext context) {
    final bool visible = widget.enabled && _focused && _keyboardDriven;
    final BorderRadius radius =
        widget.borderRadius ?? BorderRadius.circular(AppRadii.sm);
    return Focus(
      // Somewhere focus is *observed*, never somewhere it lands: the node must
      // not become a stop of its own on the way through the page.
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onFocusChange: _onFocusChange,
      child: Stack(
        fit: StackFit.passthrough,
        children: <Widget>[
          widget.child,
          if (visible)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  key: focusRingKey,
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.secondary,
                      width: focusRingWidth,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
