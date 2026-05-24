import 'dart:async';

import 'package:cast/cast.dart' as cast;

import '../../models/cast_media.dart';
import '../../models/cast_state.dart';
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
      },
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
  StreamSubscription<cast.CastSessionState>? _stateSub;
  bool? _last;

  @override
  Stream<bool> get readyStream async* {
    // Replay the latest readiness so a listener that subscribes after the
    // device already reported "connected" still sees it (broadcast streams
    // don't buffer).
    if (_last != null) yield _last!;
    yield* _ready.stream;
  }

  @override
  Future<void> loadMedia(CastMedia media) async {
    _session.sendMessage(cast.CastSession.kNamespaceMedia, <String, dynamic>{
      'type': 'LOAD',
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
  }

  @override
  Future<void> close() async {
    await _stateSub?.cancel();
    _stateSub = null;
    if (!_ready.isClosed) await _ready.close();
    await cast.CastSessionManager().endSession(_session.sessionId);
  }
}
