import 'package:flutter/widgets.dart';

/// The rows inside [region] that the keyboard can land on, in reading order.
///
/// "Row" means a row, a grid cell, a card (the thing a user would say they are
/// *on*), and not the controls it carries. A track row holds an overflow menu,
/// a queue row holds a remove button and a drag handle, and a jump that landed
/// on the last row's ⋮ rather than on the row would be a strange place to
/// arrive. Those controls are focus-tree descendants of the row they belong to,
/// so keeping only the outermost candidate of each nest is exactly the rows.
/// Tab still reaches everything inside them, as it always did.
///
/// Ordered by where the rows actually are, not by their order in the focus
/// tree. A sliver builds rows as scrolling reaches them, so the tree order of a
/// list the user has scrolled through is the order the rows were *first seen*,
/// which, after scrolling back up, is not the order they are read in. Geometry
/// cannot drift that way.
///
/// [region] is normally a [Focus] node that cannot be focused itself, parked
/// around a list or a pane purely to be asked this question.
List<FocusNode> focusableRowsIn(FocusNode region, {required bool rtl}) {
  if (region.context == null) return const <FocusNode>[];
  final Set<FocusNode> candidates = <FocusNode>{
    for (final FocusNode node in region.traversalDescendants)
      // A row that is still in the tree but no longer laid out (a sliver keeps
      // the focused one alive as it scrolls away) reports a non-finite rect.
      // It is nowhere on screen, so it is no place to send the keyboard, and
      // left in it would sort past every real row.
      if (node.context != null && node.rect.isFinite) node,
  };
  final List<FocusNode> rows = <FocusNode>[
    for (final FocusNode node in candidates)
      if (!node.ancestors.any(candidates.contains)) node,
  ];
  rows.sort((FocusNode a, FocusNode b) {
    final Rect first = a.rect;
    final Rect second = b.rect;
    // Band first: the cells of one grid row share a top edge, and it is the
    // horizontal order that separates them.
    if (first.top != second.top) return first.top.compareTo(second.top);
    return rtl
        ? second.left.compareTo(first.left)
        : first.left.compareTo(second.left);
  });
  return rows;
}

/// A [Focus] node parked around [child] only so it can be asked what is
/// focusable inside it.
///
/// It is never a stop of its own and can never hold the keyboard itself: it
/// exists so a pane that is going away has somewhere to point (see
/// `FocusHandoff`), and so a list can answer a key its rows know nothing about.
class FocusRegion extends StatelessWidget {
  const FocusRegion({required this.node, required this.child, super.key});

  final FocusNode node;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: node,
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      child: child,
    );
  }
}
