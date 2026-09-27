import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_media.dart';
import 'package:linthra/core/models/cast_playback_status.dart';
import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/core/models/cast_volume.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/cast/cast_media_access.dart';
import 'package:linthra/core/services/cast/cast_media_relay.dart';
import 'package:linthra/core/services/cast/cast_media_resolver.dart';
import 'package:linthra/core/services/cast/cast_receiver_trust.dart';
import 'package:linthra/core/services/cast/cast_transport.dart';
import 'package:linthra/core/services/cast/default_cast_service.dart';

/// A [CastSessionHandle] whose readiness, status, and lifetime the test drives.
/// It replays the latest readiness to each new listener, exactly like the real
/// handle, so the service's `firstWhere` sees a session that became ready before
/// it subscribed.
class _FakeHandle implements CastSessionHandle {
  _FakeHandle({bool readyImmediately = true}) {
    if (readyImmediately) _last = true;
  }

  final StreamController<bool> _ready = StreamController<bool>.broadcast();
  final StreamController<CastPlaybackStatus> _status =
      StreamController<CastPlaybackStatus>.broadcast();
  final StreamController<CastVolume> _volume =
      StreamController<CastVolume>.broadcast();
  bool? _last;
  final List<CastMedia> loaded = <CastMedia>[];
  int playCount = 0;
  int pauseCount = 0;
  final List<Duration> seeks = <Duration>[];
  int statusRequests = 0;
  final List<double> volumes = <double>[];
  final List<bool> mutes = <bool>[];

  /// When set, [setVolume]/[setMuted] throw it, so a test can drive a failed
  /// volume command.
  Object? volumeError;

  /// When set, [loadMedia] throws it instead of recording the media, so a test
  /// can drive a refused handoff.
  Object? loadError;
  bool closed = false;

  /// When true, [requestStatus] is answered with a status push, like a live
  /// receiver. False models a receiver that died without the session noticing.
  bool answerStatusRequests = false;

  /// When set, [close] waits for it, so a test can drive a slow goodbye.
  Completer<void>? closeGate;

  void becomeReady() {
    _last = true;
    if (!_ready.isClosed) _ready.add(true);
  }

  void drop() {
    _last = false;
    if (!_ready.isClosed) _ready.add(false);
  }

  void pushStatus(CastPlaybackStatus status) {
    if (!_status.isClosed) _status.add(status);
  }

  void pushVolume(CastVolume volume) {
    if (!_volume.isClosed) _volume.add(volume);
  }

  @override
  Stream<bool> get readyStream async* {
    if (_last != null) yield _last!;
    yield* _ready.stream;
  }

  @override
  Stream<CastPlaybackStatus> get statusStream => _status.stream;

  @override
  Stream<CastVolume> get volumeStream => _volume.stream;

  @override
  Future<void> loadMedia(CastMedia media) async {
    if (loadError != null) throw loadError!;
    loaded.add(media);
  }

  @override
  Future<void> play() async => playCount++;

  @override
  Future<void> pause() async => pauseCount++;

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> setVolume(double level) async {
    if (volumeError != null) throw volumeError!;
    volumes.add(level);
  }

  @override
  Future<void> setMuted(bool muted) async {
    if (volumeError != null) throw volumeError!;
    mutes.add(muted);
  }

  @override
  Future<void> requestStatus() async {
    statusRequests++;
    if (answerStatusRequests) {
      pushStatus(const CastPlaybackStatus(status: PlaybackStatus.paused));
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    final Completer<void>? gate = closeGate;
    if (gate != null) await gate.future;
    if (!_ready.isClosed) await _ready.close();
    if (!_status.isClosed) await _status.close();
    if (!_volume.isClosed) await _volume.close();
  }
}

class _FakeTransport implements CastTransport {
  _FakeTransport();

  List<CastDevice> devices = const <CastDevice>[];
  Object? discoverError;
  Object? connectError;
  _FakeHandle? handle;

