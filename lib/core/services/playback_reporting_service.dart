import 'dart:async';

import '../models/playback_state.dart';
import '../models/track.dart';
import 'server_playback_reporter.dart';

/// What the service last told reporters about the current track, so raw state
/// emissions (several a second while playing) collapse into the few lifecycle
/// transitions a server cares about.
enum _ReportedPhase {
  /// Nothing reported yet for this track (it may still be loading).
  none,

  /// Last report said the track is playing.
  playing,

  /// Last report said the track is paused.
  paused,

  /// Last report said playback stopped; a later play reports a fresh start.
  stopped,
}

/// Watches live playback and reports its lifecycle to the
/// [ServerPlaybackReporter] — the bridge that makes the user's own media
/// server (Plex today) show Linthra as an active player.
///
/// It listens to the unified [PlaybackState] stream and derives the few events
/// a server can use from the raw emissions:
///  - the first `playing` for a track → [ServerPlaybackReporter.onPlaybackStarted];
///  - `playing` → `paused` → [ServerPlaybackReporter.onPlaybackPaused];
///  - `paused` → `playing` → [ServerPlaybackReporter.onPlaybackResumed];
///  - steady playing → throttled [ServerPlaybackReporter.onPlaybackProgress]
///    (at most one per [progressInterval], so position ticks — up to several a
///    second — can never spam the server);
///  - idle / completed / error → [ServerPlaybackReporter.onPlaybackStopped];
///  - a queue move → [ServerPlaybackReporter.onTrackChanged] (so the outgoing
///    track's session is closed even when the next track belongs to another
///    provider — or fails to load).
///
/// `loading` and `buffering` are deliberately *not* transitions: a mid-stream
/// re-buffer keeps the session "playing" rather than flapping pause/resume,
/// and a track that never gets past loading is never reported as started.
///
/// What it deliberately does NOT do:
///  - **Never blocks or breaks playback.** Events are dispatched off the
///    playback path, strictly one at a time (so a slow report can't reorder a
///    pause behind a later progress), and every failure is swallowed —
///    reporting is best-effort by contract.
///  - **No provider knowledge, no secrets.** It hands reporters only the
///    catalog [Track] and positions; which server (if any) is told — and how
///    credentials are woven in — is entirely the reporter's business.
class PlaybackReportingService {
  PlaybackReportingService({
    required Stream<PlaybackState> playbackStates,
    required ServerPlaybackReporter reporter,
    this.progressInterval = const Duration(seconds: 10),
    DateTime Function() now = DateTime.now,
  })  : _reporter = reporter,
        _now = now {
    _subscription = playbackStates.listen(_onState);
  }

  final ServerPlaybackReporter _reporter;

  /// Minimum spacing between two progress reports for one steadily playing
  /// track. State *changes* (start/pause/resume/stop) always report
  /// immediately; only the periodic progress heartbeat is throttled.
  final Duration progressInterval;

  final DateTime Function() _now;
  late final StreamSubscription<PlaybackState> _subscription;

  Track? _track;
  _ReportedPhase _phase = _ReportedPhase.none;
  DateTime? _lastProgressAt;

  /// The last real position/duration observed for [_track]. Kept because a
  /// stop or error emits a *fresh* state whose position is zero — reporting
  /// that would tell the server the user stopped at 0:00 regardless of where
  /// they actually were.
  Duration _lastPosition = Duration.zero;
  Duration _lastDuration = Duration.zero;

  /// Pending reporter calls, dispatched strictly in order, one at a time.
  final List<Future<void> Function()> _pending = <Future<void> Function()>[];
  bool _draining = false;

  void _onState(PlaybackState state) {
    final Track? track = state.currentTrack;
    final Track? previous = _track;

    if (track?.id != previous?.id) {
      // The queue moved (skip, natural advance, or cleared to nothing). Tell
      // reporters even when the new track never starts, so the outgoing
      // track's session is always closed.
      if (previous != null && _isActive) {
        final Track? next = track;
        _enqueue(() => _reporter.onTrackChanged(previous, next));
      }
      _track = track;
      _phase = _ReportedPhase.none;
      _lastPosition = Duration.zero;
      _lastDuration = Duration.zero;
    }

    final Track? current = _track;
    if (current == null) return;

    // Prefer the engine's live values; fall back to the catalog's duration
    // (and the last observed position for the zeroed stop/error states).
    final Duration duration =
        state.duration > Duration.zero ? state.duration : current.duration;
    if (state.position > Duration.zero) _lastPosition = state.position;
    if (duration > Duration.zero) _lastDuration = duration;

    switch (state.status) {
      case PlaybackStatus.playing:
        final Duration position = state.position;
        switch (_phase) {
          case _ReportedPhase.none:
          case _ReportedPhase.stopped:
            _phase = _ReportedPhase.playing;
            _lastProgressAt = _now();
            _enqueue(
                () => _reporter.onPlaybackStarted(current, position, duration));
          case _ReportedPhase.paused:
            _phase = _ReportedPhase.playing;
            _lastProgressAt = _now();
            _enqueue(
                () => _reporter.onPlaybackResumed(current, position, duration));
          case _ReportedPhase.playing:
            final DateTime now = _now();
            final DateTime? last = _lastProgressAt;
            if (last == null || now.difference(last) >= progressInterval) {
              _lastProgressAt = now;
              _enqueue(() =>
                  _reporter.onPlaybackProgress(current, position, duration));
            }
        }
      case PlaybackStatus.paused:
        if (_phase == _ReportedPhase.playing) {
          final Duration position = state.position;
          _phase = _ReportedPhase.paused;
          _enqueue(
              () => _reporter.onPlaybackPaused(current, position, duration));
        }
      case PlaybackStatus.idle:
      case PlaybackStatus.completed:
      case PlaybackStatus.error:
        if (_isActive) {
          // stop() and an error emit a fresh, zero-position state; report the
          // last position actually observed so the server settles honestly.
          final Duration position = _lastPosition;
          final Duration lastDuration = _lastDuration;
          _phase = _ReportedPhase.stopped;
          _enqueue(() =>
              _reporter.onPlaybackStopped(current, position, lastDuration));
        }
      case PlaybackStatus.loading:
      case PlaybackStatus.buffering:
        // Indeterminate: keep the last reported phase. A re-buffer stays
        // "playing"; a fresh load reports nothing until it actually plays.
        break;
    }
  }

  /// Whether the server currently believes this track has an open session.
  bool get _isActive =>
      _phase == _ReportedPhase.playing || _phase == _ReportedPhase.paused;

  void _enqueue(Future<void> Function() report) {
    _pending.add(report);
    unawaited(_drain());
  }

  /// Dispatches pending reports strictly in order, one at a time, so a slow
  /// network call can never deliver a pause after a later progress. Failures
  /// are swallowed: reporting must never disturb playback or later reports.
  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_pending.isNotEmpty) {
        final Future<void> Function() report = _pending.removeAt(0);
        try {
          await report();
        } catch (_) {
          // Best-effort by contract; the next report still goes out.
        }
      }
    } finally {
      _draining = false;
    }
  }

  /// Stops listening. If a session was open, a final best-effort stop is
  /// reported so the server doesn't keep showing a phantom player.
  Future<void> dispose() async {
    await _subscription.cancel();
    final Track? track = _track;
    if (track != null && _isActive) {
      final Duration position = _lastPosition;
      final Duration duration = _lastDuration;
      _phase = _ReportedPhase.stopped;
      _enqueue(() => _reporter.onPlaybackStopped(track, position, duration));
    }
  }
}
