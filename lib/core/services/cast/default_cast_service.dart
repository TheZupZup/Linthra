import 'dart:async';

import '../../models/cast_media.dart';
import '../../models/cast_playback_status.dart';
import '../../models/cast_state.dart';
import '../../models/cast_volume.dart';
import '../../models/playback_state.dart';
import '../../models/track.dart';
import 'cast_media_resolver.dart';
import 'cast_service.dart';
import 'cast_transport.dart';

/// The real [CastService]: it owns cast *state*, the playback *handoff*, and the
/// receiver's reported playback status, delegating only the network-touching
/// plumbing (discovery, the cast session, transport commands) to a
/// [CastTransport]. That split is deliberate — every decision this class makes
/// is unit-tested with a fake transport, while the one untestable adapter
/// ([ChromecastCastTransport]) stays thin.
///
/// Handoff model:
///  - On connect, and whenever the playing track changes while connected, it
///    resolves the current track to a reachable URL *at that moment* via
///    [CastMediaResolver] and asks the receiver to play it. On success it marks
///    [CastState.isCasting] true; the `ActivePlaybackController` watches that to
///    silence the local engine so audio isn't heard twice.
///  - A track with no castable URL (an on-device file) is reported as a clear,
///    non-fatal limitation in [CastState.message] with [CastState.isCasting]
///    false, so local playback is left untouched.
///  - While casting it forwards the receiver's media status out on
///    [playbackStream] (position / play-state / duration) and routes
///    play/pause/seek/refresh to the session.
///
/// It no longer pauses or resumes the local engine itself: that decision belongs
/// to the [ActivePlaybackController], which reacts to [CastState.isCasting]. In
/// particular it never auto-starts local playback when a session ends — the
/// device returns to a paused, in-sync state instead of surprise-playing.
///
/// Security: the resolved URL — which may embed a Jellyfin token — lives only on
/// the [CastMedia] passed to the transport for this one load. It is never
/// logged, never written to [CastState] or [CastPlaybackStatus], and never
/// persisted.
class DefaultCastService implements CastService {
  DefaultCastService({
    required CastTransport transport,
    required CastMediaResolver mediaResolver,
    required Track? Function() currentTrack,
    required Stream<Track?> trackChanges,
    Duration discoveryTimeout = const Duration(seconds: 5),
    Duration connectTimeout = const Duration(seconds: 12),
  })  : _transport = transport,
        _mediaResolver = mediaResolver,
        _currentTrack = currentTrack,
        _trackChanges = trackChanges,
        _discoveryTimeout = discoveryTimeout,
        _connectTimeout = connectTimeout;

  static const String localFileLimitation =
      'This track is a local file. Casting plays streamed (Jellyfin/Subsonic) '
      "tracks only — a receiver can't reach files on this device.";

  static const String volumeCommandFailed =
      "Couldn't change the cast volume. Playback is unaffected.";

  /// How far one volume nudge moves the device level (10%).
  static const double _volumeStep = 0.1;

  final CastTransport _transport;
  final CastMediaResolver _mediaResolver;
  final Track? Function() _currentTrack;
  final Stream<Track?> _trackChanges;
  final Duration _discoveryTimeout;
  final Duration _connectTimeout;

  final StreamController<CastState> _states =
      StreamController<CastState>.broadcast();
  final StreamController<CastPlaybackStatus> _playback =
      StreamController<CastPlaybackStatus>.broadcast();

  // A real backend is present, so the starting point is idle (ready, nothing
  // discovered yet) rather than unavailable.
  CastState _state = const CastState(availability: CastAvailability.idle);
  CastPlaybackStatus _playbackStatus = CastPlaybackStatus.idle;

  CastSessionHandle? _handle;
  StreamSubscription<bool>? _readySub;
  StreamSubscription<CastPlaybackStatus>? _statusSub;
  StreamSubscription<CastVolume>? _volumeSub;
  StreamSubscription<Track?>? _trackSub;
  bool _discovering = false;

