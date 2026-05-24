import '../../models/cast_playback_status.dart';
import '../../models/cast_state.dart';

/// The only cast contract the UI knows about, mirroring how [PlaybackController]
/// hides the audio engine. The now-playing screen renders a cast affordance from
/// a [CastState] and drives discovery/connection through this interface, never
/// touching a cast SDK directly.
///
/// This is the seam a real backend (Google Cast / Chromecast, AirPlay, a remote
/// Jellyfin "play on device", …) implements later. The shipped default,
/// [UnavailableCastService], reports [CastAvailability.unavailable] and no-ops
/// every command, so the UI shows an honest "not yet" state instead of faking a
/// device. Swapping in a live backend wires casting end to end without changing
/// the player UI.
abstract interface class CastService {
  /// Emits a new [CastState] whenever availability, the discovered devices, or
  /// the connected device changes.
  Stream<CastState> get stateStream;

  /// The latest known state, for synchronous reads on first build.
  CastState get state;

  /// Position/play-state of the active receiver, for the unified playback state
  /// to follow while casting. Emits [CastPlaybackStatus.idle] when not casting.
  Stream<CastPlaybackStatus> get playbackStream;

  /// The latest known cast playback status, for synchronous reads.
  CastPlaybackStatus get playbackStatus;

  /// Begins scanning for nearby cast targets. A no-op when casting is
  /// unavailable.
  Future<void> startDiscovery();

  /// Stops scanning (e.g. when the device picker closes).
  Future<void> stopDiscovery();

  /// Establishes a session with [device] and hands playback off to it.
  Future<void> connect(CastDevice device);

  /// Tears down the current session and returns playback to this device.
  Future<void> disconnect();

  /// Resumes playback on the receiver. A no-op when not casting.
  Future<void> play();

  /// Pauses playback on the receiver. A no-op when not casting.
  Future<void> pause();

  /// Seeks the receiver to [position]. A no-op when not casting.
  Future<void> seek(Duration position);

  /// Asks the receiver for a fresh status, to re-sync position (e.g. when the
  /// app returns from the background). A no-op when not casting.
  Future<void> refresh();

  /// Releases any resources/listeners. Call on app shutdown.
  Future<void> dispose();
}
