import 'dart:async';

import '../../models/cast_media.dart';
import '../../models/cast_state.dart';
import '../../models/track.dart';
import 'cast_media_resolver.dart';
import 'cast_service.dart';
import 'cast_transport.dart';

/// The real [CastService]: it owns cast *state* and the playback *handoff*,
/// delegating only the network-touching plumbing (discovery, the cast session)
/// to a [CastTransport]. That split is deliberate — every decision this class
/// makes is unit-tested with a fake transport, while the one untestable adapter
/// ([ChromecastCastTransport]) stays thin.
///
/// Handoff model (kept simple on purpose, since transport controls aren't yet
/// routed to the receiver):
///  - On connect, and whenever the playing track changes while connected, it
///    resolves the current track to a reachable URL *at that moment* via
///    [CastMediaResolver] and asks the receiver to play it, then pauses local
///    playback so audio isn't heard twice.
///  - A track with no castable URL (an on-device file) is reported as a clear,
///    non-fatal limitation in [CastState.message]; local playback is left
///    untouched.
///  - On disconnect (or if the receiver drops the session) local playback
///    resumes, so the device recovers exactly where casting left off.
///
/// Security: the resolved URL — which may embed a Jellyfin token — lives only on
/// the [CastMedia] passed to the transport for this one load. It is never
/// logged, never written to [CastState], and never persisted.
class DefaultCastService implements CastService {
  DefaultCastService({
    required CastTransport transport,
    required CastMediaResolver mediaResolver,
    required Track? Function() currentTrack,
    required Stream<Track?> trackChanges,
    Future<void> Function()? onCastingStarted,
    Future<void> Function()? onCastingStopped,
    Duration discoveryTimeout = const Duration(seconds: 5),
    Duration connectTimeout = const Duration(seconds: 12),
  })  : _transport = transport,
        _mediaResolver = mediaResolver,
        _currentTrack = currentTrack,
        _trackChanges = trackChanges,
        _onCastingStarted = onCastingStarted,
        _onCastingStopped = onCastingStopped,
        _discoveryTimeout = discoveryTimeout,
        _connectTimeout = connectTimeout;

  static const String localFileLimitation =
      'This track is a local file. Casting plays streamed (Jellyfin) tracks '
      'only — a receiver can\'t reach files on this device.';

  final CastTransport _transport;
  final CastMediaResolver _mediaResolver;
  final Track? Function() _currentTrack;
  final Stream<Track?> _trackChanges;
  final Future<void> Function()? _onCastingStarted;
  final Future<void> Function()? _onCastingStopped;
  final Duration _discoveryTimeout;
  final Duration _connectTimeout;

  final StreamController<CastState> _states =
      StreamController<CastState>.broadcast();

  // A real backend is present, so the starting point is idle (ready, nothing
  // discovered yet) rather than unavailable.
  CastState _state = const CastState(availability: CastAvailability.idle);

  CastSessionHandle? _handle;
  StreamSubscription<bool>? _readySub;
  StreamSubscription<Track?>? _trackSub;
  bool _discovering = false;

  // Set only while local playback has been paused for an active handoff, so
  // disconnect resumes it exactly once and only when it was actually paused.
  bool _handedOff = false;

  @override
  CastState get state => _state;

  @override
  Stream<CastState> get stateStream => _states.stream;

  void _emit(CastState next) {
    if (next == _state) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
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
    await _teardownSession(resumeLocal: false);
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
    // Cast the current track now, and re-cast whenever it changes.
    _trackSub = _trackChanges.listen((Track? track) => _handOff(device, track));
    await _handOff(device, _currentTrack());
  }

  /// Resolves [track] to castable media and hands it to the receiver, pausing
  /// local playback on success. A non-castable (on-device) track is surfaced as
  /// a clear limitation without disturbing local playback.
  Future<void> _handOff(CastDevice device, Track? track) async {
    final CastSessionHandle? handle = _handle;
    if (handle == null) return; // disconnected mid-flight

    if (track == null) {
      _emit(CastState(
        availability: CastAvailability.connected,
        devices: _state.devices,
        connectedDevice: device,
      ));
      return;
    }

    if (!_mediaResolver.canCast(track)) {
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
      _emit(CastState(
        availability: CastAvailability.connected,
        devices: _state.devices,
        connectedDevice: device,
        message: error.message,
      ));
      return;
    } catch (_) {
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
      _emit(CastState(
        availability: CastAvailability.connected,
        devices: _state.devices,
        connectedDevice: device,
        message: "Couldn't start playback on ${device.name}.",
      ));
      return;
    }

    // Playing on the receiver now: silence the local engine so audio isn't
    // heard twice, and remember to resume it on disconnect.
    if (!_handedOff) {
      _handedOff = true;
      await _onCastingStarted?.call();
    }
    _emit(CastState(
      availability: CastAvailability.connected,
      devices: _state.devices,
      connectedDevice: device,
    ));
  }

  @override
  Future<void> disconnect() async {
    await _teardownSession(resumeLocal: true);
    _emit(CastState(
      availability: CastAvailability.idle,
      devices: _state.devices,
    ));
  }

  /// The receiver ended the session on its own (closed, network drop). Recover
  /// to local playback and reflect that we're no longer connected.
  void _onSessionLost() {
    if (_handle == null) return;
    unawaited(_teardownSession(resumeLocal: true).then((_) {
      _emit(CastState(
        availability: CastAvailability.idle,
        devices: _state.devices,
      ));
    }));
  }

  /// Cancels the session listeners, closes the handle, and resumes local
  /// playback if we had paused it for casting.
  Future<void> _teardownSession({required bool resumeLocal}) async {
    await _readySub?.cancel();
    _readySub = null;
    await _trackSub?.cancel();
    _trackSub = null;
    final CastSessionHandle? handle = _handle;
    _handle = null;
    if (handle != null) await _safeClose(handle);
    if (resumeLocal && _handedOff) {
      await _onCastingStopped?.call();
    }
    _handedOff = false;
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
    await _teardownSession(resumeLocal: false);
    await _states.close();
  }
}