  /// The connected receiver's last-reported volume, kept so every connected
  /// state build carries it (it belongs to the device and persists across track
  /// changes within a session). Null until the receiver reports one.
  CastVolume? _volume;

  /// The provider-namespaced [Track.uri] of the track currently loaded on the
  /// receiver, so a re-emission of the *same* track (a duplicate stream event, a
  /// metadata refresh) is a no-op instead of a needless re-resolve + reload —
  /// which would restart playback on the receiver and re-mint a stream URL. Keyed
  /// by uri (not the bare id) so switching to another provider's copy that shares
  /// a server-side id (`jellyfin:101` → `subsonic:101`) still reloads the
  /// receiver. Cleared whenever the session ends or nothing castable is loaded.
  String? _castingTrackUri;

  @override
  CastState get state => _state;

  @override
  Stream<CastState> get stateStream => _states.stream;

  @override
  CastPlaybackStatus get playbackStatus => _playbackStatus;

  @override
  Stream<CastPlaybackStatus> get playbackStream => _playback.stream;

  void _emit(CastState next) {
    if (next == _state) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  void _emitPlayback(CastPlaybackStatus next) {
    _playbackStatus = next;
    if (!_playback.isClosed) _playback.add(next);
  }

  /// Builds a `connected` state for [device] that always carries the current
  /// device [_volume], so a track change or volume update never drops the
  /// receiver's known level. [message] is transient (not preserved by the next
  /// build) and defaults to none.
  CastState _connected(
    CastDevice device, {
    String? message,
    bool isCasting = false,
  }) {
    final CastVolume? v = _volume;
    return CastState(
      availability: CastAvailability.connected,
      devices: _state.devices,
      connectedDevice: device,
      message: message,
      isCasting: isCasting,
      volume: v?.level,
      muted: v?.muted ?? false,
      supportsVolumeControl: v?.controllable ?? false,
    );
  }

  @override
  Future<void> startDiscovery() async {
    // Never interrupt an in-progress connection or an established session, and
    // never run two scans at once.
    if (_state.isConnecting || _state.isConnected || _discovering) return;
    _discovering = true;
    _emit(const CastState(availability: CastAvailability.discovering));
    try {
      final List<CastDevice> devices = await _transport.discover(
        _discoveryTimeout,
      );
      _discovering = false;
      // A connection may have started while we scanned; don't clobber it.
      if (_state.isConnecting || _state.isConnected) return;
      _emit(CastState(
        availability: CastAvailability.idle,
        devices: devices,
      ));
    } catch (_) {
      _discovering = false;
      if (_state.isConnecting || _state.isConnected) return;
      _emit(const CastState(
        availability: CastAvailability.error,
        message: "Couldn't search for cast devices. Check your Wi-Fi and try "
            'again.',
      ));
    }
  }

  @override
  Future<void> stopDiscovery() async {
    // The scan is time-boxed by the transport and stops itself; there is no
    // partial result to cancel. Settle a still-spinning UI back to idle.
    if (_state.isDiscovering) {
      _emit(const CastState(availability: CastAvailability.idle));
    }
  }

  @override
  Future<void> connect(CastDevice device) async {
    // Tear down any prior session first so we never leak one.
    await _teardownSession();
    _emit(CastState(
      availability: CastAvailability.connecting,
      devices: _state.devices,
      connectedDevice: device,
    ));

    final CastSessionHandle handle;
    try {
      handle = await _transport.connect(device);
    } catch (_) {
      _emit(CastState(
        availability: CastAvailability.error,
        devices: _state.devices,
        message: "Couldn't connect to ${device.name}.",
      ));
      return;
    }

    final bool ready = await handle.readyStream
        .firstWhere((bool r) => r, orElse: () => false)
        .timeout(_connectTimeout, onTimeout: () => false);
    if (!ready) {
      await _safeClose(handle);
      _emit(CastState(
        availability: CastAvailability.error,
        devices: _state.devices,
        message: "Couldn't connect to ${device.name}.",
      ));
      return;
    }

    _handle = handle;
    // Watch for the receiver dropping the session so we can recover locally.
    _readySub = handle.readyStream.listen(
      (bool r) {
        if (!r) _onSessionLost();
      },
      onDone: _onSessionLost,
      cancelOnError: false,
    );
    // Mirror the receiver's media status out for the unified playback state.
    _statusSub = handle.statusStream.listen(
      _emitPlayback,
      onError: (_) {},
      cancelOnError: false,
    );
    // Follow the receiver's device volume so the sheet can show and track it.
    _volumeSub = handle.volumeStream.listen(
      _onVolume,
      onError: (_) {},
      cancelOnError: false,
    );
    // Cast the current track now, and re-cast whenever it changes.
    _trackSub = _trackChanges.listen((Track? track) => _handOff(device, track));
    await _handOff(device, _currentTrack());
  }

  /// Resolves [track] to castable media and hands it to the receiver. On success
  /// it marks [CastState.isCasting] true so the engine can be silenced. A
  /// non-castable (on-device) track is surfaced as a clear limitation without
  /// claiming a handoff.
  Future<void> _handOff(CastDevice device, Track? track) async {
    final CastSessionHandle? handle = _handle;
    if (handle == null) return; // disconnected mid-flight

    if (track == null) {
      _castingTrackUri = null;
      _emitPlayback(CastPlaybackStatus.idle);
      _emit(_connected(device));
      return;
    }

    // Already streaming this exact track on the receiver: a duplicate emission
    // (or a metadata-only change carrying the same track) must not reload — that
    // would restart receiver playback and re-resolve the stream URL for nothing.
    // Compare by uri so a different provider's same-id copy still reloads.
    if (_state.isCasting && _castingTrackUri == track.uri) return;

    if (!_mediaResolver.canCast(track)) {
      _castingTrackUri = null;
      _emitPlayback(CastPlaybackStatus.idle);
      _emit(_connected(device, message: localFileLimitation));
      return;
    }

    final CastMedia media;
    try {
      media = await _mediaResolver.resolve(track);
    } on CastMediaException catch (error) {
      _castingTrackUri = null;
      _emitPlayback(CastPlaybackStatus.idle);
      _emit(_connected(device, message: error.message));
      return;
    } catch (_) {
      _castingTrackUri = null;
      _emitPlayback(CastPlaybackStatus.idle);
      _emit(_connected(device, message: "Couldn't cast this track."));
      return;
    }

    // A disconnect may have landed while resolving; don't load onto a dead
    // session.
    if (_handle != handle) return;
    try {
      await handle.loadMedia(media);
    } catch (_) {
      _castingTrackUri = null;
      _emitPlayback(CastPlaybackStatus.idle);
      _emit(_connected(device,
          message: "Couldn't start playback on ${device.name}."));
      return;
    }
    // Remember what is now loaded so a duplicate emission of the same track is a
    // no-op (see the guard above).
    _castingTrackUri = track.uri;

    // Playing on the receiver now. Marking isCasting true is the signal the
    // ActivePlaybackController uses to silence the local engine. Report a fresh
    // loading status (position and duration reset to zero) for the just-loaded
    // media: the receiver starts every LOAD at the beginning, so carrying the
    // previous track's position/duration forward would make the phone briefly
    // show the new track at the old track's progress — a visible desync on
    // next/previous and on repeat-advance while casting — until the receiver's
    // first MEDIA_STATUS for the new media arrives.
    _emitPlayback(const CastPlaybackStatus(status: PlaybackStatus.loading));
    _emit(_connected(device, isCasting: true));
  }

  /// Folds a fresh receiver [volume] into the connected state, keeping the
  /// current notice and casting flag. Ignored when not connected (a stray
  /// update after disconnect must not resurrect a connected state).
  void _onVolume(CastVolume volume) {
    _volume = volume;
    final CastDevice? device = _state.connectedDevice;
    if (device == null || !_state.isConnected) return;
    _emit(_connected(
      device,
      message: _state.message,
      isCasting: _state.isCasting,
    ));
  }

  @override
  Future<void> disconnect() async {
    await _teardownSession();
    _emit(CastState(
      availability: CastAvailability.idle,
      devices: _state.devices,
    ));
  }

  @override
  Future<void> play() async => _handle?.play();

  @override
  Future<void> pause() async => _handle?.pause();

  @override
  Future<void> seek(Duration position) async => _handle?.seek(position);

  @override
  Future<void> setVolume(double volume) async {
    final CastSessionHandle? handle = _handle;
    // Only act on a live, volume-capable session; otherwise a safe no-op.
    if (handle == null || !_state.supportsVolumeControl) return;
    final double level = volume.clamp(0.0, 1.0);
    try {
      await handle.setVolume(level);
      // The receiver confirms with a status push that updates [_volume]; no
      // optimistic write is needed.
    } catch (_) {
      // A failed volume command must never break playback — surface a calm
      // notice and leave the session/handoff untouched.
      _emitVolumeError();
    }
  }

  @override
  Future<void> volumeUp() => _nudgeVolume(_volumeStep);

  @override
  Future<void> volumeDown() => _nudgeVolume(-_volumeStep);

  Future<void> _nudgeVolume(double delta) {
    final double base = _volume?.level ?? 0.0;
    return setVolume(base + delta);
  }

  @override
  Future<void> setMuted(bool muted) async {
    final CastSessionHandle? handle = _handle;
    if (handle == null || !_state.supportsVolumeControl) return;
    try {
      await handle.setMuted(muted);
    } catch (_) {
      _emitVolumeError();
    }
  }

  /// Surfaces a friendly volume-command failure as a transient notice, without
  /// touching playback or the handoff. A no-op when not connected.
  void _emitVolumeError() {
    final CastDevice? device = _state.connectedDevice;
    if (device == null || !_state.isConnected) return;
    _emit(_connected(
      device,
      message: volumeCommandFailed,
      isCasting: _state.isCasting,
    ));
  }

  @override
  Future<void> refresh() async => _handle?.requestStatus();

  /// The receiver ended the session on its own (closed, network drop). Reflect
  /// that we're no longer connected; the [ActivePlaybackController] reacts to
  /// the dropped [CastState.isCasting] and returns to a paused local state
  /// (never surprise-starting playback).
  void _onSessionLost() {
    if (_handle == null) return;
    unawaited(_teardownSession().then((_) {
      _emit(CastState(
        availability: CastAvailability.idle,
        devices: _state.devices,
      ));
    }));
  }

  /// Cancels the session listeners, closes the handle, and resets the reported
  /// playback status to idle.
  Future<void> _teardownSession() async {
    await _readySub?.cancel();
    _readySub = null;
    await _statusSub?.cancel();
    _statusSub = null;
    await _volumeSub?.cancel();
    _volumeSub = null;
    await _trackSub?.cancel();
    _trackSub = null;
    // The device volume belongs to the session; forget it so the next connect
    // starts from "unknown" rather than a stale level.
    _volume = null;
    // Forget what was loaded so a reconnect re-casts the current track from
    // scratch rather than treating it as a duplicate of the last session.
    _castingTrackUri = null;
    final CastSessionHandle? handle = _handle;
    _handle = null;
    if (handle != null) await _safeClose(handle);
    _emitPlayback(CastPlaybackStatus.idle);
  }

  Future<void> _safeClose(CastSessionHandle handle) async {
    try {
      await handle.close();
    } catch (_) {
      // Closing is best-effort; a failure here must not break recovery.
    }
  }

  @override
  Future<void> dispose() async {
    await _teardownSession();
    await _states.close();
    await _playback.close();
  }
}
