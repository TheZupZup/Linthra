import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_media.dart';
import 'package:linthra/core/models/cast_playback_status.dart';
import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/core/models/cast_volume.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/cast/cast_media_resolver.dart';
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
  bool closed = false;

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
  Future<void> loadMedia(CastMedia media) async => loaded.add(media);

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
  Future<void> requestStatus() async => statusRequests++;

  @override
  Future<void> close() async {
    closed = true;
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

  DefaultCastService build() => DefaultCastService(
        transport: transport,
        mediaResolver: resolver,
        currentTrack: () => current,
        trackChanges: trackChanges.stream,
        discoveryTimeout: const Duration(milliseconds: 5),
        connectTimeout: const Duration(milliseconds: 100),
      );

  setUp(() {
    transport = _FakeTransport();
    resolver = _FakeResolver();
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
      // The resolved, token-bearing URL reached the receiver.
      expect(handle.loaded, hasLength(1));
      expect(handle.loaded.single.url.queryParameters['api_key'], 'TOKEN');
      expect(handle.loaded.single.title, 'Streamed');
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
      // The token rode only on the CastMedia handed to the receiver.
      expect(handle.loaded.single.url.queryParameters['api_key'], 'TOKEN');
      // Never in the user-facing state.
      expect(service.state.message ?? '', isNot(contains('TOKEN')));
      expect(service.state.message ?? '', isNot(contains('api_key')));
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
