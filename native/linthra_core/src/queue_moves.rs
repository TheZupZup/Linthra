//! Where the queue's current track lands after a move.
//!
//! The same rule as `lib/core/models/queue_moves.dart`, held to it by the
//! cases in `test/fixtures/queue_moves_cases.txt`, which both replay. Works on
//! positions only: the queue's tracks never cross.
//!
//! The queue is `length` tracks with the current one at `current` (-1 for an
//! empty queue). Up next is everything after the current track, history
//! everything before it. A move out of range does nothing.

/// A move the listener (or the player) makes in the queue.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QueueMove {
    /// To the track after the current one.
    Next,
    /// To the track before the current one.
    Previous,
    /// Back to the first track (repeat-all past the end).
    Restart,
    /// To the track at `index` in the queue.
    MoveTo,
    /// To the track at `index` in up next.
    JumpToUpNext,
    /// To the track at `index` in history.
    JumpToHistory,
}

/// The new position of the current track, or `None` when the move does
/// nothing. `index` is only read by the moves that take one.
pub fn queue_move_target(
    length: i64,
    current: i64,
    queue_move: QueueMove,
    index: i64,
) -> Option<i64> {
    let has_current = current >= 0 && current < length;
    let up_next = if has_current { length - current - 1 } else { 0 };
    let history = if current <= 0 || current > length {
        0
    } else {
        current
    };
    match queue_move {
        QueueMove::Next => (up_next > 0).then_some(current + 1),
        QueueMove::Previous => (current > 0).then_some(current - 1),
        QueueMove::Restart => has_current.then_some(0),
        QueueMove::MoveTo => (index >= 0 && index < length).then_some(index),
        QueueMove::JumpToUpNext => (index >= 0 && index < up_next).then_some(current + 1 + index),
        QueueMove::JumpToHistory => (index >= 0 && index < history).then_some(index),
    }
}
