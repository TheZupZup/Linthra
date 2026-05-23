import 'dart:async';

import 'package:audio_service/audio_service.dart' as audio;

import '../models/playback_state.dart';
import '../models/track.dart';
import 'playback_controller.dart';

/// Bridges the app's [PlaybackController] to the platform media session via
/// `audio_service`. This is the only file in the app that knows
/// `audio_service` exists.
///
/// It is a thin infrastructure adapter, deliberately *not* a second playback
/// engine: it forwards media-session commands (play/pause/stop/skip) to the
/// controller and mirrors the controller's [PlaybackState] back out as
/// audio_service playback state + media item, so the notification, lock screen,
/// and Android Auto reflect what is playing. The controller stays the single
/// source of truth and owns `just_audio`; the UI never touches this class.
class LinthraAudioHandler extends audio.BaseAudioHandler {
  LinthraAudioHandler(this._controller) {
    _subscription = _controller.stateStream.listen(_broadcast);
    // Seed the session from the latest known state so a freshly attached
    // notification/Android Auto isn't blank before the first stream event.
    _broadcast(_controller.state);
  }

  final PlaybackController _controller;
  late final StreamSubscription<PlaybackState> _subscription;

  @override
  Future<void> play() => _controller.play();

  @override
  Future<void> pause() => _controller.pause();

  @override
  Future<void> stop() async {
    await _controller.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() => _controller.skipToNext();

  @override
  Future<void> seek(Duration position) => _controller.seek(position);

  void _broadcast(PlaybackState state) {
    final track = state.currentTrack;
    mediaItem.add(track == null ? null : _mediaItemFor(track, state));
    playbackState.add(_playbackStateFor(state));
  }

  audio.MediaItem _mediaItemFor(Track track, PlaybackState state) {
    // Prefer the live duration the engine reported; fall back to the track's
    // catalog duration, and omit it entirely when unknown.
    final live = state.duration;
    final duration = live > Duration.zero ? live : track.duration;
    return audio.MediaItem(
      id: track.id,
      title: track.title,
      artist: track.artistName,
      album: track.albumName,
      duration: duration > Duration.zero ? duration : null,
      artUri: track.artworkUri,
    );
  }

  audio.PlaybackState _playbackStateFor(PlaybackState state) {
    return audio.PlaybackState(
      controls: _controlsFor(state),
      systemActions: const <audio.MediaAction>{audio.MediaAction.seek},
      processingState: _processingStateFor(state.status),
      playing: state.isPlaying,
      updatePosition: state.position,
    );
  }

  List<audio.MediaControl> _controlsFor(PlaybackState state) {
    return <audio.MediaControl>[
      state.isPlaying ? audio.MediaControl.pause : audio.MediaControl.play,
      audio.MediaControl.stop,
      if (state.hasNext) audio.MediaControl.skipToNext,
    ];
  }

  audio.AudioProcessingState _processingStateFor(PlaybackStatus status) {
    switch (status) {
      case PlaybackStatus.idle:
        return audio.AudioProcessingState.idle;
      case PlaybackStatus.loading:
        return audio.AudioProcessingState.loading;
      case PlaybackStatus.playing:
      case PlaybackStatus.paused:
        return audio.AudioProcessingState.ready;
      case PlaybackStatus.completed:
        return audio.AudioProcessingState.completed;
      case PlaybackStatus.error:
        return audio.AudioProcessingState.error;
    }
  }

  /// Stops mirroring controller state. Call before disposing the controller.
  Future<void> dispose() => _subscription.cancel();
}

/// Registers [controller] with the platform media session so playback appears
/// in the notification / lock screen and is reachable from Android Auto.
///
/// Best-effort by design: returns `null` when `audio_service` can't initialise
/// (a platform without the native setup, or a test environment). Playback still
/// works through the controller in that case, so a missing media session never
/// breaks basic playback.
Future<LinthraAudioHandler?> connectMediaSession(
  PlaybackController controller,
) async {
  try {
    return await audio.AudioService.init(
      builder: () => LinthraAudioHandler(controller),
      config: const audio.AudioServiceConfig(
        androidNotificationChannelId: 'com.linthra.audio',
        androidNotificationChannelName: 'Linthra playback',
        androidNotificationOngoing: true,
      ),
    );
  } catch (_) {
    return null;
  }
}
