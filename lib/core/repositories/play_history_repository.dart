import '../models/play_history.dart';
import '../models/track.dart';

/// Records and exposes the user's on-device playback history.
///
/// The player records a completed play through [recordCompletion] (called when
/// a track reaches its end); the UI reads [historyStream] to power the
/// "Recently played", "Most played", and "Never played" smart mixes — never
/// touching the backing store directly, mirroring how the player reads a
/// `PlaybackState` and never the audio engine.
///
/// Privacy invariant: only the track *id* is recorded — never its uri, a token,
/// or an authenticated URL — and the history stays on the device (no telemetry,
/// no server upload).
abstract interface class PlayHistoryRepository {
  /// Emits the current history immediately, then on every recorded play.
  Stream<PlayHistory> get historyStream;

  /// The latest known history, for synchronous reads on first build.
  PlayHistory get current;

  /// Records that [track] finished playing: increments its play count and sets
  /// its last-played time to now. Only [Track.id] is read. Never throws.
  Future<void> recordCompletion(Track track);
}
