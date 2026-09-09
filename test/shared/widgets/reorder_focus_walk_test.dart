import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/widgets/reorder_focus_walk.dart';

void main() {
  group('ReorderFocusWalk.positionAfterMove', () {
    // Where an already-focused row ends up when some *other* row is dragged
    // past it. Getting this wrong is what makes a Ctrl+Arrow after a drag move
    // the neighbour instead of the row the user is holding.
    test('the moved row lands on its destination', () {
      expect(ReorderFocusWalk.positionAfterMove(2, from: 2, to: 5), 5);
      expect(ReorderFocusWalk.positionAfterMove(5, from: 5, to: 0), 0);
    });

    test('a row the move passes downwards shifts up one', () {
      // 0 1 [2] 3 4  ->  drag 1 to 3  ->  0 2 3 [1] 4
      expect(ReorderFocusWalk.positionAfterMove(2, from: 1, to: 3), 1);
      expect(ReorderFocusWalk.positionAfterMove(3, from: 1, to: 3), 2);
    });

    test('a row the move passes upwards shifts down one', () {
      expect(ReorderFocusWalk.positionAfterMove(1, from: 3, to: 1), 2);
      expect(ReorderFocusWalk.positionAfterMove(2, from: 3, to: 1), 3);
    });

    test('a row outside the moved span stays put', () {
      expect(ReorderFocusWalk.positionAfterMove(0, from: 1, to: 3), 0);
      expect(ReorderFocusWalk.positionAfterMove(4, from: 1, to: 3), 4);
      expect(ReorderFocusWalk.positionAfterMove(0, from: 3, to: 1), 0);
      expect(ReorderFocusWalk.positionAfterMove(4, from: 3, to: 1), 4);
    });
  });

  group('ReorderFocusWalk in-flight walk', () {
    test('a row index is taken at face value before any move', () {
      final ReorderFocusWalk walk = ReorderFocusWalk();
      addTearDown(walk.dispose);
      expect(walk.sourceFor(3), 3);
    });

    test('a repeat from the same handle uses where the row really landed', () {
      final ReorderFocusWalk walk = ReorderFocusWalk();
      addTearDown(walk.dispose);
      // A held chord: the handle still reports row 0 because no frame has
      // rebuilt it, but the row is already at 1.
      walk.recordMove(rowIndex: 0, to: 1);
      expect(walk.sourceFor(0), 1);
      walk.recordMove(rowIndex: 0, to: 2);
      expect(walk.sourceFor(0), 2);
    });

    test('a press on another row inside the same window is not rewritten', () {
      final ReorderFocusWalk walk = ReorderFocusWalk();
      addTearDown(walk.dispose);
      walk.recordMove(rowIndex: 0, to: 1);
      expect(walk.sourceFor(4), 4);
    });

    test('a rebuild ends the walk, so indices are trusted again', () {
      final ReorderFocusWalk walk = ReorderFocusWalk();
      addTearDown(walk.dispose);
      walk.recordMove(rowIndex: 0, to: 3);
      walk.reset();
      expect(walk.sourceFor(0), 0);
    });
  });

  group('ReorderFocusWalk focus nodes', () {
    test('nodes are per position and stable across lookups', () {
      final ReorderFocusWalk walk = ReorderFocusWalk();
      addTearDown(walk.dispose);
      expect(identical(walk.nodeAt(2), walk.nodeAt(2)), isTrue);
      expect(identical(walk.nodeAt(0), walk.nodeAt(1)), isFalse);
    });

    test('no focused handle reports -1, so a pointer drag stays pointer-only',
        () {
      final ReorderFocusWalk walk = ReorderFocusWalk();
      addTearDown(walk.dispose);
      walk.nodeAt(2);
      expect(walk.focusedIndex, -1);
    });
  });
}
