import 'dart:async';
import 'dart:math';

import 'package:linthra/core/models/playback_queue.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/local_playback_controller.dart';

/// In-memory [LocalPlaybackController] for widget/provider tests.
///
/// Records the calls it receives, maintains a real [PlaybackQueue] so queue
/// flows behave like the production controller, and lets a test push arbitrary
/// [PlaybackState]s — all without `just_audio` or any platform plugin. It also
/// honours [suspend]/[resume] so it can stand in as the local engine behind an
/// [ActivePlaybackController] in cast-routing tests: while suspended, queue
/// changes update the current track without "playing" locally.
class FakePlaybackController implements LocalPlaybackController {
  FakePlaybackController({PlaybackState initial = PlaybackState.idle})
      : _state = initial;

  final StreamController<PlaybackState> _states =
      StreamController<PlaybackState>.broadcast();
  PlaybackState _state;
  PlaybackQueue _queue = PlaybackQueue.empty;
  bool _shuffleEnabled = false;
  RepeatMode _repeatMode = RepeatMode.off;
  bool _suspended = false;

  /// Seeded so shuffle is deterministic across test runs.
  final Random _random = Random(1);

  final List<Track> playedTracks = <Track>[];
  int playCount = 0;
  int pauseCount = 0;
  int stopCount = 0;
  int skipCount = 0;
  int previousCount = 0;
  int clearCount = 0;
  int suspendCount = 0;
  int resumeCount = 0;
  int restartQueueCount = 0;
  Duration? lastResumeAt;
  bool? lastResumePlay;
  bool disposed = false;
  final List<Duration> seeks = <Duration>[];

  /// Pushes [next] to listeners and updates the synchronous [state].
  void emit(PlaybackState next) {
    _state = next;
    _states.add(next);
  }

  @override
  PlaybackState get state => _state;

  @override
  Stream<PlaybackState> get stateStream => _states.stream;

  @override
  Future<void> playTrack(Track track) => playTracks(<Track>[track]);

  @override
  Future<void> playTracks(List<Track> tracks, {int startIndex = 0}) async {
    var queue = PlaybackQueue.of(tracks, startIndex: startIndex);
    if (_shuffleEnabled) queue = queue.shuffled(_random);
    _queue = queue;
    _playCurrent();
  }

  @override
  void playNext(Track track) {
    _queue = _queue.enqueueNext(track);
    emit(_state.copyWith(upNext: _queue.upNext));
  }

  @override
  Future<void> skipToNext() async {
    skipCount++;
    if (!_queue.hasNext) return;
    _queue = _queue.next();
    _playCurrent();
  }

  @override
  Future<void> skipToPrevious() async {
    previousCount++;
    if (!_queue.hasPrevious) return;
    _queue = _queue.previous();
    _playCurrent();
  }

  @override
  void clearQueue() {
    clearCount++;
    _queue = _queue.cleared();
    emit(_state.copyWith(upNext: _queue.upNext, hasPrevious: false));
  }

  @override
  void setShuffleEnabled(bool enabled) {
    if (enabled == _shuffleEnabled) return;
    _shuffleEnabled = enabled;
    _queue = enabled ? _queue.shuffled(_random) : _queue.unshuffled();
    emit(_state.copyWith(
      upNext: _queue.upNext,
      hasPrevious: _queue.hasPrevious,
      shuffleEnabled: _shuffleEnabled,
    ));
  }

  @override
  void setRepeatMode(RepeatMode mode) {
    if (mode == _repeatMode) return;
    _repeatMode = mode;
    emit(_state.copyWith(repeatMode: _repeatMode));
  }

  /// Test seam mirroring the production controller's completion handling: drives
  /// what plays when the current track finishes, honouring the repeat mode.
  void completeCurrent() {
    switch (_repeatMode) {
      case RepeatMode.one:
        _playCurrent();
      case RepeatMode.all:
        _queue = _queue.hasNext ? _queue.next() : _queue.restarted();
        _playCurrent();
      case RepeatMode.off:
        if (_queue.hasNext) {
          _queue = _queue.next();
          _playCurrent();
        } else {
          emit(_state.copyWith(status: PlaybackStatus.completed));
        }
    }
  }

  void _playCurrent() {
    final track = _queue.current;
    if (track == null) return;
    if (_suspended) {
      // A cast output owns audio: reflect the queue/track without "playing"
      // locally, mirroring the real controller's suspended path.
      emit(PlaybackState(
        status: PlaybackStatus.paused,
        currentTrack: track,
        upNext: _queue.upNext,
        hasPrevious: _queue.hasPrevious,
        shuffleEnabled: _shuffleEnabled,
        repeatMode: _repeatMode,
      ));
      return;
    }
    playedTracks.add(track);
    final playing = PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: track,
      upNext: _queue.upNext,
      hasPrevious: _queue.hasPrevious,
      shuffleEnabled: _shuffleEnabled,
      repeatMode: _repeatMode,
    );
    emit(playing);
  }

  @override
  bool get isSuspended => _suspended;

  @override
  Future<void> suspend() async {
    suspendCount++;
    _suspended = true;
  }

  @override
  Future<void> resume({Duration at = Duration.zero, bool play = false}) async {
    resumeCount++;
    lastResumeAt = at;
    lastResumePlay = play;
    _suspended = false;
    _playCurrent();
  }

  @override
  Future<void> restartQueue() async {
    restartQueueCount++;
    _queue = _queue.restarted();
    _playCurrent();
  }

  @override
  Future<void> play() async {
    playCount++;
  }

  @override
  Future<void> pause() async {
    pauseCount++;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _states.close();
  }
}
