import 'dart:async';

import 'package:cast/cast.dart' as cast;

import '../../models/cast_media.dart';
import '../../models/cast_playback_status.dart';
import '../../models/cast_state.dart';
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
  }

  final cast.CastSession _session;
  final StreamController<bool> _ready = StreamController<bool>.broadcast();
  final StreamController<CastPlaybackStatus> _status =
      StreamController<CastPlaybackStatus>.broadcast();
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
  Future<void> loadMedia(CastMedia media) async {
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

  /// Parses a receiver `MEDIA_STATUS` payload into a [CastPlaybackStatus] and
  /// forwards it. Other message types (receiver status, etc.) are ignored.
  void _onMessage(Map<String, dynamic> payload) {
    if (payload['type'] != 'MEDIA_STATUS') return;
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
    await cast.CastSessionManager().endSession(_session.sessionId);
  }
}
