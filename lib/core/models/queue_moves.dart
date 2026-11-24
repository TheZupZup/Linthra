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
/// The same rule as `native/linthra_core/src/queue_moves.rs`, held to it by
/// `test/fixtures/queue_moves_cases.txt`. Decided by the Rust core when the
/// build has it; [useNative] false always takes the Dart path, for tests.
int? queueMoveTarget(
  QueueMove move, {
  required int length,
  required int current,
  int index = 0,
  bool useNative = true,
}) {
  if (useNative) {
    final ({int? target})? native =
        NativeQueue.move(length, current, move.index, index);
    if (native != null) return native.target;
  }
  final bool hasCurrent = current >= 0 && current < length;
  final int upNext = hasCurrent ? length - current - 1 : 0;
  final int history = current <= 0 || current > length ? 0 : current;
  switch (move) {
    case QueueMove.next:
      return upNext > 0 ? current + 1 : null;
    case QueueMove.previous:
      return current > 0 ? current - 1 : null;
    case QueueMove.restart:
      return hasCurrent ? 0 : null;
    case QueueMove.moveTo:
      return index >= 0 && index < length ? index : null;
    case QueueMove.jumpToUpNext:
      return index >= 0 && index < upNext ? current + 1 + index : null;
    case QueueMove.jumpToHistory:
      return index >= 0 && index < history ? index : null;
  }
}

/// Shuffles [items] in place with Fisher-Yates driven by splitmix64, so the
/// Rust core (`shuffle_in_place` in queue_edits.rs) gives the same order for
/// the same [seed]. Dart ints wrap at 64 bits, as the Rust side's wrapping
/// arithmetic does.
void shuffleWithSeed<T>(List<T> items, int seed) {
  int state = seed;
  for (int i = items.length - 1; i >= 1; i--) {
    state += 0x9E3779B97F4A7C15;
    int z = state;
    z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >>> 27)) * 0x94D049BB133111EB;
    z ^= z >>> 31;
    final int j = (z >>> 1) % (i + 1);
    final T held = items[i];
    items[i] = items[j];
    items[j] = held;
  }
}
