import 'dart:async';

import '../models/active_playback_output.dart';
import '../models/cast_playback_status.dart';
import '../models/cast_state.dart';
import '../models/playback_state.dart';
import '../models/repeat_mode.dart';
import '../models/track.dart';
import 'cast/cast_service.dart';
import 'local_playback_controller.dart';
import 'playback_controller.dart';
import 'stability_diagnostics.dart';

/// The single [PlaybackController] the UI talks to, routing between the
/// on-device engine and a cast receiver and presenting *one* unified
/// [PlaybackState].
///
/// This is the seam that fixes cast desync: the now-playing screen, mini-player,
/// and lyrics read only from here, never from `just_audio` or the cast SDK
/// directly. It keeps a single source of truth by:
///  - delegating the queue (current track, up-next, shuffle, repeat) to the
///    local [LocalPlaybackController], which owns it regardless of output;
///  - folding the receiver's position/play-state/duration onto that queue while
///    casting, so the UI follows the *device* rather than the silenced engine;
///  - routing transport commands (play/pause/seek) to whichever output is
///    active, and queue commands (skip/playTracks) always to the local
///    controller — whose track changes the cast service mirrors onto the
///    receiver.
///
/// It owns the local-vs-cast switch too: when [CastState.isCasting] turns on it
/// [LocalPlaybackController.suspend]s the engine; when it turns off it
/// [LocalPlaybackController.resume]s **paused** at the receiver's last position,
/// so ending a cast session (or a dropped one) never surprise-starts the phone.
class ActivePlaybackController implements PlaybackController {
  ActivePlaybackController({
    required LocalPlaybackController local,
    required CastService cast,
  })  : _local = local,
        _cast = cast {
    _output = _cast.state.isCasting
        ? ActivePlaybackOutput.cast
        : ActivePlaybackOutput.local;
    _castStatus = _cast.playbackStatus;
    _lastEmitted = _merge();
    _localSub = _local.stateStream.listen(_onLocalState);
    _castStateSub = _cast.stateStream.listen(_onCastState);
    _castPlaybackSub = _cast.playbackStream.listen(_onCastStatus);
  }

  final LocalPlaybackController _local;
  final CastService _cast;

  final StreamController<PlaybackState> _states =
      StreamController<PlaybackState>.broadcast();
  late StreamSubscription<PlaybackState> _localSub;
  late StreamSubscription<CastState> _castStateSub;
  late StreamSubscription<CastPlaybackStatus> _castPlaybackSub;

  ActivePlaybackOutput _output = ActivePlaybackOutput.local;
  CastPlaybackStatus _castStatus = CastPlaybackStatus.idle;

  // Wall-clock anchor for the last cast status, so position can be interpolated
  // smoothly between the receiver's (roughly once-a-second) status pushes.
  DateTime? _castAnchoredAt;
  Timer? _ticker;
  bool _castWasCompleted = false;

  late PlaybackState _lastEmitted;

  /// Which output is producing sound right now. The UI reads this to show a
  /// "Casting to …" affordance instead of a local source badge.
  ActivePlaybackOutput get activeOutput => _output;

  bool get _casting => _output == ActivePlaybackOutput.cast;

  @override
  PlaybackState get state => _merge();

  @override
  Stream<PlaybackState> get stateStream => _states.stream;

  /// Folds the active output onto one state: the queue/track always come from
  /// the local controller; while casting the playback fields come from the
  /// receiver.
  PlaybackState _merge() {
    final PlaybackState base = _local.state;
    if (!_casting) return base;
    final Duration duration = _castStatus.duration > Duration.zero
        ? _castStatus.duration
        : (base.currentTrack?.duration ?? base.duration);
    return base.copyWith(
      status: _castStatus.status,
      position: _interpolatedCastPosition(),
      duration: duration,
    );
  }

  /// The receiver's reported position, advanced by wall-clock time while it is
  /// playing so progress (and lyrics) move smoothly between status pushes.
  Duration _interpolatedCastPosition() {
    if (_castStatus.status != PlaybackStatus.playing) {
      return _castStatus.position;
    }
    final DateTime? anchor = _castAnchoredAt;
    if (anchor == null) return _castStatus.position;
    Duration position =
        _castStatus.position + DateTime.now().difference(anchor);
    final Duration duration = _castStatus.duration;
    if (duration > Duration.zero && position > duration) position = duration;
    return position;
  }

  void _emitMerged() {
    final PlaybackState next = _merge();
    // PlaybackState == leans on Track == (bare id), so a same-bare-id provider
    // swap (a retry/fallback from jellyfin:101 to subsonic:101, same status and
    // source) compares equal even though a different copy is now current.
    // Compare the current uri too, so that swap still reaches UI/reporting
    // instead of being suppressed by this guard.
    if (next == _lastEmitted &&
        next.currentTrack?.uri == _lastEmitted.currentTrack?.uri) {
      return;
    }
    _lastEmitted = next;
    if (!_states.isClosed) _states.add(next);
  }

  void _onLocalState(PlaybackState _) => _emitMerged();

