import '../../models/cast_media.dart';
import '../../models/cast_playback_status.dart';
import '../../models/cast_state.dart';
import '../../models/cast_volume.dart';

/// The low-level cast plumbing [DefaultCastService] drives, isolated behind an
/// interface so the orchestration logic (discovery → state, connect → handoff,
/// disconnect → resume local) is unit-testable with a fake, while the one real
/// implementation that talks to the cast SDK ([ChromecastCastTransport]) stays a
/// thin, swappable adapter — exactly how [JustAudioPlaybackController] hides
/// `just_audio` behind [PlaybackController].
///
/// This split is what lets the network-touching parts (mDNS discovery, the TLS
/// cast socket) live in code that can't run on a test host, while everything
/// that decides *what* to do — including resolving and handing off the current
/// track's URL — is covered by tests.
abstract interface class CastTransport {
  /// Scans for cast receivers for up to [timeout] and returns those found.
  /// Throws on a discovery failure so the service can show an error state.
  Future<List<CastDevice>> discover(Duration timeout);

  /// Opens a session to [device]. The returned handle is not ready for media
  /// until its [CastSessionHandle.readyStream] emits `true`.
  Future<CastSessionHandle> connect(CastDevice device);
}

/// A live cast session. Created by [CastTransport.connect]; closed by [close].
abstract interface class CastSessionHandle {
  /// Emits `true` once the receiver's media app has launched and the session is
  /// ready to accept [loadMedia], and `false`/closes if the session ends.
  Stream<bool> get readyStream;

  /// Position/play-state updates parsed from the receiver's media status, so the
  /// app can mirror the device (and follow its position for lyrics) instead of
  /// the silenced local engine while casting. Carries no track identity, URL, or
  /// token.
  Stream<CastPlaybackStatus> get statusStream;

  /// The receiver's device volume, parsed from its receiver status, so the app
  /// can show and follow the *device* volume (not the phone's). Emits whenever
  /// the device reports a change. Carries no track identity, URL, or token.
  Stream<CastVolume> get volumeStream;

  /// Tells the receiver to fetch and play [media]. Only valid once the session
  /// is ready.
  Future<void> loadMedia(CastMedia media);

  /// Resumes playback on the receiver.
  Future<void> play();

  /// Pauses playback on the receiver.
  Future<void> pause();

  /// Seeks the receiver to [position].
  Future<void> seek(Duration position);

  /// Sets the receiver's device volume to [level] (`0.0–1.0`). Targets the
  /// platform receiver, not the media app, so it changes the device's own
  /// volume.
  Future<void> setVolume(double level);

  /// Mutes ([muted] true) or unmutes the receiver's device volume.
  Future<void> setMuted(bool muted);

  /// Asks the receiver for a fresh media status (used to re-sync position, e.g.
  /// after the app returns from the background). Best-effort; a no-op when no
  /// media is loaded.
  Future<void> requestStatus();

  /// Tears the session down and returns control to this device.
  Future<void> close();
}
