import 'dart:async';

import '../../models/cast_media.dart';
import '../../models/cast_playback_status.dart';
import '../../models/cast_state.dart';
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
      'This track is a local file. Casting plays streamed (Jellyfin) tracks '
      'only — a receiver can\'t reach files on this device.';

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
  StreamSubscription<Track?>? _trackSub;
  bool _discovering = false;

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
      _emitPlayback(CastPlaybackStatus.idle);
      _emit(CastState(
        availability: CastAvailability.connected,
        devices: _state.devices,
        connectedDevice: device,
      ));
      return;
    }

    if (!_mediaResolver.canCast(track)) {
      _emitPlayback(CastPlaybackStatus.idle);
      _emit(CastState(
        availability: CastAvailability.connected,
        devices: _state.devices,
        connectedDevice: device,
        message: localFileLimitation,
      ));
      return;
    }

    final CastMedia media;
    try {
      media = await _mediaResolver.resolve(track);
    } on CastMediaException catch (error) {
      _emitPlayback(CastPlaybackStatus.idle);
      _emit(CastState(
        availability: CastAvailability.connected,
        devices: _state.devices,
        connectedDevice: device,
        message: error.message,
      ));
      return;
    } catch (_) {
      _emitPlayback(CastPlaybackStatus.idle);
      _emit(CastState(
        availability: CastAvailability.connected,
        devices: _state.devices,
        connectedDevice: device,
        message: "Couldn't cast this track.",
      ));
      return;
    }

    // A disconnect may have landed while resolving; don't load onto a dead
    // session.
    if (_handle != handle) return;
    try {
      await handle.loadMedia(media);
    } catch (_) {
      _emitPlayback(CastPlaybackStatus.idle);
      _emit(CastState(
        availability: CastAvailability.connected,
        devices: _state.devices,
        connectedDevice: device,
        message: "Couldn't start playback on ${device.name}.",
      ));
      return;
    }

    // Playing on the receiver now. Marking isCasting true is the signal the
    // ActivePlaybackController uses to silence the local engine; we report a
    // loading status until the receiver's first MEDIA_STATUS arrives.
    if (!_playbackStatus.isPlaying) {
      _emitPlayback(_playbackStatus.copyWith(status: PlaybackStatus.loading));
    }
    _emit(CastState(
      availability: CastAvailability.connected,
      devices: _state.devices,
      connectedDevice: device,
      isCasting: true,
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
    await _trackSub?.cancel();
    _trackSub = null;
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
