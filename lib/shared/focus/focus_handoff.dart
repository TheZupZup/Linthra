import 'package:flutter/widgets.dart';

/// Hands the keyboard somewhere sensible when the pane holding it goes away.
///
/// Desktop panes in Linthra come and go for two reasons: the user closes one
/// (the queue column's ✕, the Now Playing queue button), or the window gets
/// narrow enough that the layout drops it (`ListDetailPanes`, the queue
/// column's width floor). Either way the widgets inside are disposed, and if
/// one of them held focus the keyboard is left with nothing: Flutter unwinds to
/// the enclosing scope, so the ring disappears and the next Tab restarts from
/// the top of the page rather than continuing from where the user was.
///
/// A mouse user never notices. A keyboard user loses their place on a window
/// resize they did not think of as leaving the screen. It is the same class of
/// problem `ListDetailPanes` already documents for selection state, and it has
/// the same answer: the thing that outlives the pane has to hold what the pane
/// cannot.
///
/// So wrap the pane in this, pointing at something that is still on screen once
/// the pane is gone, normally the control that opens it again, which is where
/// the user would go next anyway:
///
/// ```dart
/// if (queueOpen)
///   FocusHandoff(
///     returnFocusTo: () => _queueButtonFocusNode,
///     child: QueueSidePanel(...),
///   )
/// ```
///
/// It only acts when the pane really was holding focus, so a pane closed while
/// the user was typing somewhere else never yanks the keyboard away from them.
class FocusHandoff extends StatefulWidget {
  const FocusHandoff({
    required this.returnFocusTo,
    required this.child,
    super.key,
  });

  /// Where the keyboard goes when this subtree leaves the tree holding it.
  ///
  /// Resolved after the pane is gone rather than while it is still up, which is
  /// what lets a caller answer with something that only exists once the layout
  /// has settled: the first row of the list a detail pane was sitting beside,
  /// say, rather than a control it can name in advance.
  ///
  /// Answer null, or a node that went away with the pane, and nothing is done:
  /// a layout change that dropped both leaves focus where Flutter put it
  /// instead of arming a request that would fire whenever that control came
  /// back, long afterwards.
  final ValueGetter<FocusNode?> returnFocusTo;

  final Widget child;

  @override
  State<FocusHandoff> createState() => _FocusHandoffState();
}

class _FocusHandoffState extends State<FocusHandoff> {
  /// Whether anything inside currently holds the keyboard. Read at dispose,
  /// when the nodes below are already being detached and cannot answer.
  bool _hadFocus = false;

  @override
  void dispose() {
    if (_hadFocus) {
      final ValueGetter<FocusNode?> resolve = widget.returnFocusTo;
      // After the frame that removes the pane: the framework unfocuses the
      // detaching node as part of it, a request made now would be undone by
      // that unwind, and what is left on screen is not laid out until then
      // anyway.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final FocusNode? target = resolve();
        if (target == null || target.context == null) return;
        target.requestFocus();
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      // Observes, never lands: an extra stop in front of every pane is exactly
      // the kind of unexplained Tab that this issue is about removing.
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onFocusChange: (bool focused) => _hadFocus = focused,
      child: widget.child,
    );
  }
}
