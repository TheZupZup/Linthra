import 'playback_controller.dart';

/// A [PlaybackController] that owns an on-device audio engine and can be
/// *suspended* so an external output (a cast receiver) becomes the only thing
/// making sound.
///
/// The `ActivePlaybackController` drives this: when a cast handoff begins it
/// calls [suspend] so the local engine goes silent while still owning the queue
/// (skips/`playTracks` keep updating the current track and up-next, which the
/// cast service mirrors onto the receiver — without any local audio). When
/// casting ends it calls [resume] to load the current track at the receiver's
/// last position, *paused by default* so the device never surprise-starts.
abstract interface class LocalPlaybackController implements PlaybackController {
  /// Whether the engine is currently suspended (a cast output is active).
  bool get isSuspended;

  /// Silences and pauses the local engine, leaving the queue intact. Idempotent.
  Future<void> suspend();

  /// Resumes local output: loads the current track, seeks to [at], and either
  /// starts playing or stays paused per [play] (paused by default, so ending a
  /// cast session never auto-starts the phone). Clears the suspended flag.
  Future<void> resume({Duration at = Duration.zero, bool play = false});

  /// Wraps the queue back to its first track and (re)loads it. Used to honour
  /// repeat-all when a cast track finishes at the end of the queue.
  Future<void> restartQueue();

  /// Turns ReplayGain volume normalization on or off. When on, the engine
  /// attenuates each loaded track by its ReplayGain so songs play at a more
  /// even loudness; when off, audio plays untouched. Applies to the currently
  /// loaded track immediately, so toggling takes effect without a track change.
  void setVolumeNormalizationEnabled(bool enabled);
}
