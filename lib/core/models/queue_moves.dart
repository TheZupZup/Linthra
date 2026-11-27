import '../native/native_queue.dart';

/// A move the listener (or the player) makes in the queue.
enum QueueMove {
  /// To the track after the current one.
  next,

  /// To the track before the current one.
  previous,

  /// Back to the first track (repeat-all past the end).
  restart,

  /// To the track at an index in the queue.
  moveTo,

  /// To the track at an index in up next.
  jumpToUpNext,

  /// To the track at an index in history.
  jumpToHistory,
}

/// Where the current track lands after [move] in a queue of [length] tracks
/// with the current one at [current] (-1 when empty), or null when the move
/// does nothing. [index] is only read by the moves that take one.
///
/// Decided by the Rust core (native/linthra_core/src/queue_moves.rs), held
/// to `test/fixtures/queue_moves_cases.txt`.
int? queueMoveTarget(
  QueueMove move, {
  required int length,
  required int current,
  int index = 0,
}) =>
    NativeQueue.move(length, current, move.index, index);
