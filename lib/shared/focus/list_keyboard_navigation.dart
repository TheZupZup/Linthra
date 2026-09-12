import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'focus_reading_order.dart';

/// The list and grid keys a desktop user expects, on top of the ones Flutter
/// already handles.
///
/// Most of a collection's keyboard behaviour comes for free and is deliberately
/// left alone: the arrow keys already move focus row by row (and cell by cell)
/// through a `ListView` or `GridView`, scrolling as they go, and Page Up/Down
/// already scroll by a screen. What no amount of framework default can supply
/// are the jumps that mean "the other end of this collection", because in a
/// lazily-built list the other end has not been built yet: there is no focus
/// node at the bottom of a 200k-track library for a traversal policy to find.
///
/// So this adds what is missing, for a list *or* a grid:
///
///  * **Home**: the top of the collection, and its first row.
///  * **End**: the bottom of the collection, and its last row.
///  * **← / →** past the end of a row, with [wrapRows]: the next (or previous)
///    cell in reading order, which is how an icon grid is walked on every
///    desktop. Off by default: in a single column of rows, ← and → belong to
///    the controls inside a row, not to the list.
///
/// It scrolls first and moves focus on the next frame, once the sliver has
/// built the rows the jump brought into range. The keyboard therefore lands on
/// a real, visible row rather than on whatever happened to be built before.
///
/// Nothing here is gated on the platform. The keys only arrive from a real
/// keyboard, so a phone is unaffected and a tablet with a keyboard case gets
/// them for free, the same rule the rest of Linthra's desktop work follows.
/// Typing wins outright: while an [EditableText] holds focus every key is left
/// alone, so Home and End keep meaning "start/end of line" in a search box that
/// happens to live inside a list.
class ListKeyboardNavigation extends StatefulWidget {
  const ListKeyboardNavigation({
    required this.child,
    this.wrapRows = false,
    super.key,
  });

  /// Whether ← and → continue into the neighbouring row once a row runs out.
  ///
  /// True for grids of cards, where a row break is a layout artefact and not
  /// something the user arranged. False for a column of rows.
  final bool wrapRows;

  final Widget child;

  @override
  State<ListKeyboardNavigation> createState() => _ListKeyboardNavigationState();
}

class _ListKeyboardNavigationState extends State<ListKeyboardNavigation> {
  /// Observes the rows without ever being a stop of its own: key events travel
  /// up from the focused row through this node, which is how the list gets to
  /// answer a key its rows know nothing about, and `traversalDescendants` gives
  /// the ordered rows without the list having to hold a node per row.
  final FocusNode _node = FocusNode(
    debugLabel: 'list keyboard navigation',
    canRequestFocus: false,
    skipTraversal: true,
  );

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final FocusNode? focused = FocusManager.instance.primaryFocus;
    final BuildContext? focusedContext = focused?.context;
    if (focused == null || focusedContext == null) {
      return KeyEventResult.ignored;
    }
    // Typing first, always: in a text field Home and End are the ends of the
    // line and the arrow keys move the caret.
    if (_isEditingText(focusedContext)) return KeyEventResult.ignored;

    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.home) return _jumpToEdge(focused, end: false);
    if (key == LogicalKeyboardKey.end) return _jumpToEdge(focused, end: true);
    if (!widget.wrapRows) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowRight) {
      return _step(focused, forward: !_isRtl);
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      return _step(focused, forward: _isRtl);
    }
    return KeyEventResult.ignored;
  }

  bool get _isRtl => Directionality.of(context) == TextDirection.rtl;

  /// Whether the keyboard is in a text field rather than on a row.
  ///
  /// Checked through the ancestors as well as the focused widget itself: a
  /// field's focus node is attached to the [Focus] inside its [EditableText],
  /// so the widget directly under the node is one step below the thing the
  /// question is actually about.
  static bool _isEditingText(BuildContext context) =>
      context.widget is EditableText ||
      context.findAncestorWidgetOfExactType<EditableText>() != null;

  /// Home / End: scroll the collection to one end, then take its outermost row.
  KeyEventResult _jumpToEdge(FocusNode focused, {required bool end}) {
    final ScrollableState? scrollable = Scrollable.maybeOf(focused.context!);
    if (scrollable == null) return KeyEventResult.ignored;
    final ScrollPosition position = scrollable.position;
    if (!position.hasContentDimensions) return KeyEventResult.ignored;
    position.jumpTo(end ? position.maxScrollExtent : position.minScrollExtent);
    // Next frame: until the jump has been laid out, the rows at that end of the
    // collection do not exist and there is nothing there to focus.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final List<FocusNode> rows = _rowsInOrder();
      if (rows.isEmpty) return;
      (end ? rows.last : rows.first).requestFocus();
    });
    return KeyEventResult.handled;
  }

  /// ← / → in a grid: the cell the row break hid, one step away in reading
  /// order.
  ///
  /// Tried only once the ordinary geometric move has failed, so moving *within*
  /// a row, and onto whatever controls a row carries, is untouched. Bounded to
  /// this collection by construction: the candidates are its own descendants,
  /// so the last cell of the grid cannot hand focus on to the page beyond it.
  KeyEventResult _step(FocusNode focused, {required bool forward}) {
    final TraversalDirection direction =
        forward ? TraversalDirection.right : TraversalDirection.left;
    if (focused.focusInDirection(direction)) return KeyEventResult.handled;

    final List<FocusNode> cells = _rowsInOrder();
    final int index = cells.indexOf(focused);
    if (index < 0) return KeyEventResult.ignored;
    final int target = forward ? index + 1 : index - 1;
    if (target < 0 || target >= cells.length) return KeyEventResult.ignored;

    final FocusNode next = cells[target];
    final BuildContext? nextContext = next.context;
    if (nextContext != null) {
      Scrollable.ensureVisible(
        nextContext,
        alignmentPolicy: forward
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    }
    next.requestFocus();
    return KeyEventResult.handled;
  }

  /// This collection's rows, in the order they read.
  List<FocusNode> _rowsInOrder() => focusableRowsIn(_node, rtl: _isRtl);

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onKeyEvent: _onKeyEvent,
      child: widget.child,
    );
  }
}