  void _onCastState(CastState state) {
    final bool shouldCast = state.isCasting;
    if (shouldCast && _output == ActivePlaybackOutput.local) {
      // A handoff began: the receiver is the active output. Silence the engine
      // so audio isn't heard twice; the queue stays owned locally.
      _output = ActivePlaybackOutput.cast;
      StabilityDiagnostics.output('cast');
      unawaited(_local.suspend());
    } else if (!shouldCast && _output == ActivePlaybackOutput.cast) {
      // The session ended (user disconnect or a dropped receiver). Return to the
      // device at the receiver's last position, *paused*, so nothing
      // surprise-starts; the user can press play to continue here.
      final Duration resumeAt = _interpolatedCastPosition();
      _output = ActivePlaybackOutput.local;
      StabilityDiagnostics.output('local');
      _castStatus = CastPlaybackStatus.idle;
      _castAnchoredAt = null;
      _castWasCompleted = false;
      unawaited(_local.resume(at: resumeAt, play: false));
    }
    _syncTicker();
    _emitMerged();
  }

  void _onCastStatus(CastPlaybackStatus status) {
    _castStatus = status;
    _castAnchoredAt = DateTime.now();
    _handleCastCompletion(status);
    _syncTicker();
    if (_casting) _emitMerged();
  }

  /// When a cast track finishes, advance the queue the same way local playback
  /// would: repeat-one replays on the receiver, repeat-all/off advance (wrapping
  /// for repeat-all), and the cast service re-loads the new current track.
  void _handleCastCompletion(CastPlaybackStatus status) {
    final bool completed = status.status == PlaybackStatus.completed;
    final bool wasCompleted = _castWasCompleted;
    _castWasCompleted = completed;
    if (!_casting || !completed || wasCompleted) return;

    final PlaybackState local = _local.state;
    switch (local.repeatMode) {
      case RepeatMode.one:
        unawaited(_cast.seek(Duration.zero).then((_) => _cast.play()));
      case RepeatMode.all:
        if (local.hasNext) {
          unawaited(_local.skipToNext());
        } else {
          unawaited(_local.restartQueue());
        }
      case RepeatMode.off:
        if (local.hasNext) unawaited(_local.skipToNext());
    }
  }

  /// Runs a light ticker only while a cast track is actively playing, to push
  /// interpolated position updates for smooth progress/lyrics.
  void _syncTicker() {
    final bool shouldTick =
        _casting && _castStatus.status == PlaybackStatus.playing;
    if (shouldTick && _ticker == null) {
      _ticker = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => _emitMerged(),
      );
    } else if (!shouldTick && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  /// Handles the app returning to the foreground. While casting, re-syncs from
  /// the receiver. Otherwise runs the local engine's audio-focus safety restore
  /// — undoing any lingering duck and resuming only a transient-focus-loss pause
  /// — so a voice/mic session in another app that ended without a clean focus
  /// gain can't leave Linthra stuck silent or ducked.
  void onAppResumed() {
    if (_casting) {
      unawaited(_cast.refresh());
    } else {
      _local.onAppForegrounded();
    }
  }

  // --- Transport commands route to the active output ----------------------

  @override
  Future<void> play() => _casting ? _cast.play() : _local.play();

  @override
  Future<void> pause() => _casting ? _cast.pause() : _local.pause();

  @override
  Future<void> seek(Duration position) =>
      _casting ? _cast.seek(position) : _local.seek(position);

  @override
  Future<void> stop() => _local.stop();

  // --- Queue commands always go to the local controller (the queue owner) --
  // While casting it is suspended, so these update the current track/up-next
  // without local audio; the cast service mirrors the change onto the receiver.

  @override
  Future<void> playTrack(Track track) => _local.playTrack(track);

  @override
  Future<void> playTracks(List<Track> tracks, {int startIndex = 0}) =>
      _local.playTracks(tracks, startIndex: startIndex);

  @override
  void playNext(Track track) => _local.playNext(track);

  @override
  void addToQueue(Track track) => _local.addToQueue(track);

  @override
  void removeFromQueue(int upNextIndex) => _local.removeFromQueue(upNextIndex);

  @override
  void reorderQueue(int oldIndex, int newIndex) =>
      _local.reorderQueue(oldIndex, newIndex);

  @override
  Future<void> playFromQueue(int upNextIndex) =>
      _local.playFromQueue(upNextIndex);

  @override
  Future<void> playFromHistory(int previousIndex) =>
      _local.playFromHistory(previousIndex);

  @override
  Future<void> skipToNext() => _local.skipToNext();

  @override
  Future<void> skipToPrevious() => _local.skipToPrevious();

  @override
  void clearQueue() => _local.clearQueue();

  @override
  void setShuffleEnabled(bool enabled) => _local.setShuffleEnabled(enabled);

  @override
  void setRepeatMode(RepeatMode mode) => _local.setRepeatMode(mode);

  @override
  Future<void> dispose() async {
    _ticker?.cancel();
    _ticker = null;
    await _localSub.cancel();
    await _castStateSub.cancel();
    await _castPlaybackSub.cancel();
    await _states.close();
    // The local controller and cast service are owned by their own providers,
    // which dispose them; this controller only owns its own subscriptions.
  }
}
