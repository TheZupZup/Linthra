import 'dart:async';

import 'package:cast/cast.dart' as cast;

import '../../models/cast_media.dart';
import '../../models/cast_playback_status.dart';
import '../../models/cast_state.dart';
import '../../models/cast_volume.dart';
import '../../models/playback_state.dart';
import 'cast_transport.dart';

/// The one place the `cast` package is touched. It implements [CastTransport]
/// over the package's pure-Dart Google Cast v2 protocol (mDNS discovery via
/// `bonsoir`, a TLS socket, protobuf framing) — no Google Play Services and no
/// proprietary Cast SDK, which is what keeps casting F-Droid/open-source
/// compatible.
///
/// It is deliberately thin: discover, open a session, launch the default media
/// receiver, and forward a `LOAD`. All of casting's decision-making lives in
/// [DefaultCastService] (and is unit-tested there); this adapter only does I/O,
/// so it is verified by static analysis and on-device testing rather than unit
/// tests, which can't open real sockets.
class ChromecastCastTransport implements CastTransport {
  /// The published "Default Media Receiver" app id — a generic player that
  /// streams a media URL with no custom receiver app to host.
  static const String _defaultMediaReceiverAppId = 'CC1AD845';

  // Remembers the underlying cast device for each id we hand out, so [connect]
  // can dial the right host/port from the small [CastDevice] the service holds.
  final Map<String, cast.CastDevice> _devices = <String, cast.CastDevice>{};

  @override
  Future<List<CastDevice>> discover(Duration timeout) async {
    final List<cast.CastDevice> found =
        await cast.CastDiscoveryService().search(timeout: timeout);
    _devices
      ..clear()
      ..addEntries(found.map((d) => MapEntry(d.serviceName, d)));
    return found
        .map((d) => CastDevice(id: d.serviceName, name: d.name))
        .toList(growable: false);
  }

  @override
  Future<CastSessionHandle> connect(CastDevice device) async {
    final cast.CastDevice? target = _devices[device.id];
    if (target == null) {
      throw StateError('Unknown cast device ${device.id}; re-run discovery.');
    }
    final cast.CastSession session =
        await cast.CastSessionManager().startSession(target);
    return _ChromecastSessionHandle(session, _defaultMediaReceiverAppId);
  }
}

class _ChromecastSessionHandle implements CastSessionHandle {
  _ChromecastSessionHandle(this._session, String mediaReceiverAppId) {
    _stateSub = _session.stateStream.listen(
      (cast.CastSessionState s) {
        final bool ready = s == cast.CastSessionState.connected;
        _last = ready;
        if (!_ready.isClosed) _ready.add(ready);
      },
      onDone: () {
        _last = false;
        if (!_ready.isClosed) {
          _ready.add(false);
          _ready.close();
        }
        _stopPolling();
      },
      cancelOnError: false,
    );
    // Listen for the receiver's media status so we can mirror its position and
    // play state back to the app while casting.
    _messageSub = _session.messageStream.listen(
      _onMessage,
      onError: (_) {},
      cancelOnError: false,
    );
    // Launch the default media receiver; the device replies with a receiver
    // status that drives the session to "connected".
    _session.sendMessage(cast.CastSession.kNamespaceReceiver, <String, dynamic>{
      'type': 'LAUNCH',
      'appId': mediaReceiverAppId,
    });
    // Ask the platform receiver for its status so the device's current volume is
    // known promptly (the LAUNCH reply also carries it, but this is belt-and-
    // suspenders for receivers that omit volume on launch).
    _requestReceiverStatus();
  }

  final cast.CastSession _session;
  final StreamController<bool> _ready = StreamController<bool>.broadcast();
  final StreamController<CastPlaybackStatus> _status =
      StreamController<CastPlaybackStatus>.broadcast();
  final StreamController<CastVolume> _volume =
      StreamController<CastVolume>.broadcast();
  StreamSubscription<cast.CastSessionState>? _stateSub;
  StreamSubscription<Map<String, dynamic>>? _messageSub;
  Timer? _poll;
  bool? _last;

