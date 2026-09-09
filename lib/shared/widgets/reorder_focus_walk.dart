import 'package:flutter/widgets.dart';

/// Keeps keyboard focus on the row a reorder actually moved.
///
/// A pointer drag carries the row under the pointer, so the framework keeps the
/// gesture aimed at the right item by itself. A keyboard move is a jump
/// instead — the list rebuilds with the moved row a slot away — so focus has to
/// be handed to the row it landed on, or a second Ctrl+Arrow would move
/// whatever slid into the old position.
///
/// The focus nodes are per *position*, not per item, which is what makes that
/// work: after the rebuild the node at the destination index is the moved row's
/// handle. Keying them by item would mean a new node per edit, and a duplicate
/// node whenever the same song appears twice.
///
/// Shared by the queue's Up Next list and the playlist editor (#388, #389).
/// Pure enough to unit-test the index arithmetic without pumping a list; the
/// focus and scroll side effects are exercised through the two screens.
class ReorderFocusWalk {
  ReorderFocusWalk({String debugLabelPrefix = 'reorder-handle'})
      : _debugLabelPrefix = debugLabelPrefix;

  final String _debugLabelPrefix;
  final List<FocusNode> _nodes = <FocusNode>[];
  bool _disposed = false;

  /// Where a keyboard walk started from and where it has actually put the row,
  /// while the list catches up.
  ///
  /// A move is applied to the underlying model before any frame rebuilds the
  /// rows with it. A held chord repeats faster than that: the second press is
  /// fired by a handle still carrying the pre-move index, and taking it at face
  /// value would move the row back where it came from. [_walkOrigin] is that
  /// stale index, [_walkLanded] is where the row really is, and [reset] drops
  /// both the moment a rebuild makes the widgets truthful again.
  int? _walkOrigin;
  int? _walkLanded;

  /// The handle focus node for row [index], grown on demand.
  ///
  /// The list only ever grows within one screen: a shrinking list leaves spare
  /// nodes parked, which costs nothing and keeps the indices stable.
  FocusNode nodeAt(int index) {
    while (_nodes.length <= index) {
      _nodes.add(FocusNode(debugLabel: '$_debugLabelPrefix-${_nodes.length}'));
    }
    return _nodes[index];
  }

  /// Forgets an in-flight walk. Hosts call this when the list identity changes,
  /// which means the rows now carry post-move indices.
  void reset() {
    _walkOrigin = null;
    _walkLanded = null;
  }

  void dispose() {
    for (final FocusNode node in _nodes) {
      node.dispose();
    }
    _nodes.clear();
    _disposed = true;
  }

  /// The real source row for a move asked for by the handle on [rowIndex].
  ///
  /// [rowIndex] is only a starting point: while a walk is in flight the rows
  /// still report their pre-move indices, so the real source comes from the
  /// landed position. The substitution is guarded on the walk's origin, so a
  /// press on some *other* row inside that same window is still taken at face
  /// value.
  int sourceFor(int rowIndex) =>
      (_walkLanded != null && rowIndex == _walkOrigin)
          ? _walkLanded!
          : rowIndex;

  /// Records that the row whose handle sits on [rowIndex] has landed on [to].
  void recordMove({required int rowIndex, required int to}) {
    _walkOrigin = rowIndex;
    _walkLanded = to;
  }

  /// The index of the handle that currently has focus, or -1 when none does —
  /// so a plain mouse drag never pulls focus into the list.
  int get focusedIndex => _nodes.indexWhere((FocusNode node) => node.hasFocus);

  /// Where row [index] ends up once the row at [from] is moved to [to].
  ///
  /// [to] is the destination *after* removal, the index a normalised
  /// reorderable list reports.
  static int positionAfterMove(
    int index, {
    required int from,
    required int to,
  }) {
    if (index == from) return to;
    if (from < index && index <= to) return index - 1;
    if (to <= index && index < from) return index + 1;
    return index;
  }

  /// Scrolls the moved row's handle into view and gives it focus, so a held
  /// chord keeps walking the same row. [delta] is the direction of the move.
  ///
  /// The scroll is the part that makes this hold up on a long list. Focus can
  /// only land on a row the sliver has actually built, and a walk that never
  /// scrolls eventually pushes the row past the built range: focus would stay
  /// behind on the row a *different* item just slid into, and the next press
  /// would move that one instead. Keeping the walking row on screen keeps its
  /// destination within the built range, one row at a time.
  void followTo(int index, int delta) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || index < 0 || index >= _nodes.length) return;
      final FocusNode node = _nodes[index];
      final BuildContext? handle = node.context;
      if (handle == null) return;
      Scrollable.ensureVisible(
        handle,
        alignmentPolicy: delta > 0
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
      node.requestFocus();
    });
  }
}