  /// Per-device handles, for tests that connect to more than one device.
  Map<String, _FakeHandle> handlesById = <String, _FakeHandle>{};

  /// Per-device connect failures.
  Map<String, Object> connectErrorById = <String, Object>{};

  int discoverCount = 0;
  final List<CastDevice> connectRequests = <CastDevice>[];

  @override
  Future<List<CastDevice>> discover(Duration timeout) async {
    discoverCount++;
    if (discoverError != null) throw discoverError!;
    return devices;
  }

  @override
  Future<CastSessionHandle> connect(CastDevice device) async {
    connectRequests.add(device);
    if (connectError != null) throw connectError!;
    final Object? deviceError = connectErrorById[device.id];
    if (deviceError != null) throw deviceError;
    return handlesById[device.id] ?? (handle ??= _FakeHandle());
  }
}

/// A resolver that yields a token-bearing URL derived from the track (so a test
/// can tell which track was cast), or fails as configured.
class _FakeResolver implements CastMediaResolver {
  bool castable = true;
  CastMediaException? error;
  final List<Track> resolved = <Track>[];

  @override
  bool canCast(Track track) => castable;

  @override
  CastMediaAccess accessFor(Track track) =>
      castable ? CastMediaAccess.undeclared : CastMediaAccess.none;

  @override
  Future<CastMedia> resolve(Track track) async {
    resolved.add(track);
    if (error != null) throw error!;
    return CastMedia(
      url: Uri.parse(
          'https://music.example.com/Audio/${track.id}/stream?api_key=TOKEN'),
      contentType: 'audio/mpeg',
      title: track.title,
    );
  }
}

/// A relay that records what it was asked to re-serve and hands back a
/// token-free address, or fails as configured.
class _FakeRelay implements CastMediaRelay {
  bool running = false;
  Object? startError;
  Object? publishError;
  int startCount = 0;
  int stopCount = 0;
  int touchCount = 0;
  final List<CastMedia> published = <CastMedia>[];

  /// Holds the n-th [stop] call (1-based) until completed, after it has
  /// already taken effect, like the real relay awaiting its socket close.
  final Map<int, Completer<void>> stopGates = <int, Completer<void>>{};

  @override
  bool get isRunning => running;

  /// Holds the n-th [start] call (1-based) until completed; a call listed in
  /// [failingStarts] then throws instead of starting.
  final Map<int, Completer<void>> startGates = <int, Completer<void>>{};
  final Set<int> failingStarts = <int>{};

  @override
  Future<void> start() async {
    startCount++;
    final int call = startCount;
    final Completer<void>? gate = startGates[call];
    if (gate != null) await gate.future;
    if (startError != null || failingStarts.contains(call)) {
      throw startError ?? const CastMediaRelayException('down');
    }
    running = true;
  }

  @override
  CastMedia publish(CastMedia media) {
    if (publishError != null) throw publishError!;
    if (!running) {
      throw const CastMediaRelayException(
          CastMediaRelayException.unavailableMessage);
    }
    published.add(media);
    return CastMedia(
      url: Uri.parse('http://192.168.1.20:40000/cast/item${published.length}'),
      contentType: media.contentType,
      title: media.title,
      access: CastMediaAccess.localRelay,
    );
  }

  @override
  void touch() => touchCount++;

  final List<CastMedia> revoked = <CastMedia>[];

  @override
  void revoke(CastMedia relayed) => revoked.add(relayed);

