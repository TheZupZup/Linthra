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
/// Decided by the Rust core when the build has it. [useNative] false always
/// takes the Dart path, for tests.
TrackEndAction trackEndAction(
  RepeatMode repeat, {
  required bool hasNext,
  bool useNative = true,
}) {
  if (useNative) {
    final int? native = NativeTrackEnd.action(repeat.index, hasNext: hasNext);
    if (native != null) return TrackEndAction.values[native];
  }
  if (repeat == RepeatMode.one) return TrackEndAction.replay;
  if (hasNext) return TrackEndAction.next;
  return repeat == RepeatMode.all
      ? TrackEndAction.restart
      : TrackEndAction.stop;
}
