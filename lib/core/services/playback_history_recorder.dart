import 'dart:async';

import '../models/playback_history.dart';
import '../models/playback_state.dart';
import '../models/track.dart';

/// Notified when a track has left the player, with how it left.
typedef PlaybackHistoryRecord = void Function(
  Track track,
  PlaybackHistoryOutcome outcome,
  DateTime at,
);

/// Watches the playback state stream and reports what just played.
///
/// It is a pure observer: it never touches the queue, the controller, or the
/// audio engine, and it emits nothing back into playback. That is what makes it
/// safe to add — the queue is not redesigned, its semantics are not changed,
/// and switching this off changes nothing except whether a list gets filled in.
///
/// **Why the state stream and not a callback on the controller.**
/// `JustAudioPlaybackController` already calls `onTrackCompleted` for play
/// counts, but only on a *completed* track. History wants skips too, and a skip
/// is not an event the controller raises — it is a track change. Reading the
/// state stream sees both without the controller having to grow a second
/// callback, and it works identically for every controller implementation
/// (local, cast-routing, the unsupported stub) because they all publish the
/// same [PlaybackState].
///
/// **How completed and skipped are told apart.** A normal advance never
/// publishes [PlaybackStatus.completed] — the controller goes straight to the
/// next track — so the rule cannot be "wait for a completed status". Instead
/// the outgoing track is judged on how far it actually got:
///
///  * it reached within [endTolerance] of its duration → [
///    PlaybackHistoryOutcome.completed];
///  * a [PlaybackStatus.completed] state arrived for it (the queue ran out with
///    repeat off, so there is no track change to observe) → completed, recorded
///    right then;
///  * anything else → [PlaybackHistoryOutcome.skipped].
///
/// A track that never actually started — a load that errored, a queue rebuilt
/// before audio reached it — is not recorded at all: "recently played" has to
/// mean played.
class PlaybackHistoryRecorder {
  PlaybackHistoryRecorder({
    required Stream<PlaybackState> states,
    required PlaybackHistoryRecord onPlayed,
    DateTime Function()? now,
  })  : _states = states,
        _onPlayed = onPlayed,
        _now = now ?? DateTime.now;

  /// How close to the end counts as having finished the track.
  ///
  /// Engines stop reporting positions a beat before the true end, and a track
  /// whose duration is only known approximately (a stream without a precise
  /// header) can stop a second short. Two seconds absorbs both without turning
  /// a real skip near the end into a "completed".
  static const Duration endTolerance = Duration(seconds: 2);

  final Stream<PlaybackState> _states;
  final PlaybackHistoryRecord _onPlayed;
  final DateTime Function() _now;

  StreamSubscription<PlaybackState>? _subscription;

  /// The track currently being watched, or null when nothing is loaded.
  Track? _observed;

  /// The furthest position seen for [_observed]. Furthest, not latest: seeking
  /// backwards near the end must not turn a finished track into a skip.
  Duration _furthest = Duration.zero;

  /// The last non-zero duration seen for [_observed].
  Duration _duration = Duration.zero;

  /// Whether playback ever really got going for [_observed].
  bool _started = false;

  /// Whether [_observed] has already been reported, so a completed track that
  /// is then replaced cannot be recorded twice.
  bool _reported = false;

  /// Begins observing. Idempotent: calling it twice never adds a second
  /// listener, which is what keeps this from ever double-recording.
  void start() {
    _subscription ??= _states.listen(onState);
  }

  /// Feeds one state in. Public so the transition rules can be exercised
  /// without a stream, and used by [start] as the listener.
  void onState(PlaybackState state) {
    final Track? current = state.currentTrack;
    final Track? observed = _observed;

    if (observed != null && current?.uri != observed.uri) {
      _flush();
      _begin(current);
    } else if (observed == null && current != null) {
      _begin(current);
    }
    if (_observed == null) return;

    if (state.position > _furthest) _furthest = state.position;
    if (state.duration > Duration.zero) _duration = state.duration;
    switch (state.status) {
      case PlaybackStatus.playing:
      case PlaybackStatus.paused:
      case PlaybackStatus.buffering:
      case PlaybackStatus.reconnecting:
        _started = true;
      case PlaybackStatus.completed:
        _started = true;
        // The queue ran out with repeat off: no track change will ever follow,
        // so this is the only chance to record it.
        if (!_reported) {
          _reported = true;
          _onPlayed(_observed!, PlaybackHistoryOutcome.completed, _now());
        }
      case PlaybackStatus.idle:
      case PlaybackStatus.loading:
      case PlaybackStatus.error:
        break;
    }
  }

  /// Reports the track being watched, if it earned an entry.
  void _flush() {
    final Track? outgoing = _observed;
    if (outgoing == null || _reported || !_started) return;
    _reported = true;
    _onPlayed(
      outgoing,
      _reachedEnd
          ? PlaybackHistoryOutcome.completed
          : PlaybackHistoryOutcome.skipped,
      _now(),
    );
  }

  bool get _reachedEnd =>
      _duration > Duration.zero && _furthest >= _duration - endTolerance;

  void _begin(Track? track) {
    _observed = track;
    _furthest = Duration.zero;
    _duration = Duration.zero;
    _started = false;
    _reported = false;
  }

  Future<void> dispose() async {
    final StreamSubscription<PlaybackState>? subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }
}
