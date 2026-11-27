import '../models/repeat_mode.dart';
import '../native/native_track_end.dart';

/// What the player does once the current track has finished.
enum TrackEndAction {
  /// Play the same track again from the start.
  replay,

  /// Move to the next track in the queue.
  next,

  /// Go back to the first track of the queue and play it.
  restart,

  /// Stay on the finished track; the queue is done.
  stop,
}

/// What plays when a track reaches its end. The same rule as
/// `native/linthra_core/src/track_end.rs`, held to it by the cases in
/// `test/fixtures/track_end_cases.txt`, which both replay.
///
///  - Repeat one: the same track again, whatever follows it.
///  - Repeat all: the next track, or back to the first past the end.
///  - Off: the next track, and playback stops past the end.
///
/// Decided by the Rust core.
TrackEndAction trackEndAction(RepeatMode repeat, {required bool hasNext}) =>
    TrackEndAction
        .values[NativeTrackEnd.action(repeat.index, hasNext: hasNext)];
