/// How playback behaves when the current track (or the whole queue) finishes.
///
/// Kept in the model layer, decoupled from any audio package, so both the
/// [PlaybackController] and the UI share one definition. The cycling order the
/// repeat button steps through also lives here ([next]) rather than in a widget,
/// keeping playback policy out of presentation code.
enum RepeatMode {
  /// Play to the end of the queue and stop.
  off,

  /// At the end of the queue, wrap back to the first track.
  all,

  /// Replay the current track indefinitely.
  one;

  /// The mode the repeat button advances to: off → all → one → off.
  RepeatMode get next {
    switch (this) {
      case RepeatMode.off:
        return RepeatMode.all;
      case RepeatMode.all:
        return RepeatMode.one;
      case RepeatMode.one:
        return RepeatMode.off;
    }
  }
}