  @override
  Future<void> stop() async {
    stopCount++;
    running = false;
    final Completer<void>? gate = stopGates[stopCount];
    if (gate != null) await gate.future;
  }
}

const _d1 = CastDevice(id: 'd1', name: 'Living Room');
const _d2 = CastDevice(id: 'd2', name: 'Kitchen');
const _jellyfinTrack = Track(id: 'j1', title: 'Streamed', uri: 'jellyfin:j1');
const _localTrack = Track(id: 'l1', title: 'On device', uri: '/music/x.mp3');

void main() {
  late _FakeTransport transport;
  late _FakeResolver resolver;
  late _FakeRelay relay;
  late StreamController<Track?> trackChanges;
  Track? current;

  DefaultCastService build({
    Duration relayKeepAlive = const Duration(minutes: 5),
  }) =>
      DefaultCastService(
        transport: transport,
        mediaResolver: resolver,
        mediaRelay: relay,
        currentTrack: () => current,
        trackChanges: trackChanges.stream,
        discoveryTimeout: const Duration(milliseconds: 5),
        connectTimeout: const Duration(milliseconds: 100),
        relayKeepAlive: relayKeepAlive,
      );

  setUp(() {
    transport = _FakeTransport();
    resolver = _FakeResolver();
    relay = _FakeRelay();
    trackChanges = StreamController<Track?>.broadcast();
    current = null;
  });

  tearDown(() async {
    await trackChanges.close();
  });

  group('discovery', () {
    test('starts idle (a real backend is present, nothing discovered yet)', () {
      final service = build();
      addTearDown(service.dispose);
      expect(service.state.availability, CastAvailability.idle);
      expect(service.state.isAvailable, isTrue);
      expect(service.state.isCasting, isFalse);
    });

    test('populates the device list', () async {
      transport.devices = const <CastDevice>[_d1];
      final service = build();
      addTearDown(service.dispose);

      await service.startDiscovery();

      expect(transport.discoverCount, 1);
      expect(service.state.availability, CastAvailability.idle);
      expect(service.state.devices, const <CastDevice>[_d1]);
    });

    test('a discovery failure becomes a friendly error state', () async {
      transport.discoverError = Exception('mdns down');
      final service = build();
      addTearDown(service.dispose);

      await service.startDiscovery();

      expect(service.state.hasError, isTrue);
      expect(service.state.message, isNotNull);
      expect(service.state.message, isNot(contains('Exception')));
    });
  });

  group('connect + handoff', () {
    test('casts the current streamable track and marks isCasting', () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);

      expect(transport.connectRequests, const <CastDevice>[_d1]);
      expect(service.state.isConnected, isTrue);
      expect(service.state.isCasting, isTrue);
      expect(service.state.connectedDevice, _d1);
      // The receiver got the relay's address; the resolved, token-bearing URL
      // went to the relay and no further.
      expect(handle.loaded, hasLength(1));
      expect(handle.loaded.single.url.host, '192.168.1.20');
      expect(handle.loaded.single.title, 'Streamed');
      expect(relay.published.single.url.queryParameters['api_key'], 'TOKEN');
    });

    test('a local file is reported as a clear limitation, not cast', () async {
      current = _localTrack;
      resolver.castable = false;
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);

      expect(service.state.isConnected, isTrue);
      // Not a real handoff: the engine must be left alone for local files.
      expect(service.state.isCasting, isFalse);
      expect(service.state.message, DefaultCastService.localFileLimitation);
      expect(handle.loaded, isEmpty);
      expect(resolver.resolved, isEmpty);
    });

