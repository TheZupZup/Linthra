import 'dart:async';

import 'package:just_audio/just_audio.dart';

import '../models/playback_queue.dart';
import '../models/playback_state.dart';
import '../models/track.dart';
import 'local_playable_uri_resolver.dart';
import 'playable_uri_resolver.dart';
import 'playback_controller.dart';

/// [PlaybackController] backed by `just_audio`.
///
/// This is the only file in the app that knows `just_audio` exists. It adapts
/// the player's separate event streams (state, position, duration) into the
/// single immutable [PlaybackState] the UI renders from. Swapping the engine or
/// wrapping it for background playback later means replacing this class, not
/// the feature code.
///
/// It opens whatever URI a [PlayableUriResolver] returns rather than assuming a
/// local file path, so local files, Android SAF content URIs, and remote
/// (Jellyfin) streams all play through the same path. The default resolver
/// handles only on-device tracks; remote resolution is composed in at the
/// provider layer, keeping this class free of any source-specific knowledge.
class JustAudioPlaybackController implements PlaybackController {
  JustAudioPlaybackController({
    AudioPlayer? player,
    PlayableUriResolver resolver = const LocalPlayableUriResolver(),
  })  : _player = player ?? AudioPlayer(),
        _resolver = resolver {
    _wire();
  }

  final AudioPlayer _player;
  final PlayableUriResolver _resolver;
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
  ///
  /// Resolution (local path / content URI / remote stream) happens through the
  /// [PlayableUriResolver]. A resolution failure carries its own friendly,
  /// secret-free message; a load failure after a successful resolve falls back
  /// to a generic one.
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

    final Uri uri;
    try {
      uri = await _resolver.resolve(track);
    } on PlaybackResolutionException catch (error) {
      _emitError(track, error.message);
      return;
    } catch (_) {
      _emitError(track, _genericPlaybackError);
      return;
    }

    try {
      // setUrl handles file://, content:// (Android), and https:// URIs alike,
      // so local files, SAF documents, and Jellyfin streams share one path.
      await _player.setUrl(uri.toString());
      // play()'s future completes when playback ends, so we don't await it.
      unawaited(_player.play());
    } catch (_) {
      _emitError(track, _genericPlaybackError);
    }
  }

  static const String _genericPlaybackError = "Couldn't play this track.";

  /// Emits an error state for [track] carrying a friendly [message], preserving
  /// the queue context so the UI keeps showing the right track and up-next.
  void _emitError(Track track, String message) {
    _emit(PlaybackState(
      status: PlaybackStatus.error,
      currentTrack: track,
      upNext: _queue.upNext,
      hasPrevious: _queue.hasPrevious,
      errorMessage: message,
    ));
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
