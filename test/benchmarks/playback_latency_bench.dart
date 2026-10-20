// A measurement harness, not a regression test.
//
// It times the app side of a remote play: from the listener's action (play,
// Next, a track ending) to the moment the engine is told to play. Everything
// up to the engine is real: the provider resolvers and their HTTP clients, the
// reachability memory, the remote playback cache and the prebuffer service,
// against loopback servers that answer each request after [_roundTrip]. The
// engine fetches the URL it is handed and reports ready, so it adds one more
// round trip and nothing of a real decoder's buffering.
//
// Deliberately named `_bench.dart`, not `_test.dart`, so `flutter test` does
// not pick it up: the numbers are machine- and load-dependent. The behaviour
// behind them is covered by real tests (`remote_prebuffer_service_test.dart`,
// `reachability_aware_playable_uri_resolver_test.dart`,
// `session_checked_while_minting_test.dart`, `playback_auto_recovery_test.dart`).
//
// Run it explicitly, and compare two revisions on the same machine:
//
//     flutter test test/benchmarks/playback_latency_bench.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/local_playable_uri_resolver.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_recovery_policy.dart';
import 'package:linthra/core/services/provider_reachability.dart';
import 'package:linthra/core/services/reachability_aware_playable_uri_resolver.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_resolver.dart';
import 'package:linthra/core/services/remote_cache/remote_playback_cache.dart';
import 'package:linthra/core/services/remote_cache/remote_stream_prebufferer.dart';
import 'package:linthra/core/services/remote_prebuffer_service.dart';
import 'package:linthra/core/services/routing_playable_uri_resolver.dart';
import 'package:linthra/core/sources/jellyfin/http_jellyfin_client.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_music_source.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_playable_uri_resolver.dart';
import 'package:linthra/core/sources/plex/http_plex_client.dart';
import 'package:linthra/core/sources/plex/plex_client.dart';
import 'package:linthra/core/sources/plex/plex_music_source.dart';
import 'package:linthra/core/sources/plex/plex_playable_uri_resolver.dart';
import 'package:linthra/core/sources/subsonic/http_subsonic_client.dart';
import 'package:linthra/core/sources/subsonic/subsonic_music_source.dart';
import 'package:linthra/core/sources/subsonic/subsonic_playable_uri_resolver.dart';

import '../support/fake_remote_music_servers.dart';

/// What each request to the server costs: a home server reached over the
/// internet from a phone, roughly.
const Duration _roundTrip = Duration(milliseconds: 100);

const int _runs = 5;

const Duration _trackLength = Duration(minutes: 3, seconds: 40);

/// Records when it was told to open a source and to play.
class _TimingEngine extends Fake implements AudioPlayer {
  _TimingEngine(this._clock);

  final Stopwatch _clock;
  final HttpClient _http = HttpClient();
  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast(sync: true);
  final StreamController<Duration> _positions =
      StreamController<Duration>.broadcast(sync: true);
  final StreamController<Duration?> _durations =
      StreamController<Duration?>.broadcast(sync: true);
  final StreamController<PlaybackEvent> _events =
      StreamController<PlaybackEvent>.broadcast(sync: true);

  final List<Duration> playedAt = <Duration>[];

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;
  @override
  Stream<Duration> get positionStream => _positions.stream;
  @override
  Stream<Duration?> get durationStream => _durations.stream;
  @override
  Stream<PlaybackEvent> get playbackEventStream => _events.stream;

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    final HttpClientRequest request = await _http.getUrl(Uri.parse(url));
    final HttpClientResponse response = await request.close();
    await response.drain<void>();
    if (response.statusCode >= 400) throw Exception('Source error');
    _states.add(PlayerState(false, ProcessingState.ready));
    _durations.add(_trackLength);
    return _trackLength;
  }

  @override
  Future<void> play() async {
    playedAt.add(_clock.elapsed);
    _states.add(PlayerState(true, ProcessingState.ready));
  }

  @override
  Future<void> pause() async =>
      _states.add(PlayerState(false, ProcessingState.ready));

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(Duration? position, {int? index}) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> dispose() async {}

  void tick(Duration position) => _positions.add(position);

  void complete() => _states.add(PlayerState(true, ProcessingState.completed));

  Future<void> close() async {
    _http.close(force: true);
    await _states.close();
    await _positions.close();
    await _durations.close();
    await _events.close();
  }
}

