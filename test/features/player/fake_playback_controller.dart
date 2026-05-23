import 'dart:async';

import 'package:sonara/core/models/playback_queue.dart';
import 'package:sonara/core/models/playback_state.dart';
import 'package:sonara/core/models/track.dart';
import 'package:sonara/core/services/playback_controller.dart';

/// In-memory [PlaybackController] for widget/provider tests.
///
/// Records the calls it receives, maintains a real [PlaybackQueue] so queue
/// flows behave like the production controller, and lets a test push arbitrary
/// [PlaybackState]s — all without `just_audio` or any platform plugin.
class FakePlaybackController implements PlaybackController {
  FakePlaybackController({PlaybackState initial = PlaybackState.idle})
      : _state = initial;

  final StreamController<PlaybackState> _states =
      StreamController<PlaybackState>.broadcast();
  PlaybackState _state;
  PlaybackQueue _queue = PlaybackQueue.empty;

  final List<Track> playedTracks = <Track>[];
  int playCount = 0;
  int pauseCount = 0;
  int stopCount = 0;
  int skipCount = 0;
  int clearCount = 0;
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
    _queue = PlaybackQueue.of(tracks, startIndex: startIndex);
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
  void clearQueue() {
    clearCount++;
    _queue = _queue.cleared();
    emit(_state.copyWith(upNext: _queue.upNext));
  }

  void _playCurrent() {
    final track = _queue.current;
    if (track == null) return;
    playedTracks.add(track);
    final playing = PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: track,
      upNext: _queue.upNext,
    );
    emit(playing);
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
    await _states.close();
  }
}