    test('a resolve failure surfaces the message and does not claim casting',
        () async {
      current = _jellyfinTrack;
      resolver.error = const CastMediaException(
        'Sign in to Jellyfin before casting this track.',
        kind: CastMediaErrorKind.notSignedIn,
      );
      transport.handle = _FakeHandle();
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);

      expect(service.state.isConnected, isTrue);
      expect(service.state.isCasting, isFalse);
      expect(service.state.message, contains('Sign in to Jellyfin'));
      expect(transport.handle!.loaded, isEmpty);
    });

    test('a session that never becomes ready becomes an error state', () async {
      current = _jellyfinTrack;
      transport.handle = _FakeHandle(readyImmediately: false);
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);

      expect(service.state.hasError, isTrue);
      expect(service.state.isCasting, isFalse);
      expect(service.state.message, contains('Living Room'));
    });

    test('a connect failure becomes a friendly error state', () async {
      transport.connectError = Exception('socket refused');
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);

      expect(service.state.hasError, isTrue);
      expect(service.state.message, isNot(contains('Exception')));
    });

    test('a refused receiver says why, not "couldn\'t connect"', () async {
      // The trust gate (#575) refuses a receiver that cannot prove who it is.
      // That is not a flaky network, and telling the user to try again would be
      // wrong — its own secret-free message has to survive to the sheet.
      transport.connectError = const CastReceiverTrustException(
        "Linthra can't verify this device yet, so it won't send your music to "
        'it.',
        kind: CastTrustFailureKind.unsupported,
      );
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);

      expect(service.state.hasError, isTrue);
      expect(service.state.message, contains("can't verify this device"));
      expect(service.state.isCasting, isFalse);
    });

    test('a handoff refused by the trust gate says why too', () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle()
        ..loadError = const CastReceiverTrustException(
          "Linthra stopped casting to that device because it couldn't keep "
          'verifying it.',
          kind: CastTrustFailureKind.incomplete,
        );
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);

      expect(service.state.isCasting, isFalse);
      expect(service.state.message, contains('stopped casting'));
    });

    test('re-casts when the playing track changes mid-session', () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);
      expect(handle.loaded.single.title, 'Streamed');

      const next = Track(id: 'j2', title: 'Next up', uri: 'jellyfin:j2');
      current = next;
      trackChanges.add(next);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(handle.loaded, hasLength(2));
      expect(handle.loaded.last.title, 'Next up');
      expect(service.state.isCasting, isTrue);
    });

    test('a duplicate emission of the same track does not reload the receiver',
        () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);
      expect(handle.loaded, hasLength(1));
      final int resolvesAfterConnect = resolver.resolved.length;

      // The same track is emitted again (a duplicate stream event / metadata
      // refresh). It must not re-resolve or re-LOAD — that would restart the
      // receiver and re-mint the stream URL for nothing.
      trackChanges.add(_jellyfinTrack);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(handle.loaded, hasLength(1));
      expect(resolver.resolved.length, resolvesAfterConnect);
      expect(service.state.isCasting, isTrue);
    });

    test('re-casts a same-bare-id copy from another provider (uri de-dupe)',
        () async {
      // Two castable copies that share a server-side id: switching from one to
      // the other must reload the receiver, not be dropped as the "same track"
      // (the de-dupe keys on the uri, not the bare id).
      const jelly101 = Track(id: '101', title: 'Alpha', uri: 'jellyfin:101');
      const sub101 = Track(id: '101', title: 'Beta', uri: 'subsonic:101');
      current = jelly101;
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);
      expect(handle.loaded, hasLength(1));

      current = sub101;
      trackChanges.add(sub101);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(handle.loaded, hasLength(2));
      expect(handle.loaded.last.title, 'Beta');
    });

    test('reconnecting re-casts the current track (no stale dedupe)', () async {
      current = _jellyfinTrack;
      final firstHandle = _FakeHandle();
      transport.handle = firstHandle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);
      expect(firstHandle.loaded, hasLength(1));

      await service.disconnect();

      // A brand-new session for the (unchanged) current track must load it
      // again — the previous session's loaded-track memory is cleared on
      // teardown, so a reconnect is never mistaken for a duplicate.
      final secondHandle = _FakeHandle();
      transport.handle = secondHandle;
      await service.connect(_d1);

      expect(secondHandle.loaded, hasLength(1));
      expect(service.state.isCasting, isTrue);
    });

    test('a track change resets the reported position and duration', () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);
      // The receiver reports the first track playing near its end.
      handle.pushStatus(const CastPlaybackStatus(
        status: PlaybackStatus.playing,
        position: Duration(seconds: 175),
        duration: Duration(seconds: 180),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(service.playbackStatus.position, const Duration(seconds: 175));

      // Skip to the next track while casting.
      const next = Track(id: 'j2', title: 'Next up', uri: 'jellyfin:j2');
      current = next;
      trackChanges.add(next);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The reported status is reset for the freshly loaded media, so the phone
      // UI never briefly shows the new track at the previous track's 2:55.
      expect(service.playbackStatus.status, PlaybackStatus.loading);
      expect(service.playbackStatus.position, Duration.zero);
      expect(service.playbackStatus.duration, Duration.zero);
    });
  });

  group('receiver status', () {
    test('forwards the receiver media status on playbackStream', () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);

      const status = CastPlaybackStatus(
        status: PlaybackStatus.playing,
        position: Duration(seconds: 12),
        duration: Duration(minutes: 3),
      );
      final Future<CastPlaybackStatus> next = service.playbackStream.first;
      handle.pushStatus(status);

      expect(await next, status);
      expect(service.playbackStatus, status);
    });
  });

  group('transport commands route to the session', () {
    test('play/pause/seek/refresh forward to the handle while casting',
        () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);

      await service.play();
      await service.pause();
      await service.seek(const Duration(seconds: 30));
      await service.refresh();

      expect(handle.playCount, 1);
      expect(handle.pauseCount, 1);
      expect(handle.seeks, const <Duration>[Duration(seconds: 30)]);
      expect(handle.statusRequests, 1);
    });

    test('commands are safe no-ops when not connected', () async {
      final service = build();
      addTearDown(service.dispose);

      // Must not throw with no session.
      await service.play();
      await service.pause();
      await service.seek(const Duration(seconds: 5));
      await service.refresh();
    });
  });

  group('disconnect + recovery (no surprise local restart)', () {
    test('disconnect closes the session and returns to idle', () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);
      expect(service.state.isCasting, isTrue);

      await service.disconnect();

      expect(handle.closed, isTrue);
      expect(service.state.availability, CastAvailability.idle);
      expect(service.state.isCasting, isFalse);
      expect(service.state.connectedDevice, isNull);
      // Playback status is reset; the router (not this service) decides what the
      // device does next, and it never auto-starts local playback.
      expect(service.playbackStatus, CastPlaybackStatus.idle);
    });

    test('a receiver-dropped session recovers to a disconnected state',
        () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);
      handle.drop();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(service.state.availability, CastAvailability.idle);
      expect(service.state.isCasting, isFalse);
    });
  });

  group('security', () {
    test('no token leaks into cast state on success or failure', () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);
      // The token stayed with the relay; the receiver never saw it.
      expect(handle.loaded.single.url.toString(), isNot(contains('TOKEN')));
      expect(handle.loaded.single.access, CastMediaAccess.localRelay);
      // Never in the user-facing state.
      expect(service.state.message ?? '', isNot(contains('TOKEN')));
      expect(service.state.message ?? '', isNot(contains('api_key')));
    });
  });

  group('media relay', () {
    test(
        'a relay that cannot start refuses the session before any receiver '
        'contact', () async {
      current = _jellyfinTrack;
      relay.startError = const CastMediaRelayException('boom');
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);

      expect(transport.connectRequests, isEmpty);
      expect(handle.loaded, isEmpty);
      expect(resolver.resolved, isEmpty);
      expect(service.state.hasError, isTrue);
      expect(service.state.isCasting, isFalse);
      expect(service.state.message, CastMediaRelayException.unavailableMessage);
    });

    test('the relay stops when the session ends', () async {
      current = _jellyfinTrack;
      transport.handle = _FakeHandle();
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);
      expect(relay.running, isTrue);

      await service.disconnect();

      expect(relay.running, isFalse);
    });

    test('the relay stops when the receiver drops the session', () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);
      handle.drop();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(relay.running, isFalse);
    });

    test('the relay stops when connecting fails', () async {
      current = _jellyfinTrack;
      transport.connectError = Exception('no route');
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);

      expect(relay.startCount, 1);
      expect(relay.running, isFalse);
    });

    test('an idle-stopped relay is brought back for the next track', () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);
      relay.running = false; // as if the idle timer fired
      const Track next = Track(id: 'j2', title: 'Next', uri: 'jellyfin:j2');
      current = next;
      trackChanges.add(next);
      await Future<void>.delayed(Duration.zero);

      expect(relay.startCount, 2);
      expect(handle.loaded, hasLength(2));
      expect(handle.loaded.last.url.toString(), isNot(contains('TOKEN')));
      expect(service.state.isCasting, isTrue);
    });

    test(
        'a relay that cannot come back ends the session, never falling back '
        'to the server URL', () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);
      relay.running = false;
      relay.startError = const CastMediaRelayException('boom');
      const Track next = Track(id: 'j2', title: 'Next', uri: 'jellyfin:j2');
      current = next;
      trackChanges.add(next);
      await Future<void>.delayed(Duration.zero);

      expect(handle.loaded, hasLength(1));
      for (final CastMedia media in handle.loaded) {
        expect(media.url.toString(), isNot(contains('TOKEN')));
      }
      expect(handle.closed, isTrue);
      expect(service.state.hasError, isTrue);
      expect(service.state.isCasting, isFalse);
      expect(service.state.message, CastMediaRelayException.unavailableMessage);
    });

    test('a publish failure hands the receiver nothing', () async {
      current = _jellyfinTrack;
      relay.publishError = StateError('nope');
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);

      expect(handle.loaded, isEmpty);
      expect(handle.closed, isTrue);
      expect(relay.running, isFalse);
      expect(service.state.message, CastMediaRelayException.unavailableMessage);
    });

    test('a connected session keeps the relay awake through a long pause',
        () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle()..answerStatusRequests = true;
      transport.handle = handle;
      final service = build(relayKeepAlive: const Duration(milliseconds: 10));
      addTearDown(service.dispose);

      await service.connect(_d1);
      // No status and no requests, as with a paused receiver.
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(relay.touchCount, greaterThanOrEqualTo(3));
      expect(relay.running, isTrue);

      await service.disconnect();
      final int afterDisconnect = relay.touchCount;
      await Future<void>.delayed(const Duration(milliseconds: 40));

      // Nothing keeps a relay awake once its session is gone.
      expect(relay.touchCount, afterDisconnect);
    });

    test('a receiver that stops answering stops keeping the relay awake',
        () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle(); // never answers a status request
      transport.handle = handle;
      final service = build(relayKeepAlive: const Duration(milliseconds: 10));
      addTearDown(service.dispose);

      await service.connect(_d1);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      // It was asked, and its silence renewed nothing, so the relay's own idle
      // shutdown is still armed for a session that died unnoticed.
      expect(handle.statusRequests, greaterThanOrEqualTo(3));
      expect(relay.touchCount, 0);
    });

    test('the relay is revoked before a slow session close finishes', () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle()..closeGate = Completer<void>();
      transport.handle = handle;
      final service = build();

      await service.connect(_d1);
      final Future<void> disconnecting = service.disconnect();
      await Future<void>.delayed(Duration.zero);

      expect(handle.closed, isTrue);
      expect(relay.running, isFalse);

      handle.closeGate!.complete();
      await disconnecting;
      await service.dispose();
    });

    test('a superseded connection attempt leaves the newer session alone',
        () async {
      current = _jellyfinTrack;
      final slow = _FakeHandle(readyImmediately: false); // times out
      final fast = _FakeHandle();
      transport.handlesById = <String, _FakeHandle>{'d1': slow, 'd2': fast};
      final service = build();
      addTearDown(service.dispose);

      final Future<void> first = service.connect(_d1);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await service.connect(_d2);
      expect(service.state.isCasting, isTrue);

      await first; // its readiness wait runs out now

      expect(slow.closed, isTrue);
      expect(relay.running, isTrue);
      expect(service.state.connectedDevice, _d2);
      expect(service.state.isCasting, isTrue);
      expect(service.state.hasError, isFalse);
    });

    test('a failed attempt that lost the race while cleaning up stays quiet',
        () async {
      current = _jellyfinTrack;
      transport.connectErrorById = <String, Object>{'d1': Exception('no')};
      transport.handlesById = <String, _FakeHandle>{'d2': _FakeHandle()};
      // Stop #1 is the first attempt's teardown, #2 its cleanup after the
      // failed connect: hold that one while the second attempt connects.
      final Completer<void> slowStop = Completer<void>();
      relay.stopGates[2] = slowStop;
      final service = build();
      addTearDown(service.dispose);

      final Future<void> first = service.connect(_d1);
      await Future<void>.delayed(Duration.zero);
      await service.connect(_d2);
      expect(service.state.isCasting, isTrue);

      slowStop.complete();
      await first;

      expect(service.state.connectedDevice, _d2);
      expect(service.state.isCasting, isTrue);
      expect(service.state.hasError, isFalse);
      expect(relay.running, isTrue);
    });

    test(
        'an attempt superseded while the relay starts never contacts its '
        'device', () async {
      current = _jellyfinTrack;
      transport.handlesById = <String, _FakeHandle>{
        'd1': _FakeHandle(),
        'd2': _FakeHandle(),
      };
      final Completer<void> slowStart = Completer<void>();
      relay.startGates[1] = slowStart; // the first attempt's relay start
      final service = build();
      addTearDown(service.dispose);

      final Future<void> first = service.connect(_d1);
      await Future<void>.delayed(Duration.zero);
      await service.connect(_d2);
      slowStart.complete();
      await first;

      expect(transport.connectRequests, const <CastDevice>[_d2]);
      expect(service.state.connectedDevice, _d2);
      expect(service.state.isCasting, isTrue);
    });

    test('a stale handoff failing late leaves the next session alone',
        () async {
      current = _jellyfinTrack;
      final d1 = _FakeHandle();
      final d2 = _FakeHandle();
      transport.handlesById = <String, _FakeHandle>{'d1': d1, 'd2': d2};
      final service = build();
      addTearDown(service.dispose);
      await service.connect(_d1);

      // The relay idled out; the next track has to bring it back, and that
      // restart is slow and ends up failing.
      relay.running = false;
      final Completer<void> slowRestart = Completer<void>();
      relay.startGates[2] = slowRestart;
      relay.failingStarts.add(2);
      const Track next = Track(id: 'j2', title: 'Next', uri: 'jellyfin:j2');
      current = next;
      trackChanges.add(next);
      await Future<void>.delayed(Duration.zero);

      // Meanwhile the user moves to another receiver.
      await service.connect(_d2);
      expect(service.state.isCasting, isTrue);

      slowRestart.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(d2.closed, isFalse);
      expect(service.state.connectedDevice, _d2);
      expect(service.state.isCasting, isTrue);
      expect(service.state.hasError, isFalse);
    });

    test('the playing item stays reachable when the next LOAD fails', () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);
      final CastMedia playing = handle.loaded.single;

      handle.loadError = Exception('socket write failed');
      const Track next = Track(id: 'j2', title: 'Next', uri: 'jellyfin:j2');
      current = next;
      trackChanges.add(next);
      await Future<void>.delayed(Duration.zero);

      // Only the refused item's token went; the playing one was never touched.
      expect(relay.revoked, hasLength(1));
      expect(relay.revoked.single.url, isNot(playing.url));
    });

    test('receiver status keeps the relay awake', () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);
      handle
          .pushStatus(const CastPlaybackStatus(status: PlaybackStatus.playing));
      await Future<void>.delayed(Duration.zero);

      expect(relay.touchCount, 1);
    });
  });

  group('device volume', () {
    Future<DefaultCastService> connectedService(_FakeHandle handle) async {
      current = _jellyfinTrack;
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);
      await service.connect(_d1);
      return service;
    }

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 5));

    test('a receiver volume update folds into the cast state', () async {
      final handle = _FakeHandle();
      final service = await connectedService(handle);

      handle.pushVolume(const CastVolume(level: 0.4, muted: false));
      await settle();

      expect(service.state.volume, 0.4);
      expect(service.state.muted, isFalse);
      expect(service.state.supportsVolumeControl, isTrue);
      // Folding volume must not disturb the handoff.
      expect(service.state.isCasting, isTrue);
    });

    test('setVolume forwards a clamped level to the session', () async {
      final handle = _FakeHandle();
      final service = await connectedService(handle);
      handle.pushVolume(const CastVolume(level: 0.5, muted: false));
      await settle();

      await service.setVolume(1.5);

      expect(handle.volumes, <double>[1.0]);
    });

    test('setMuted forwards to the session', () async {
      final handle = _FakeHandle();
      final service = await connectedService(handle);
      handle.pushVolume(const CastVolume(level: 0.5, muted: false));
      await settle();

      await service.setMuted(true);

      expect(handle.mutes, <bool>[true]);
    });

    test('volumeUp / volumeDown nudge from the current level', () async {
      final handle = _FakeHandle();
      final service = await connectedService(handle);
      handle.pushVolume(const CastVolume(level: 0.5, muted: false));
      await settle();

      await service.volumeUp();
      await service.volumeDown();

      expect(handle.volumes, hasLength(2));
      expect(handle.volumes[0], closeTo(0.6, 1e-9));
      expect(handle.volumes[1], closeTo(0.4, 1e-9));
    });

    test('volume commands are safe no-ops when not connected', () async {
      final service = build();
      addTearDown(service.dispose);

      await service.setVolume(0.5);
      await service.setMuted(true);
      await service.volumeUp();
      await service.volumeDown();
      // No throw, nothing connected to forward to.
    });

    test('volume commands are no-ops on a fixed-volume device', () async {
      final handle = _FakeHandle();
      final service = await connectedService(handle);
      handle.pushVolume(
        const CastVolume(level: 0.5, muted: false, controllable: false),
      );
      await settle();
      expect(service.state.supportsVolumeControl, isFalse);

      await service.setVolume(0.8);
      await service.setMuted(true);

      expect(handle.volumes, isEmpty);
      expect(handle.mutes, isEmpty);
    });

    test('a failed volume command surfaces a notice but never stops playback',
        () async {
      final handle = _FakeHandle();
      final service = await connectedService(handle);
      handle.pushVolume(const CastVolume(level: 0.5, muted: false));
      await settle();
      expect(service.state.isCasting, isTrue);

      handle.volumeError = Exception('receiver rejected SET_VOLUME');
      await service.setVolume(0.7);

      // Playback/handoff is untouched, and the raw error never leaks.
      expect(service.state.isCasting, isTrue);
      expect(service.state.message, DefaultCastService.volumeCommandFailed);
      expect(service.state.message, isNot(contains('Exception')));
    });

    test('the device volume survives a track change mid-session', () async {
      final handle = _FakeHandle();
      final service = await connectedService(handle);
      handle.pushVolume(const CastVolume(level: 0.5, muted: false));
      await settle();

      const next = Track(id: 'j2', title: 'Next up', uri: 'jellyfin:j2');
      current = next;
      trackChanges.add(next);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(service.state.volume, 0.5);
      expect(service.state.supportsVolumeControl, isTrue);
    });

    test('disconnect clears the device volume', () async {
      final handle = _FakeHandle();
      final service = await connectedService(handle);
      handle.pushVolume(const CastVolume(level: 0.5, muted: false));
      await settle();
      expect(service.state.supportsVolumeControl, isTrue);

      await service.disconnect();

      expect(service.state.volume, isNull);
      expect(service.state.supportsVolumeControl, isFalse);
    });
  });
}
