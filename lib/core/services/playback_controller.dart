import '../models/playback_state.dart';
import '../models/repeat_mode.dart';
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

  /// Loads [track] (resolving its playable URI) and begins playback, replacing
  /// any existing queue with just this track.
  Future<void> playTrack(Track track);

  /// Replaces the queue with [tracks] and starts playback at [startIndex]. The
  /// tracks after it become the up-next queue.
  Future<void> playTracks(List<Track> tracks, {int startIndex = 0});

  /// Inserts [track] so it plays immediately after the current one
  /// ("play next") without interrupting what is playing now.
  void playNext(Track track);

  /// Advances to the next track in the queue, if any. A no-op when the queue
  /// has no upcoming tracks.
  Future<void> skipToNext();

  /// Steps back to the previous track in the queue, if any. A no-op when the
  /// current track is the first one.
  Future<void> skipToPrevious();

  /// Empties the up-next queue, leaving the current track playing.
  void clearQueue();

  /// Turns shuffle on or off. Shuffle is a playback mode, not a one-shot: it
  /// reorders the current queue (keeping the current track playing) and stays in
  /// effect for any queue loaded afterwards. The new state is reflected in
  /// [PlaybackState.shuffleEnabled].
  void setShuffleEnabled(bool enabled);

  /// Sets the repeat behaviour (off / repeat all / repeat one). Consulted when a
  /// track finishes; the new mode is reflected in [PlaybackState.repeatMode].
  void setRepeatMode(RepeatMode mode);

  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);

  /// Releases native resources. Call on app shutdown.
  Future<void> dispose();
}
