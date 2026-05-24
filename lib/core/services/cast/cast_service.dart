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

  /// Begins scanning for nearby cast targets. A no-op when casting is
  /// unavailable.
  Future<void> startDiscovery();

  /// Stops scanning (e.g. when the device picker closes).
  Future<void> stopDiscovery();

  /// Establishes a session with [device] and hands playback off to it.
  Future<void> connect(CastDevice device);

  /// Tears down the current session and returns playback to this device.
  Future<void> disconnect();

  /// Releases any resources/listeners. Call on app shutdown.
  Future<void> dispose();
}
