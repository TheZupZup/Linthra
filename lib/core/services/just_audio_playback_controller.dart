import 'dart:async';

import 'package:just_audio/just_audio.dart';

import '../models/playback_queue.dart';
import '../models/playback_state.dart';
import '../models/track.dart';
import 'playback_controller.dart';

/// [PlaybackController] backed by `just_audio`.
///
/// This is the only file in the app that knows `just_audio` exists. It adapts
/// the player's separate event streams (state, position, duration) into the
/// single immutable [PlaybackState] the UI renders from. Swapping the engine or
/// wrapping it for background playback later means replacing this class, not
/// the feature code.
class JustAudioPlaybackController implements PlaybackController {
  JustAudioPlaybackController({AudioPlayer? player})
      : _player = player ?? AudioPlayer() {
    _wire();
  }

  final AudioPlayer _player;
  final StreamController<PlaybackState> _states =
      StreamController<PlaybackState>.broadcast();
  final List<StreamSubscription<void>> _subscriptions =
      <StreamSubscription<void>>[];

  PlaybackState _state = PlaybackState.idle;
  PlaybackQueue _queue = PlaybackQueue.empty;

  @override
  PlaybackState get state => _state;

  @override
  Stream<PlaybackState> get stateStream => _states.stream;

  void _wire() {
    _subscriptions.add(_player.playerStateStream.listen((playerState) {
      final status = _statusFor(playerState);
      // When a track finishes, roll into the next one if the queue has more.
      if (status == PlaybackStatus.completed && _queue.hasNext) {
        skipToNext();
        return;
      }
      _emit(_state.copyWith(status: status));
    }));
    _subscriptions.add(_player.positionStream.listen((position) {
      _emit(_state.copyWith(position: position));
    }));
    _subscriptions.add(_player.durationStream.listen((duration) {
      if (duration != null) _emit(_state.copyWith(duration: duration));
    }));
  }

  static PlaybackStatus _statusFor(PlayerState playerState) {
    switch (playerState.processingState) {
      case ProcessingState.idle:
        return PlaybackStatus.idle;
      case ProcessingState.loading:
      case ProcessingState.buffering:
        return PlaybackStatus.loading;
      case ProcessingState.ready:
        return playerState.playing
            ? PlaybackStatus.playing
            : PlaybackStatus.paused;
      case ProcessingState.completed:
        return PlaybackStatus.completed;
    }
  }

  void _emit(PlaybackState next) {
    if (next == _state) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  @override
  Future<void> playTrack(Track track) => playTracks(<Track>[track]);

  @override
  Future<void> playTracks(List<Track> tracks, {int startIndex = 0}) {
    _queue = PlaybackQueue.of(tracks, startIndex: startIndex);
    return _playCurrent();
  }

  @override
  void playNext(Track track) {
    _queue = _queue.enqueueNext(track);
    // The current track keeps playing; only the up-next list changes.
    _emit(_state.copyWith(upNext: _queue.upNext));
  }

  @override
  Future<void> skipToNext() async {
    if (!_queue.hasNext) return;
    _queue = _queue.next();
    await _playCurrent();
  }

  @override
  Future<void> skipToPrevious() async {
    if (!_queue.hasPrevious) return;
    _queue = _queue.previous();
    await _playCurrent();
  }

  @override
  void clearQueue() {
    _queue = _queue.cleared();
    _emit(_state.copyWith(upNext: _queue.upNext, hasPrevious: false));
  }

  /// Loads and plays the queue's current track, surfacing its up-next list.
  Future<void> _playCurrent() async {
    final track = _queue.current;
    if (track == null) return;
    // Reset position/duration up front so the UI doesn't show the previous
    // track's progress while the new one loads.
    final loading = PlaybackState(
      status: PlaybackStatus.loading,
      currentTrack: track,
      upNext: _queue.upNext,
      hasPrevious: _queue.hasPrevious,
    );
    _emit(loading);
    try {
      // Track.uri is a local file path (see LocalTrackMapper); remote sources
      // arrive in a later PR.
      await _player.setFilePath(track.uri);
      // play()'s future completes when playback ends, so we don't await it.
      unawaited(_player.play());
    } catch (_) {
      _emit(_state.copyWith(status: PlaybackStatus.error));
    }
  }

  @override
  Future<void> play() async {
    // play()'s future completes when playback ends, so we don't await it.
    unawaited(_player.play());
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    final stopped = PlaybackState(
      currentTrack: _state.currentTrack,
      upNext: _queue.upNext,
      hasPrevious: _queue.hasPrevious,
    );
    _emit(stopped);
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _states.close();
    await _player.dispose();
  }
}