  // The receiver's media session id, learned from the first MEDIA_STATUS and
  // required to address PLAY/PAUSE/SEEK at the loaded media. Duration is carried
  // forward because not every MEDIA_STATUS repeats it.
  int? _mediaSessionId;
  Duration _lastDuration = Duration.zero;
  int _requestId = 1;

  @override
  Stream<bool> get readyStream async* {
    // Replay the latest readiness so a listener that subscribes after the
    // device already reported "connected" still sees it (broadcast streams
    // don't buffer).
    if (_last != null) yield _last!;
    yield* _ready.stream;
  }

  @override
  Stream<CastPlaybackStatus> get statusStream => _status.stream;

  @override
  Stream<CastVolume> get volumeStream => _volume.stream;

  @override
  Future<void> loadMedia(CastMedia media) async {
    // A LOAD starts a brand-new media session on the receiver, which mints a
    // fresh mediaSessionId and reports the new track's own duration. Forget the
    // previous track's session id and duration so a poll between this LOAD and
    // the first MEDIA_STATUS can't address the old media (or report its stale
    // duration/`FINISHED`) — which would desync the phone or trigger a spurious
    // skip on track change while casting.
    _mediaSessionId = null;
    _lastDuration = Duration.zero;
    _session.sendMessage(cast.CastSession.kNamespaceMedia, <String, dynamic>{
      'type': 'LOAD',
      'requestId': _requestId++,
      'autoplay': true,
      'currentTime': 0,
      'media': <String, dynamic>{
        'contentId': media.url.toString(),
        'contentType': media.contentType,
        'streamType': 'BUFFERED',
        'metadata': <String, dynamic>{
          'metadataType': 3, // MusicTrackMediaMetadata
          if (media.title != null) 'title': media.title,
          if (media.artist != null) 'artist': media.artist,
          if (media.album != null) 'albumName': media.album,
          if (media.artworkUrl != null)
            'images': <Map<String, dynamic>>[
              <String, dynamic>{'url': media.artworkUrl.toString()},
            ],
        },
      },
    });
    // Keep position fresh between the receiver's spontaneous status pushes by
    // polling its media status once a second.
    _startPolling();
  }

  @override
  Future<void> play() async => _mediaCommand('PLAY');

  @override
  Future<void> pause() async => _mediaCommand('PAUSE');

  @override
  Future<void> seek(Duration position) async {
    final int? id = _mediaSessionId;
    if (id == null) return;
    _session.sendMessage(cast.CastSession.kNamespaceMedia, <String, dynamic>{
      'type': 'SEEK',
      'requestId': _requestId++,
      'mediaSessionId': id,
      'currentTime': position.inMilliseconds / 1000.0,
    });
  }

  @override
  Future<void> requestStatus() async {
    if (_mediaSessionId == null) return;
    _session.sendMessage(cast.CastSession.kNamespaceMedia, <String, dynamic>{
      'type': 'GET_STATUS',
      'requestId': _requestId++,
      'mediaSessionId': _mediaSessionId,
    });
  }

  @override
  Future<void> setVolume(double level) async {
    _sendToReceiver(<String, dynamic>{
      'type': 'SET_VOLUME',
      'volume': <String, dynamic>{'level': level.clamp(0.0, 1.0)},
    });
  }

  @override
  Future<void> setMuted(bool muted) async {
    _sendToReceiver(<String, dynamic>{
      'type': 'SET_VOLUME',
      'volume': <String, dynamic>{'muted': muted},
    });
  }

  /// Asks the platform receiver for its current status (which carries device
  /// volume).
  void _requestReceiverStatus() {
    _sendToReceiver(<String, dynamic>{'type': 'GET_STATUS'});
  }

  /// Sends a message on the receiver namespace addressed to the platform
  /// receiver (`receiver-0`), not the media app.
  ///
  /// `CastSession.sendMessage` targets the media app's transport id once the
  /// app has launched, but volume/receiver-status commands must reach the
  /// platform receiver — so this goes through the socket with an explicit
  /// `receiver-0` destination (the virtual connection to it was opened when the
  /// session connected).
  void _sendToReceiver(Map<String, dynamic> payload) {
    _session.socket.sendMessage(
      cast.CastSession.kNamespaceReceiver,
      _session.sessionId,
      'receiver-0',
      <String, dynamic>{'requestId': _requestId++, ...payload},
    );
  }