/// One provider's playback stack, wired the way the app wires it.
class _Rig {
  _Rig(this.server, PlayableUriResolver provider) {
    final RoutingPlayableUriResolver router =
        RoutingPlayableUriResolver(<PlayableUriResolver>[
      ReachabilityAwarePlayableUriResolver(
        inner: provider,
        providerKey: () => 'bench',
        reachability: CachingProviderReachability(),
        quickFailureRetryDelay:
            ReachabilityAwarePlayableUriResolver.defaultQuickFailureRetryDelay,
      ),
      const LocalPlayableUriResolver(),
    ]);
    final RemotePlaybackCache cache = RemotePlaybackCache();
    engine = _TimingEngine(clock);
    controller = JustAudioPlaybackController(
      player: engine,
      resolver: RemoteCacheResolver(inner: router, cache: cache, clock: now),
      automaticRecovery: const PlaybackRecoveryPolicy(),
    );
    service = RemotePrebufferService(
      playbackStates: controller.stateStream,
      prebufferer: RemoteStreamPrebufferer(
        resolver: router,
        cache: cache,
        clock: now,
      ),
    );
  }

  final FakeProviderServer server;
  final Stopwatch clock = Stopwatch()..start();
  late final _TimingEngine engine;
  late final JustAudioPlaybackController controller;
  late final RemotePrebufferService service;

  /// The listener's clock, which the bench moves forward to stand for the
  /// minutes a track plays.
  Duration skipped = Duration.zero;
  final DateTime _start = DateTime.now();
  DateTime now() => _start.add(clock.elapsed + skipped);

  Future<void> dispose() async {
    await service.dispose();
    await controller.dispose();
    await engine.close();
  }

