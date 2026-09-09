import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Lets Escape leave a track selection, on every screen that has one (#387).
///
/// A selection is a mode, and a mode with no keyboard focus has nowhere for a
/// key to land: clicking a row does not move focus by itself, so without this
/// the only way out of a selection started with Ctrl or Shift is the mouse
/// again — the app bar's close button. On a phone the system Back gesture is
/// that way out, which is what the hosts' `PopScope` already answers; Escape is
/// the desktop's Back.
///
/// So the scope takes the keyboard the moment a selection starts and hands
/// Escape to [onEscape]. Its node is kept out of the Tab order: it is somewhere
/// focus is *put*, not a stop on the way through, and Tab from there walks on
/// into the page as it always did.
class SelectionEscapeScope extends StatefulWidget {
  const SelectionEscapeScope({
    required this.selecting,
    required this.onEscape,
    required this.child,
    super.key,
  });

  /// Whether a selection is running. The rising edge is what claims focus.
  final bool selecting;

  final VoidCallback onEscape;

  final Widget child;

  @override
  State<SelectionEscapeScope> createState() => _SelectionEscapeScopeState();
}

class _SelectionEscapeScopeState extends State<SelectionEscapeScope> {
  final FocusNode _node = FocusNode(
    debugLabel: 'track selection',
    skipTraversal: true,
  );

  @override
  void initState() {
    super.initState();
    if (widget.selecting) _claimFocus();
  }

  @override
  void didUpdateWidget(SelectionEscapeScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only on the rising edge: re-requesting on every selection change would
    // pull focus back from anything the user had since moved it to — a search
    // field, the app bar's own buttons — for no reason.
    if (widget.selecting && !oldWidget.selecting) _claimFocus();
  }

  void _claimFocus() {
    // After the frame that turned selection on: the node is only attached once
    // this build has been mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.selecting) _node.requestFocus();
    });
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      skipTraversal: true,
      onKeyEvent: (FocusNode node, KeyEvent event) {
        if (!widget.selecting ||
            event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.escape) {
          return KeyEventResult.ignored;
        }
        widget.onEscape();
        return KeyEventResult.handled;
      },
      child: widget.child,
    );
  }
}
