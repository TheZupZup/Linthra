import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/playback_state.dart';
import '../../core/services/just_audio_playback_controller.dart';
import '../../core/services/playback_controller.dart';

/// The single [PlaybackController] the app drives playback through.
///
/// Defaults to the `just_audio`-backed implementation. Tests override it with a
/// fake so playback can be exercised without the audio plugin. Disposed with
/// the provider scope so native resources are released on shutdown.
final playbackControllerProvider = Provider<PlaybackController>((ref) {
  final controller = JustAudioPlaybackController();
  ref.onDispose(controller.dispose);
  return controller;
});

/// Streams [PlaybackState] for the UI. Until the first event arrives, callers
/// fall back to the controller's synchronous [PlaybackController.state].
final playbackStateProvider = StreamProvider<PlaybackState>((ref) {
  final controller = ref.watch(playbackControllerProvider);
  return controller.stateStream;
});
