import '../models/repeat_mode.dart';
import '../models/track.dart';
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

  /// Restores a previously persisted queue as a **paused** session: sets modes,
  /// installs [tracks] at [startIndex], seeks to [position], and loads the
  /// current track through the normal resolver **without autoplay**. Used after
  /// an unexpected process restart so the user can resume deliberately.
  Future<void> restoreSession({
    required List<Track> tracks,
    int startIndex = 0,
    Duration position = Duration.zero,
    bool shuffleEnabled = false,
    RepeatMode repeatMode = RepeatMode.off,
    List<Track>? originalOrder,
  });

  /// Wraps the queue back to its first track and (re)loads it. Used to honour
  /// repeat-all when a cast track finishes at the end of the queue.
  Future<void> restartQueue();

  /// Turns ReplayGain volume normalization on or off. When on, the engine
  /// attenuates each loaded track by its ReplayGain so songs play at a more
  /// even loudness; when off, audio plays untouched. Applies to the currently
  /// loaded track immediately, so toggling takes effect without a track change.
  void setVolumeNormalizationEnabled(bool enabled);

  /// Whether, once its own recovery for a track is spent, the engine moves on
  /// to the next playable track after a visible countdown
  /// ([PlaybackState.autoSkip]) or stops on the failed track and waits for the
  /// listener. Off until the listener allows it. The retry that comes before
  /// either is not affected. Turning it off during a countdown calls that
  /// countdown off, so the setting always wins over a skip already pending.
  void setAutomaticSkipEnabled(bool enabled);

  /// A safety restore when the app returns to the foreground: undoes any
  /// lingering audio-focus duck. Never resumes a track the user paused, and a
  /// no-op while suspended. (Recovering from a system sleep is the engine's own
  /// business, driven by the wake rather than by the app's lifecycle.)
  void onAppForegrounded();
}