  /// Runs [action] and returns how long until the engine was told to play,
  /// or null when playback settled on an error instead.
  Future<Duration?> timeToPlay(Future<void> Function() action) async {
    final int before = engine.playedAt.length;
    final Duration started = clock.elapsed;
    await action();
    final Stopwatch wait = Stopwatch()..start();
    Duration? settledSince;
    while (engine.playedAt.length == before) {
      final bool settled = controller.state.status == PlaybackStatus.error &&
          !controller.hasPendingAutomaticRecovery;
      if (!settled) {
        settledSince = null;
      } else {
        settledSince ??= wait.elapsed;
        if (wait.elapsed - settledSince > const Duration(milliseconds: 500)) {
          return null;
        }
      }
      if (wait.elapsed > const Duration(seconds: 40)) {
        throw StateError('never played (${controller.state.status})');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    return engine.playedAt.last - started;
  }

  /// Lets the prebuffer service finish whatever it started.
  Future<void> idle() =>
      Future<void>.delayed(_roundTrip * 6 + const Duration(milliseconds: 50));

  /// Plays the current track from [from] to [to] on the listener's clock, with
  /// the engine's position ticks along the way.
  Future<void> playThrough(Duration from, Duration to) async {
    const Duration step = Duration(seconds: 10);
    for (Duration at = from; at <= to; at += step) {
      skipped += step;
      engine.tick(at);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

typedef _RigFactory = Future<_Rig> Function();

Track _track(String scheme, int n) =>
    Track(id: '$n', title: 'Track $n', uri: '$scheme:$n');

Future<_Rig> _jellyfin() async {
  final FakeJellyfinServer server = FakeJellyfinServer();
  await server.start();
  server.responseDelay = _roundTrip;
  final JellyfinMusicSource source = JellyfinMusicSource(
    session: server.session,
    client: HttpJellyfinClient(retryBackoff: Duration.zero),
  );
  return _Rig(server, JellyfinPlayableUriResolver(() => source));
}

Future<_Rig> _subsonic() async {
  final FakeSubsonicServer server = FakeSubsonicServer();
  await server.start();
  server.responseDelay = _roundTrip;
  final SubsonicMusicSource source = SubsonicMusicSource(
    session: server.session,
    client: HttpSubsonicClient(),
  );
  return _Rig(server, SubsonicPlayableUriResolver(() => source));
}

Future<_Rig> _plex() async {
  final FakePlexServer server = FakePlexServer();
  await server.start();
  server.responseDelay = _roundTrip;
  final PlexMusicSource source = PlexMusicSource(
    session: server.session,
    client: HttpPlexClient(
      identity: const PlexClientIdentity(
        clientIdentifier: 'install-uuid-1',
        product: 'Linthra',
        version: '0.0.0-bench',
        platform: 'Linux',
        device: 'Linux',
      ),
    ),
  );
  return _Rig(server, PlexPlayableUriResolver(() => source));
}

Future<List<Duration?>> _measure(
  _RigFactory build,
  Future<Duration?> Function(_Rig rig) scenario,
) async {
  final List<Duration?> samples = <Duration?>[];
  for (int run = 0; run < _runs; run++) {
    final _Rig rig = await build();
    try {
      samples.add(await scenario(rig));
    } finally {
      await rig.dispose();
      await rig.server.stop();
    }
  }
  return samples;
}

String _report(List<Duration?> samples) {
  final List<int> ms = samples
      .whereType<Duration>()
      .map((Duration d) => d.inMilliseconds)
      .toList()
    ..sort();
  final int stuck = samples.length - ms.length;
  final String errors =
      stuck == 0 ? '' : '  $stuck/${samples.length} stuck on an error';
  if (ms.isEmpty) return errors.trim();
  return 'median ${ms[ms.length ~/ 2]} ms  (min ${ms.first}, max ${ms.last})'
      '$errors';
}

void main() {
  final Map<String, (_RigFactory, String)> providers =
      <String, (_RigFactory, String)>{
    'Jellyfin': (_jellyfin, 'jellyfin'),
    'Subsonic': (_subsonic, 'subsonic'),
    'Plex': (_plex, 'plex'),
  };

  final Map<String, Future<Duration?> Function(_Rig, String)> scenarios =
      <String, Future<Duration?> Function(_Rig, String)>{
    'first play': (_Rig rig, String scheme) => rig.timeToPlay(
          () => rig.controller.playTracks(<Track>[
            for (int n = 1; n <= 4; n++) _track(scheme, n),
          ]),
        ),
    'Next, 5 s in': (_Rig rig, String scheme) async {
      await rig.timeToPlay(() => rig.controller.playTracks(<Track>[
            for (int n = 1; n <= 4; n++) _track(scheme, n),
          ]));
      await rig.idle();
      rig.skipped += const Duration(seconds: 5);
      return rig.timeToPlay(rig.controller.skipToNext);
    },
    'Next, 2:30 in': (_Rig rig, String scheme) async {
      await rig.timeToPlay(() => rig.controller.playTracks(<Track>[
            for (int n = 1; n <= 4; n++) _track(scheme, n),
          ]));
      await rig.idle();
      await rig.playThrough(
          Duration.zero, const Duration(minutes: 2, seconds: 30));
      await rig.idle();
      return rig.timeToPlay(rig.controller.skipToNext);
    },
    'track ends': (_Rig rig, String scheme) async {
      await rig.timeToPlay(() => rig.controller.playTracks(<Track>[
            for (int n = 1; n <= 4; n++) _track(scheme, n),
          ]));
      await rig.idle();
      await rig.playThrough(Duration.zero, _trackLength);
      await rig.idle();
      return rig.timeToPlay(() async => rig.engine.complete());
    },
    '150 ms network blip': (_Rig rig, String scheme) async {
      await rig.timeToPlay(() => rig.controller.playTracks(<Track>[
            for (int n = 1; n <= 4; n++) _track(scheme, n),
          ]));
      await rig.idle();
      rig.skipped += const Duration(minutes: 3);
      // Requests reaching the server in the next 150 ms have their
      // connection cut.
      rig.server.refuseConnections = true;
      unawaited(Future<void>.delayed(_roundTrip * 1.5, () {
        rig.server.refuseConnections = false;
      }));
      return rig.timeToPlay(rig.controller.skipToNext);
    },
    '3 s outage': (_Rig rig, String scheme) async {
      await rig.timeToPlay(() => rig.controller.playTracks(<Track>[
            for (int n = 1; n <= 4; n++) _track(scheme, n),
          ]));
      await rig.idle();
      rig.skipped += const Duration(minutes: 3);
      rig.server.refuseConnections = true;
      unawaited(Future<void>.delayed(const Duration(seconds: 3), () {
        rig.server.refuseConnections = false;
      }));
      return rig.timeToPlay(rig.controller.skipToNext);
    },
  };

  test('playback latency', () async {
    final StringBuffer out = StringBuffer()
      ..writeln()
      ..writeln('Each request answered after ${_roundTrip.inMilliseconds} ms; '
          '$_runs runs each.');
    for (final MapEntry<String, (_RigFactory, String)> provider
        in providers.entries) {
      out.writeln(provider.key);
      for (final MapEntry<String,
              Future<Duration?> Function(_Rig, String)> scenario
          in scenarios.entries) {
        final List<Duration?> samples = await _measure(
          provider.value.$1,
          (_Rig rig) => scenario.value(rig, provider.value.$2),
        );
        out.writeln('  ${scenario.key.padRight(20)} ${_report(samples)}');
        // ignore: avoid_print
        print('${provider.key} ${scenario.key}: ${_report(samples)}');
      }
    }
    // ignore: avoid_print
    print(out);
  }, timeout: const Timeout(Duration(minutes: 20)));
}
