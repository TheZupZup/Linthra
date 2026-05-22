import '../models/playback_state.dart';
import '../models/track.dart';

/// The only playback contract the UI knows about.
///
/// The player feature depends on this interface, never on `just_audio` or
/// `audio_service` directly. The concrete controller lives in the services
/// layer and can be swapped or wrapped (e.g. to add background playback,
/// MPRIS, or Android Auto) without touching feature code.
abstract interface class PlaybackController {
  /// Emits a new immutable [PlaybackState] whenever anything changes
  /// (status, position, or the loaded track).
  Stream<PlaybackState> get stateStream;

  /// The latest known state, for synchronous reads on first build.
  PlaybackState get state;

  /// Loads [track] (resolving its playable URI) and begins playback.
  Future<void> playTrack(Track track);

  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);

  /// Releases native resources. Call on app shutdown.
  Future<void> dispose();
}
