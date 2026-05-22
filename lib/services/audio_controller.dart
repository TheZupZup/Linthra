import '../models/song.dart';

/// High-level playback state, deliberately decoupled from any audio package.
enum PlaybackStatus { idle, loading, playing, paused, completed, error }

/// The only playback contract the UI knows about.
///
/// The UI and player feature depend on this interface, never on `just_audio`
/// or `audio_service` directly. The concrete `JustAudioController` lives in the
/// services layer and can be swapped or wrapped (e.g. to add `audio_service`
/// background handling, MPRIS, or Android Auto) without touching feature code.
abstract interface class AudioController {
  /// Emits whenever playback state changes.
  Stream<PlaybackStatus> get statusStream;

  /// Emits the current playback position, suitable for driving a seek bar.
  Stream<Duration> get positionStream;

  /// The track currently loaded, or null if nothing is loaded.
  Song? get currentSong;

  /// Loads [song] (resolving its playable URI) and begins playback.
  Future<void> playSong(Song song);

  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);

  /// Releases native resources. Call on app shutdown.
  Future<void> dispose();
}
