import 'dart:async';

import 'package:audio_service/audio_service.dart' as audio;

import '../models/playback_state.dart';
import '../models/track.dart';
import '../repositories/music_library_repository.dart';
import 'media_browser_tree.dart';
import 'playback_controller.dart';

/// Bridges the app's [PlaybackController] to the platform media session via
/// `audio_service`. This is the only file in the app that knows
/// `audio_service` exists.
///
/// It is a thin infrastructure adapter, deliberately *not* a second playback
/// engine: it forwards media-session commands (play/pause/stop/skip) to the
/// controller and mirrors the controller's [PlaybackState] back out as
/// audio_service playback state + media item, so the notification, lock screen,
/// and Android Auto reflect what is playing. For Android Auto it also exposes a
/// browsable tree (Library / Queue) built by [MediaBrowserTree] and turns a
/// selected item into a [PlaybackController.playTracks] call. The controller
/// stays the single source of truth and owns `just_audio`; the UI never touches
/// this class.
class LinthraAudioHandler extends audio.BaseAudioHandler {
  LinthraAudioHandler(this._controller, this._tree) {
    _subscription = _controller.stateStream.listen(_broadcast);
    // Seed the session from the latest known state so a freshly attached
    // notification/Android Auto isn't blank before the first stream event.
    _broadcast(_controller.state);
  }

  final PlaybackController _controller;
  final MediaBrowserTree _tree;
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
  Future<void> skipToPrevious() => _controller.skipToPrevious();

  @override
  Future<void> seek(Duration position) => _controller.seek(position);

  // --- Android Auto / media browser ---------------------------------------

  @override
  Future<List<audio.MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    final nodes = await _tree.childrenOf(parentMediaId, _controller.state);
    return nodes.map(_mediaItemForNode).toList();
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    final request = await _tree.resolve(mediaId, _controller.state);
    if (request == null) return;
    await _controller.playTracks(request.tracks,
        startIndex: request.startIndex);
  }

  // ------------------------------------------------------------------------

  void _broadcast(PlaybackState state) {
    final track = state.currentTrack;
    mediaItem.add(
      track == null
          ? null
          : _trackMediaItem(track, id: track.id, live: state.duration),
    );
    playbackState.add(_playbackStateFor(state));
  }

  audio.MediaItem _mediaItemForNode(MediaNode node) {
    final track = node.track;
    if (node.playable && track != null) {
      return _trackMediaItem(track, id: node.id);
    }
    return audio.MediaItem(
      id: node.id,
      title: node.title,
      playable: false,
      displaySubtitle: node.subtitle,
    );
  }

  audio.MediaItem _trackMediaItem(
    Track track, {
    required String id,
    Duration live = Duration.zero,
  }) {
    // Prefer the live duration the engine reported (now-playing); fall back to
    // the track's catalog duration, and omit it entirely when unknown.
    final duration = live > Duration.zero ? live : track.duration;
    return audio.MediaItem(
      id: id,
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
      systemActions: const <audio.MediaAction>{
        audio.MediaAction.seek,
        audio.MediaAction.skipToNext,
        audio.MediaAction.skipToPrevious,
      },
      processingState: _processingStateFor(state.status),
      playing: state.isPlaying,
      updatePosition: state.position,
    );
  }

  List<audio.MediaControl> _controlsFor(PlaybackState state) {
    return <audio.MediaControl>[
      if (state.hasPrevious) audio.MediaControl.skipToPrevious,
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
/// in the notification / lock screen and is reachable from Android Auto, with a
/// browsable tree backed by [library].
///
/// Best-effort by design: returns `null` when `audio_service` can't initialise
/// (a platform without the native setup, or a test environment). Playback still
/// works through the controller in that case, so a missing media session never
/// breaks basic playback.
Future<LinthraAudioHandler?> connectMediaSession(
  PlaybackController controller,
  MusicLibraryRepository library,
) async {
  try {
    return await audio.AudioService.init(
      builder: () => LinthraAudioHandler(controller, MediaBrowserTree(library)),
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
