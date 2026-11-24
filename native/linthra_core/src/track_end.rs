//! What plays when a track reaches its end.
//!
//! The same rule as `lib/core/services/track_end.dart`, held to it by the
//! cases in `test/fixtures/track_end_cases.txt`, which both replay.
//!
//!  - Repeat one: the same track again, whatever follows it.
//!  - Repeat all: the next track, or back to the first past the end.
//!  - Off: the next track, and playback stops past the end.

/// `RepeatMode` in Dart.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RepeatMode {
    Off,
    All,
    One,
}

/// What the player does once the current track has finished.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrackEndAction {
    /// Play the same track again from the start.
    Replay,
    /// Move to the next track in the queue.
    Next,
    /// Go back to the first track of the queue and play it.
    Restart,
    /// Stay on the finished track; the queue is done.
    Stop,
}

pub fn track_end_action(repeat: RepeatMode, has_next: bool) -> TrackEndAction {
    match repeat {
        RepeatMode::One => TrackEndAction::Replay,
        _ if has_next => TrackEndAction::Next,
        RepeatMode::All => TrackEndAction::Restart,
        RepeatMode::Off => TrackEndAction::Stop,
    }
}
