import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_media.dart';
import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/cast/cast_media_resolver.dart';
import 'package:linthra/core/services/cast/cast_transport.dart';
import 'package:linthra/core/services/cast/default_cast_service.dart';

/// A [CastSessionHandle] whose readiness and lifetime the test drives. It
/// replays the latest readiness to each new listener, exactly like the real
/// handle, so the service's `firstWhere` sees a session that became ready before
/// it subscribed.
class _FakeHandle implements CastSessionHandle {
  _FakeHandle({bool readyImmediately = true}) {
    if (readyImmediately) _last = true;
  }

  final StreamController<bool> _ready = StreamController<bool>.broadcast();
  bool? _last;
  final List<CastMedia> loaded = <CastMedia>[];
  bool closed = false;

  void becomeReady() {
    _last = true;
    if (!_ready.isClosed) _ready.add(true);
  }

  void drop() {
    _last = false;
    if (!_ready.isClosed) _ready.add(false);
  }

  @override
  Stream<bool> get readyStream async* {
    if (_last != null) yield _last!;
    yield* _ready.stream;
  }

  @override
  Future<void> loadMedia(CastMedia media) async => loaded.add(media);

  @override
  Future<void> close() async {
    closed = true;
    if (!_ready.isClosed) await _ready.close();
  }
}

class _FakeTransport implements CastTransport {
  _FakeTransport();

  List<CastDevice> devices = const <CastDevice>[];
  Object? discoverError;
  Object? connectError;
  _FakeHandle? handle;

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
    return handle ??= _FakeHandle();
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

const _d1 = CastDevice(id: 'd1', name: 'Living Room');
const _jellyfinTrack = Track(id: 'j1', title: 'Streamed', uri: 'jellyfin:j1');
const _localTrack = Track(id: 'l1', title: 'On device', uri: '/music/x.mp3');

void main() {
  late _FakeTransport transport;
  late _FakeResolver resolver;
  late StreamController<Track?> trackChanges;
  Track? current;
  int pauseCount = 0;
  int resumeCount = 0;

  DefaultCastService build() => DefaultCastService(
        transport: transport,
        mediaResolver: resolver,
        currentTrack: () => current,
        trackChanges: trackChanges.stream,
        onCastingStarted: () async => pauseCount++,
        onCastingStopped: () async => resumeCount++,
        discoveryTimeout: const Duration(milliseconds: 5),
        connectTimeout: const Duration(milliseconds: 100),
      );

  setUp(() {
    transport = _FakeTransport();
    resolver = _FakeResolver();
    trackChanges = StreamController<Track?>.broadcast();
    current = null;
    pauseCount = 0;
    resumeCount = 0;
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

    test('settles to an empty idle state when nothing is found', () async {
      transport.devices = const <CastDevice>[];
      final service = build();
      addTearDown(service.dispose);

      await service.startDiscovery();

      expect(service.state.availability, CastAvailability.idle);
      expect(service.state.devices, isEmpty);
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
    test('casts the current streamable track and pauses local playback',
        () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);

      expect(transport.connectRequests, const <CastDevice>[_d1]);
      expect(service.state.isConnected, isTrue);
      expect(service.state.connectedDevice, _d1);
      // The resolved, token-bearing URL reached the receiver.
      expect(handle.loaded, hasLength(1));
      expect(handle.loaded.single.url.queryParameters['api_key'], 'TOKEN');
      expect(handle.loaded.single.title, 'Streamed');
      // Local playback was silenced so audio isn't heard twice.
      expect(pauseCount, 1);
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
      expect(service.state.message, DefaultCastService.localFileLimitation);
      // Nothing was sent to the receiver and local playback was left alone.
      expect(handle.loaded, isEmpty);
      expect(resolver.resolved, isEmpty);
      expect(pauseCount, 0);
    });

    test('a resolve failure surfaces the message but stays connected',
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
      expect(service.state.message, contains('Sign in to Jellyfin'));
      expect(transport.handle!.loaded, isEmpty);
      expect(pauseCount, 0);
    });

    test('a session that never becomes ready becomes an error state', () async {
      current = _jellyfinTrack;
      transport.handle = _FakeHandle(readyImmediately: false);
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);

      expect(service.state.hasError, isTrue);
      expect(service.state.message, contains('Living Room'));
      expect(pauseCount, 0);
    });

    test('a connect failure becomes a friendly error state', () async {
      transport.connectError = Exception('socket refused');
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);

      expect(service.state.hasError, isTrue);
      expect(service.state.message, isNot(contains('Exception')));
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
    });
  });

  group('disconnect + recovery', () {
    test('disconnect closes the session and resumes local playback', () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);
      expect(pauseCount, 1);

      await service.disconnect();

      expect(handle.closed, isTrue);
      expect(resumeCount, 1);
      expect(service.state.availability, CastAvailability.idle);
      expect(service.state.connectedDevice, isNull);
    });

    test('a receiver-dropped session recovers to local playback', () async {
      current = _jellyfinTrack;
      final handle = _FakeHandle();
      transport.handle = handle;
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1);
      handle.drop();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(resumeCount, 1);
      expect(service.state.availability, CastAvailability.idle);
    });
  });

  group('local playback stays stable when not actively casting', () {
    test('merely discovering never pauses local playback', () async {
      current = _jellyfinTrack;
      transport.devices = const <CastDevice>[_d1];
      final service = build();
      addTearDown(service.dispose);

      await service.startDiscovery();

      // Cast is available but no handoff happened, so local playback is
      // untouched and keeps playing.
      expect(pauseCount, 0);
      expect(resumeCount, 0);
    });

    test('disconnecting without a handoff leaves local playback alone',
        () async {
      current = _localTrack;
      resolver.castable = false;
      transport.handle = _FakeHandle();
      final service = build();
      addTearDown(service.dispose);

      await service.connect(_d1); // local file: limitation, no handoff
      await service.disconnect();

      // Never paused, so never force-resumed either.
      expect(pauseCount, 0);
      expect(resumeCount, 0);
    });
  });
}