  void _mediaCommand(String type) {
    final int? id = _mediaSessionId;
    if (id == null) return;
    _session.sendMessage(cast.CastSession.kNamespaceMedia, <String, dynamic>{
      'type': type,
      'requestId': _requestId++,
      'mediaSessionId': id,
    });
  }

  void _startPolling() {
    _poll ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(requestStatus()),
    );
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  /// Routes an incoming receiver message: media status drives playback, receiver
  /// status carries the device volume. Other types are ignored.
  void _onMessage(Map<String, dynamic> payload) {
    switch (payload['type']) {
      case 'MEDIA_STATUS':
        _onMediaStatus(payload);
      case 'RECEIVER_STATUS':
        _onReceiverStatus(payload);
    }
  }

  /// Parses a `MEDIA_STATUS` payload into a [CastPlaybackStatus] and forwards it.
  void _onMediaStatus(Map<String, dynamic> payload) {
    final Object? list = payload['status'];
    if (list is! List || list.isEmpty) return;
    final Object? first = list.first;
    if (first is! Map) return;

    final Object? sessionId = first['mediaSessionId'];
    if (sessionId is int) _mediaSessionId = sessionId;

    final Object? media = first['media'];
    if (media is Map) {
      final num? d = media['duration'] as num?;
      if (d != null && d > 0) _lastDuration = _secondsToDuration(d);
    }

    final num? currentTime = first['currentTime'] as num?;
    final Duration position =
        currentTime != null ? _secondsToDuration(currentTime) : Duration.zero;

    final status = CastPlaybackStatus(
      status: _statusFor(
        first['playerState'] as String?,
        first['idleReason'] as String?,
      ),
      position: position,
      duration: _lastDuration,
    );
    if (!_status.isClosed) _status.add(status);
  }

  /// Parses the device volume out of a `RECEIVER_STATUS` payload and forwards a
  /// [CastVolume]. A `controlType` of `fixed` marks the device as not
  /// volume-controllable, so the UI can disable its slider. Carries no track
  /// identity, URL, or token.
  void _onReceiverStatus(Map<String, dynamic> payload) {
    final Object? status = payload['status'];
    if (status is! Map) return;
    final Object? volume = status['volume'];
    if (volume is! Map) return;
    final num? level = volume['level'] as num?;
    if (level == null) return;
    final Object? muted = volume['muted'];
    final Object? controlType = volume['controlType'];
    final CastVolume next = CastVolume(
      level: level.toDouble().clamp(0.0, 1.0),
      muted: muted is bool ? muted : false,
      controllable: controlType != 'fixed',
    );
    if (!_volume.isClosed) _volume.add(next);
  }

  static Duration _secondsToDuration(num seconds) =>
      Duration(milliseconds: (seconds * 1000).round());

  /// Maps the receiver's `playerState` (with `idleReason` for IDLE) onto the
  /// app's [PlaybackStatus].
  static PlaybackStatus _statusFor(String? playerState, String? idleReason) {
    switch (playerState) {
      case 'PLAYING':
        return PlaybackStatus.playing;
      case 'PAUSED':
        return PlaybackStatus.paused;
      case 'BUFFERING':
      case 'LOADING':
        return PlaybackStatus.loading;
      case 'IDLE':
        return idleReason == 'FINISHED'
            ? PlaybackStatus.completed
            : PlaybackStatus.idle;
      default:
        return PlaybackStatus.idle;
    }
  }

  @override
  Future<void> close() async {
    _stopPolling();
    await _stateSub?.cancel();
    _stateSub = null;
    await _messageSub?.cancel();
    _messageSub = null;
    if (!_ready.isClosed) await _ready.close();
    if (!_status.isClosed) await _status.close();
    if (!_volume.isClosed) await _volume.close();
    await cast.CastSessionManager().endSession(_session.sessionId);
  }
}
