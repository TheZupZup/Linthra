import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/diagnostics/safe_event_log.dart';
import 'package:linthra/core/models/persisted_playback_session.dart';
import 'package:linthra/core/models/playback_failure.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/linux_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_candidate_source.dart';
import 'package:linthra/core/services/playback_session_persistence.dart';
import 'package:linthra/core/services/routing_playable_uri_resolver.dart';
import 'package:linthra/core/sources/jellyfin/http_jellyfin_client.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_music_source.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_playable_uri_resolver.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_stream_source.dart';
import 'package:linthra/core/sources/plex/http_plex_client.dart';
import 'package:linthra/core/sources/plex/plex_client.dart';
import 'package:linthra/core/sources/plex/plex_music_source.dart';
import 'package:linthra/core/sources/plex/plex_playable_uri_resolver.dart';
import 'package:linthra/core/sources/plex/plex_stream_source.dart';
import 'package:linthra/core/sources/subsonic/http_subsonic_client.dart';
import 'package:linthra/core/sources/subsonic/subsonic_music_source.dart';
import 'package:linthra/core/sources/subsonic/subsonic_playable_uri_resolver.dart';
import 'package:linthra/core/sources/subsonic/subsonic_stream_source.dart';
import 'package:linthra/data/repositories/in_memory_playback_session_store.dart';

import '../../support/fake_remote_music_servers.dart';

/// An [AudioPlayer] stand-in that goes as far toward libmpv as a VM test can:
/// what it is handed it actually fetches, over HTTP, off the same loopback
/// socket the resolver just authenticated against.
///
/// It keeps the *shape* of the real engine — an open that can fail, a
/// player-state stream, a `playbackEventStream` that carries mid-stream errors
/// — and adds the one thing a pure mock cannot: a URL the server would reject
/// fails the load here too, which is what turns "the stream URL that reached
/// the engine really was valid" from an assumption into an assertion.
///
/// Its failures deliberately quote the URL, because the real backend's do
/// (`Failed to open <uri>`, passed straight through by the vendored
/// just_audio_media_kit). That is the leak path the controller has to contain,
/// so the tests get to prove it does.
class LoopbackEngine extends Fake implements AudioPlayer {
  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast(sync: true);
  final StreamController<Duration> _positions =
      StreamController<Duration>.broadcast(sync: true);
  final StreamController<Duration?> _durations =
      StreamController<Duration?>.broadcast(sync: true);
  final StreamController<PlaybackEvent> _events =
      StreamController<PlaybackEvent>.broadcast(sync: true);
  final HttpClient _http = HttpClient();

  /// Every URL handed to the engine, in order.
  final List<String> opened = <String>[];

  /// The status each fetch came back with — proof the bytes were really served.
  final List<int> fetched = <int>[];

  final List<Duration> seeks = <Duration>[];

  /// When true, the open fails *after* fetching, with an error quoting the
  /// URL — what the vendored media_kit backend passes through as
  /// `Failed to open <uri>`.
  bool failLoadQuotingUrl = false;

  /// The text of the last load failure, so a test can show the engine really
  /// held the credential the listener never sees.
  String? lastLoadError;

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
    opened.add(url);
    final HttpClientRequest request = await _http.getUrl(Uri.parse(url));
    final HttpClientResponse response = await request.close();
    await response.drain<void>();
    fetched.add(response.statusCode);
    if (response.statusCode >= 400 || failLoadQuotingUrl) {
      final String message = 'Failed to open $url';
      lastLoadError = message;
      throw Exception(message);
    }
    return const Duration(minutes: 4);
  }

  @override
  Future<void> play() async =>
      _states.add(PlayerState(true, ProcessingState.ready));

  @override
  Future<void> pause() async =>
      _states.add(PlayerState(false, ProcessingState.ready));

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (position != null) seeks.add(position);
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> dispose() async {}

  /// Ends the current track naturally, as the engine does at the last sample.
  void completeTrack() =>
      _states.add(PlayerState(false, ProcessingState.completed));

  /// Drops the stream mid-playback with an error that quotes the authenticated
  /// URL, exactly as the real backend's does.
  void failMidStream() {
    final String url = opened.isEmpty ? '<none>' : opened.last;
    _events.addError(Exception('Failed to open $url'), StackTrace.empty);
  }

  Future<void> close() async {
    _http.close(force: true);
    await _states.close();
    await _positions.close();
    await _durations.close();
    await _events.close();
  }
}

/// Linux remote-stream integration tests (issue #424).
///
/// These go further than the resolver and controller unit suites, which each
/// stub the other side out. Here the whole Linux remote chain runs for real:
///
///   an opaque `jellyfin:` / `subsonic:` / `plex:` track
///     → [RoutingPlayableUriResolver]
///     → the provider resolver and its `*MusicSource`
///     → the real `Http*Client` over a real socket
///     → a loopback fake server that checks the credential
///     → the minted URL handed to [LinuxPlaybackController]
///     → an engine that really fetches those bytes back off the socket.
///
/// Nothing external is required: no home server, no credential from CI, no DNS,
/// no public internet. Every server binds `127.0.0.1` on an ephemeral port with
/// a synthetic token this file created, and is torn down with the test.
///
/// What stays out of reach here is libmpv itself. `flutter test` runs on the
/// Dart VM without the Linux plugin bundle, so the last hop — media_kit
/// decoding those bytes and putting them out through PipeWire — is exercised by
/// `tool/linux_audio_backend_smoke.dart` and the manual matrix in
/// docs/linux-desktop.md instead. Everything up to and including the handoff to
/// the engine is real here, and the Linux-specific seams
/// ([LinuxPlaybackBackendInitializer], the preflight, the load-time
/// classification) run as they do in the app.
void main() {
  // ---------------------------------------------------------------------------
  // Fixtures
  // ---------------------------------------------------------------------------

  setUp(SafeEventLog.instance.clear);

  LoopbackEngine newEngine() {
    final LoopbackEngine engine = LoopbackEngine();
    addTearDown(engine.close);
    return engine;
  }

  /// Waits until [predicate] holds, then returns.
  ///
  /// Transitions that nothing hands back a future for — a track ending, a
  /// stream dropping — settle through a real socket here, and a fixed number of
  /// event-queue pumps is a guess about how long that takes. Waiting for the
  /// outcome itself is the deterministic version: the loop ends the moment the
  /// state is right (microseconds, on loopback), and the bound only exists so a
  /// broken expectation fails loudly instead of hanging the suite.
  Future<void> waitFor(
    bool Function() predicate, {
    required String describe,
  }) async {
    final Stopwatch clock = Stopwatch()..start();
    while (!predicate()) {
      if (clock.elapsed > const Duration(seconds: 10)) {
        fail('timed out waiting for $describe');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    // The observable state can land a microtask before the controller's own
    // bookkeeping does — playback reaches `playing` inside `_playCurrent`,
    // while the recovery gate reopens in the `finally` that runs after it
    // returns. Draining what is already scheduled closes that window, so a test
    // that pushes the next failure straight after a wait cannot have it
    // swallowed as a duplicate.
    await pumpEventQueue();
  }

  Future<FakeJellyfinServer> jellyfinServer({
    Set<String> knownItemIds = const <String>{},
  }) async {
    final FakeJellyfinServer server =
        FakeJellyfinServer(knownItemIds: knownItemIds);
    await server.start();
    addTearDown(server.stop);
    return server;
  }

  Future<FakeSubsonicServer> subsonicServer() async {
    final FakeSubsonicServer server = FakeSubsonicServer();
    await server.start();
    addTearDown(server.stop);
    return server;
  }

  Future<FakePlexServer> plexServer({
    Set<String> knownRatingKeys = const <String>{},
    Set<String> itemsWithoutPart = const <String>{},
  }) async {
    final FakePlexServer server = FakePlexServer(
      knownRatingKeys: knownRatingKeys,
      itemsWithoutPart: itemsWithoutPart,
    );
    await server.start();
    addTearDown(server.stop);
    return server;
  }

  JellyfinStreamSource jellyfinSource(FakeJellyfinServer server) =>
      JellyfinMusicSource(
        session: server.session,
        client: HttpJellyfinClient(retryBackoff: Duration.zero),
      );

  SubsonicStreamSource subsonicSource(FakeSubsonicServer server) =>
      SubsonicMusicSource(
        session: server.session,
        client: HttpSubsonicClient(),
      );

  PlexStreamSource plexSource(FakePlexServer server) => PlexMusicSource(
        session: server.session,
        client: HttpPlexClient(
          identity: const PlexClientIdentity(
            clientIdentifier: 'install-uuid-1',
            product: 'Linthra',
            version: '0.0.0-test',
            platform: 'Linux',
            device: 'Linux',
          ),
        ),
      );

  /// The same routing resolver `remoteSourceRouterProvider` composes, minus the
  /// reachability cache (which is a separate seam with its own suite) and the
  /// on-device resolver (nothing here is a local file). A provider with no
  /// server is passed as null, which is exactly how a signed-out provider looks
  /// to the router.
  PlayableUriResolver router({
    JellyfinStreamSource? jellyfin,
    SubsonicStreamSource? subsonic,
    PlexStreamSource? plex,
  }) =>
      RoutingPlayableUriResolver(<PlayableUriResolver>[
        JellyfinPlayableUriResolver(() => jellyfin),
        SubsonicPlayableUriResolver(() => subsonic),
        PlexPlayableUriResolver(() => plex),
      ]);

  /// A [LinuxPlaybackController] wired the way the Linux provider graph wires
  /// it, with the native backend seam present (its registration is a no-op
  /// here, because `flutter test` has no plugin bundle to register) so the
  /// Linux preflight and load-time classification really run.
  LinuxPlaybackController controllerFor(
    LoopbackEngine engine,
    PlayableUriResolver resolver, {
    PlaybackCandidateSource candidates = const NoFallbackCandidateSource(),
    void Function(Track track)? onTrackCompleted,
  }) {
    final LinuxPlaybackController controller = LinuxPlaybackController(
      player: engine,
      resolver: resolver,
      candidates: candidates,
      backend: LinuxPlaybackBackendInitializer(registerBackend: () {}),
      onTrackCompleted: onTrackCompleted,
    )
      // Deterministic and fast: the mid-stream backoff is a real wait and
      // nothing here is testing how long it is. The buffering watchdog keeps
      // its production timeout — it must not fire during a test — and dispose
      // cancels it.
      ..streamRetryBackoff = Duration.zero;
    addTearDown(controller.dispose);
    return controller;
  }

  Track jellyfinTrack(String id) =>
      Track(id: id, title: 'Track $id', uri: 'jellyfin:$id');
  Track subsonicTrack(String id) =>
      Track(id: id, title: 'Track $id', uri: 'subsonic:$id');
  Track plexTrack(String id) =>
      Track(id: id, title: 'Track $id', uri: 'plex:$id');

  /// Every synthetic secret these tests create. Nothing the app produces — a
  /// track, a state, a message, a breadcrumb, a persisted session — may contain
  /// any of them.
  const List<String> syntheticSecrets = <String>[
    syntheticJellyfinToken,
    syntheticSubsonicToken,
    syntheticSubsonicSalt,
    syntheticPlexToken,
  ];

  void expectFreeOfSecrets(String? text, {required String what}) {
    if (text == null) return;
    for (final String secret in syntheticSecrets) {
      expect(text, isNot(contains(secret)),
          reason: '$what leaked a credential');
    }
  }

  /// Asserts the things that must hold after *any* remote play, successful or
  /// not: the queue's identity stays opaque, nothing the UI can show carries a
  /// credential, and neither do the breadcrumbs a bug report would include.
  void expectCredentialsContained(LinuxPlaybackController controller) {
    final PlaybackState state = controller.state;
    for (final Track track in <Track>[
      if (state.currentTrack != null) state.currentTrack!,
      ...state.upNext,
      ...state.previous,
    ]) {
      expectFreeOfSecrets(track.uri, what: 'track uri');
      expectFreeOfSecrets(track.id, what: 'track id');
      expectFreeOfSecrets(track.title, what: 'track title');
      expect(
        track.uri,
        isNot(contains('://')),
        reason: 'a queued track must stay a logical reference, not a URL',
      );
    }
    expectFreeOfSecrets(state.errorMessage, what: 'error message');
    expectFreeOfSecrets(state.failure?.message, what: 'failure message');
    for (final String line in SafeEventLog.instance.lines) {
      expectFreeOfSecrets(line, what: 'diagnostics breadcrumb');
      expect(line, isNot(contains('://')),
          reason: 'a breadcrumb must never carry a URL');
    }
  }

  // ---------------------------------------------------------------------------
  // 1–4. Opaque reference → fresh authenticated URL → Linux load → lifecycle
  // ---------------------------------------------------------------------------

  group('Jellyfin-shaped remote playback on Linux', () {
    test('resolves a fresh authenticated URL and plays it through the engine',
        () async {
      final FakeJellyfinServer server = await jellyfinServer();
      final LoopbackEngine engine = newEngine();
      final LinuxPlaybackController controller = controllerFor(
        engine,
        router(jellyfin: jellyfinSource(server)),
      );

      await controller.playTrack(jellyfinTrack('101'));

      // The session was checked before anything was minted, and the stream URL
      // carried the token in the query — which is what the engine fetches with.
      expect(
        server.requests.map((FakeServerRequest r) => r.path),
        containsAllInOrder(<String>['/Users/Me', '/Audio/101/stream']),
      );
      final FakeServerRequest probe = server.streamProbes.single;
      expect(probe.query['ApiKey'], syntheticJellyfinToken);
      expect(probe.query['static'], 'true');

      // The engine was handed that URL and really fetched it back.
      expect(engine.opened, hasLength(1));
      expect(Uri.parse(engine.opened.single).path, '/Audio/101/stream');
      expect(engine.fetched, hasLength(1));
      expect(controller.state.status, PlaybackStatus.playing);
      expect(controller.state.source, PlaybackSource.streamingDirect);
      expectCredentialsContained(controller);
    });

    test('keeps the queued reference opaque and mints a URL per play',
        () async {
      final FakeJellyfinServer server = await jellyfinServer();
      final LinuxPlaybackController controller = controllerFor(
        newEngine(),
        router(jellyfin: jellyfinSource(server)),
      );
      final Track track = jellyfinTrack('101');

      await controller.playTrack(track);
      await controller.playTrack(track);

      // Two plays, two resolutions: nothing authenticated was cached on the
      // track between them.
      expect(server.streamProbes, hasLength(2));
      expect(server.streamFetches, hasLength(2));
      expect(controller.state.currentTrack!.uri, 'jellyfin:101');
      expectCredentialsContained(controller);
    });

    test(
        'an item that is gone from the server fails as unavailable, not as auth',
        () async {
      // The library row is stale: the server still knows the session, but not
      // this item. The probe is what finds out.
      final FakeJellyfinServer server =
          await jellyfinServer(knownItemIds: <String>{'101'});
      final LinuxPlaybackController controller = controllerFor(
        newEngine(),
        router(jellyfin: jellyfinSource(server)),
      );

      await controller.playTrack(jellyfinTrack('999'));

      expect(controller.state.status, PlaybackStatus.error);
      expect(
        controller.state.failure!.kind,
        PlaybackFailureKind.temporarySource,
      );
      expectCredentialsContained(controller);
    });

    test('play, pause, seek and stop drive the engine and stay truthful',
        () async {
      final FakeJellyfinServer server = await jellyfinServer();
      final LoopbackEngine engine = newEngine();
      final LinuxPlaybackController controller = controllerFor(
        engine,
        router(jellyfin: jellyfinSource(server)),
      );

      await controller.playTrack(jellyfinTrack('101'));
      expect(controller.state.status, PlaybackStatus.playing);

      await controller.pause();
      expect(controller.state.status, PlaybackStatus.paused);

      await controller.seek(const Duration(seconds: 42));
      expect(engine.seeks, <Duration>[const Duration(seconds: 42)]);

      await controller.play();
      expect(controller.state.status, PlaybackStatus.playing);

      await controller.stop();
      expect(controller.state.status, PlaybackStatus.idle);
      // One resolution for the whole lifecycle: pause/seek/play never re-mint.
      expect(server.streamProbes, hasLength(1));
      expectCredentialsContained(controller);
    });
  });

  group('Navidrome/Subsonic-shaped remote playback on Linux', () {
    test('resolves a fresh salt+token URL and plays it through the engine',
        () async {
      final FakeSubsonicServer server = await subsonicServer();
      final LoopbackEngine engine = newEngine();
      final LinuxPlaybackController controller = controllerFor(
        engine,
        router(subsonic: subsonicSource(server)),
      );

      await controller.playTrack(subsonicTrack('song-7'));

      expect(
        server.requests.map((FakeServerRequest r) => r.path),
        containsAllInOrder(<String>['/rest/ping.view', '/rest/stream.view']),
      );
      final FakeServerRequest probe = server.streamProbes.single;
      expect(probe.query['id'], 'song-7');
      expect(probe.query['t'], syntheticSubsonicToken);
      expect(probe.query['s'], syntheticSubsonicSalt);

      expect(engine.fetched, hasLength(1));
      expect(controller.state.status, PlaybackStatus.playing);
      expect(controller.state.source, PlaybackSource.streamingDirect);
      expect(controller.state.currentTrack!.uri, 'subsonic:song-7');
      expectCredentialsContained(controller);
    });
  });

  group('Plex-shaped remote playback on Linux', () {
    test('walks identity → Part lookup → tokenized Part fetch', () async {
      final FakePlexServer server = await plexServer();
      final LoopbackEngine engine = newEngine();
      final LinuxPlaybackController controller = controllerFor(
        engine,
        router(plex: plexSource(server)),
      );

      await controller.playTrack(plexTrack('4242'));

      expect(
        server.requests.map((FakeServerRequest r) => r.path),
        containsAllInOrder(<String>[
          '/identity',
          '/library/metadata/4242',
          FakePlexServer.partKeyFor('4242'),
        ]),
      );
      // The token rides in a header for the API calls and only reaches a query
      // on the Part URL the engine fetches.
      final FakeServerRequest metadata = server.requests.firstWhere(
          (FakeServerRequest r) => r.path.startsWith('/library/metadata/'));
      expect(metadata.query, isEmpty);
      expect(metadata.headers['x-plex-token'], syntheticPlexToken);
      expect(
        server.streamFetches.single.query['X-Plex-Token'],
        syntheticPlexToken,
      );
      // Plex resolves in two steps and never probes the stream, so the Part is
      // fetched exactly once — by the engine.
      expect(server.streamProbes, isEmpty);

      expect(engine.fetched, hasLength(1));
      expect(controller.state.status, PlaybackStatus.playing);
      expect(controller.state.currentTrack!.uri, 'plex:4242');
      expectCredentialsContained(controller);
    });

    test('a rating key the server no longer knows never reaches the engine',
        () async {
      final FakePlexServer server =
          await plexServer(knownRatingKeys: <String>{'4242'});
      final LoopbackEngine engine = newEngine();
      final LinuxPlaybackController controller = controllerFor(
        engine,
        router(plex: plexSource(server)),
      );

      await controller.playTrack(plexTrack('9999'));

      expect(controller.state.status, PlaybackStatus.error);
      expect(
        controller.state.failure!.kind,
        PlaybackFailureKind.temporarySource,
      );
      // Plex resolves in two steps, so a vanished item is settled at the
      // lookup: no token is ever woven into a URL for it.
      expect(server.streamRequests, isEmpty);
      expect(engine.opened, isEmpty);
      expectCredentialsContained(controller);
    });

    test('an item with no playable part fails precisely, not generically',
        () async {
      final FakePlexServer server =
          await plexServer(itemsWithoutPart: <String>{'4242'});
      final LinuxPlaybackController controller = controllerFor(
        newEngine(),
        router(plex: plexSource(server)),
      );

      await controller.playTrack(plexTrack('4242'));

      expect(controller.state.status, PlaybackStatus.error);
      expect(
          controller.state.failure!.kind, PlaybackFailureKind.temporarySource);
      expect(controller.state.failure!.message, contains('Plex'));
      expect(server.streamRequests, isEmpty);
      expectCredentialsContained(controller);
    });
  });

  // ---------------------------------------------------------------------------
  // 5. Queue transition
  // ---------------------------------------------------------------------------

  group('queue transitions across providers', () {
    test('completing a track advances and re-resolves the next one', () async {
      final FakeJellyfinServer jellyfin = await jellyfinServer();
      final FakeSubsonicServer subsonic = await subsonicServer();
      final LoopbackEngine engine = newEngine();
      final List<Track> completed = <Track>[];
      final LinuxPlaybackController controller = controllerFor(
        engine,
        router(
          jellyfin: jellyfinSource(jellyfin),
          subsonic: subsonicSource(subsonic),
        ),
        onTrackCompleted: completed.add,
      );

      await controller.playTracks(<Track>[
        jellyfinTrack('101'),
        subsonicTrack('song-7'),
      ]);
      expect(controller.state.currentTrack!.uri, 'jellyfin:101');

      engine.completeTrack();
      await waitFor(
        () =>
            controller.state.status == PlaybackStatus.playing &&
            controller.state.currentTrack!.uri == 'subsonic:song-7',
        describe: 'the next track to resolve and start',
      );

      expect(completed.map((Track t) => t.uri), <String>['jellyfin:101']);
      // The second track was resolved against its own provider, on its own.
      expect(jellyfin.streamProbes, hasLength(1));
      expect(subsonic.streamProbes, hasLength(1));
      expect(engine.opened, hasLength(2));
      expectCredentialsContained(controller);
    });

    test(
        'skipping forward resolves the next track and back re-resolves the first',
        () async {
      final FakeJellyfinServer jellyfin = await jellyfinServer();
      final FakePlexServer plex = await plexServer();
      final LinuxPlaybackController controller = controllerFor(
        newEngine(),
        router(jellyfin: jellyfinSource(jellyfin), plex: plexSource(plex)),
      );

      await controller.playTracks(<Track>[
        jellyfinTrack('101'),
        plexTrack('4242'),
      ]);
      await controller.skipToNext();
      expect(controller.state.currentTrack!.uri, 'plex:4242');

      await controller.skipToPrevious();
      expect(controller.state.currentTrack!.uri, 'jellyfin:101');

      // Coming back re-mints rather than reusing the first URL.
      expect(jellyfin.streamProbes, hasLength(2));
      expect(plex.metadataRequests, hasLength(1));
      expectCredentialsContained(controller);
    });
  });

  // ---------------------------------------------------------------------------
  // 6. Bounded retry / re-resolution
  // ---------------------------------------------------------------------------

  group('bounded retry and re-resolution', () {
    test('a mid-stream drop re-resolves once, then gives up with a safe error',
        () async {
      final FakeJellyfinServer server = await jellyfinServer();
      final LoopbackEngine engine = newEngine();
      final LinuxPlaybackController controller = controllerFor(
        engine,
        router(jellyfin: jellyfinSource(server)),
      );

      await controller.playTrack(jellyfinTrack('101'));
      expect(server.streamProbes, hasLength(1));

      // The stream dies the way a real one does: an engine error quoting the
      // authenticated URL it was fetching.
      engine.failMidStream();
      await waitFor(
        () => controller.state.status == PlaybackStatus.playing,
        describe: 'the bounded retry to re-resolve and start',
      );

      // One bounded retry, and it went back to the provider for a *new* URL
      // rather than reusing the dead one.
      expect(server.streamProbes, hasLength(2));
      expect(
        server.streamProbes.last.query['ApiKey'],
        syntheticJellyfinToken,
      );
      expect(controller.state.status, PlaybackStatus.playing);

      // A second drop has no budget left: it ends as an error, not a loop.
      engine.failMidStream();
      await waitFor(
        () => controller.state.status == PlaybackStatus.error,
        describe: 'the spent retry budget to surface an error',
      );

      expect(server.streamProbes, hasLength(2));
      expect(controller.state.status, PlaybackStatus.error);
      // The sweep below is only worth anything if something was recorded: a
      // failed stream leaves breadcrumbs, and none of them may carry the URL.
      expect(SafeEventLog.instance.lines, isNotEmpty);
      expectCredentialsContained(controller);
    });

    test('a listener-driven Retry re-resolves against the recovered server',
        () async {
      final FakeJellyfinServer server = await jellyfinServer();
      // The first resolve finds the stream endpoint down.
      server.failingStreamRequests = 1;
      final LinuxPlaybackController controller = controllerFor(
        newEngine(),
        router(jellyfin: jellyfinSource(server)),
      );

      await controller.playTrack(jellyfinTrack('101'));
      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.failure!.canRetry, isTrue);

      await controller.retryCurrentTrack();

      expect(controller.state.status, PlaybackStatus.playing);
      expect(server.streamProbes, hasLength(2));
      expectCredentialsContained(controller);
    });

    test('an unreachable server fails with a friendly, secret-free message',
        () async {
      final FakeSubsonicServer server = await subsonicServer();
      server.refuseConnections = true;
      final LinuxPlaybackController controller = controllerFor(
        newEngine(),
        router(subsonic: subsonicSource(server)),
      );

      await controller.playTrack(subsonicTrack('song-7'));

      expect(controller.state.status, PlaybackStatus.error);
      expect(
        controller.state.failure!.kind,
        PlaybackFailureKind.temporarySource,
      );
      expect(controller.state.failure!.message, contains('music server'));
      expectCredentialsContained(controller);
    });
  });

  // ---------------------------------------------------------------------------
  // 7. Provider / session expiration
  // ---------------------------------------------------------------------------

  group('provider session expiry', () {
    test('Jellyfin: a rejected session asks for a sign-in, not a retry',
        () async {
      final FakeJellyfinServer server = await jellyfinServer();
      final LinuxPlaybackController controller = controllerFor(
        newEngine(),
        router(jellyfin: jellyfinSource(server)),
      );

      await controller.playTrack(jellyfinTrack('101'));
      expect(controller.state.status, PlaybackStatus.playing);

      // The server stops accepting the token mid-session.
      server.sessionValid = false;
      await controller.playTrack(jellyfinTrack('102'));

      final PlaybackFailure failure = controller.state.failure!;
      expect(controller.state.status, PlaybackStatus.error);
      expect(failure.kind, PlaybackFailureKind.sourceSignInRequired);
      expect(failure.message, contains('Jellyfin'));
      expect(failure.canRetry, isFalse);
      expectCredentialsContained(controller);
    });

    test('Subsonic: a rejected credential is an expiry, not an outage',
        () async {
      final FakeSubsonicServer server = await subsonicServer();
      server.sessionValid = false;
      final LinuxPlaybackController controller = controllerFor(
        newEngine(),
        router(subsonic: subsonicSource(server)),
      );

      await controller.playTrack(subsonicTrack('song-7'));

      expect(
        controller.state.failure!.kind,
        PlaybackFailureKind.sourceSignInRequired,
      );
      expect(server.streamRequests, isEmpty);
      expectCredentialsContained(controller);
    });

    test('Plex: a rejected token steers to reconnecting in Settings', () async {
      final FakePlexServer server = await plexServer();
      server.sessionValid = false;
      final LinuxPlaybackController controller = controllerFor(
        newEngine(),
        router(plex: plexSource(server)),
      );

      await controller.playTrack(plexTrack('4242'));

      final PlaybackFailure failure = controller.state.failure!;
      expect(failure.kind, PlaybackFailureKind.sourceSignInRequired);
      expect(failure.message, contains('Plex'));
      expectCredentialsContained(controller);
    });

    test(
        'a signed-out provider is recognised and refused, never fallen through',
        () async {
      final LinuxPlaybackController controller = controllerFor(
        newEngine(),
        router(),
      );

      await controller.playTrack(plexTrack('4242'));

      expect(
        controller.state.failure!.kind,
        PlaybackFailureKind.sourceSignInRequired,
      );
      expectCredentialsContained(controller);
    });
  });

  // ---------------------------------------------------------------------------
  // 8. Cross-provider fallback
  // ---------------------------------------------------------------------------

  group('cross-provider fallback', () {
    test('a failing Jellyfin copy falls back to the Navidrome copy and plays',
        () async {
      final FakeJellyfinServer jellyfin = await jellyfinServer();
      final FakeSubsonicServer subsonic = await subsonicServer();
      jellyfin.sessionValid = false;
      final Track preferred = jellyfinTrack('101');
      final Track sibling = subsonicTrack('101');
      final LoopbackEngine engine = newEngine();
      final LinuxPlaybackController controller = controllerFor(
        engine,
        router(
          jellyfin: jellyfinSource(jellyfin),
          subsonic: subsonicSource(subsonic),
        ),
        candidates: MapPlaybackCandidateSource(
          () => <String, List<Track>>{
            preferred.uri: <Track>[preferred, sibling],
          },
        ),
      );

      await controller.playTrack(preferred);

      // The preferred copy was tried first and the sibling actually played.
      expect(jellyfin.streamRequests, isEmpty);
      expect(subsonic.streamProbes, hasLength(1));
      expect(controller.state.status, PlaybackStatus.playing);
      expect(controller.state.currentTrack!.uri, 'subsonic:101');
      expect(engine.fetched, hasLength(1));
      expectCredentialsContained(controller);
    });

    test('a mid-stream drop with the budget spent moves to the sibling copy',
        () async {
      final FakeJellyfinServer jellyfin = await jellyfinServer();
      final FakePlexServer plex = await plexServer();
      final Track preferred = jellyfinTrack('101');
      final Track sibling = plexTrack('101');
      final LoopbackEngine engine = newEngine();
      final LinuxPlaybackController controller = controllerFor(
        engine,
        router(jellyfin: jellyfinSource(jellyfin), plex: plexSource(plex)),
        candidates: MapPlaybackCandidateSource(
          () => <String, List<Track>>{
            preferred.uri: <Track>[preferred, sibling],
          },
        ),
      );

      await controller.playTrack(preferred);
      expect(controller.state.currentTrack!.uri, 'jellyfin:101');

      // Two drops: the first spends the bounded retry, the second exhausts it
      // and hands over to the next candidate.
      engine.failMidStream();
      await waitFor(
        () => controller.state.status == PlaybackStatus.playing,
        describe: 'the bounded retry to re-resolve and start',
      );
      engine.failMidStream();
      await waitFor(
        () =>
            controller.state.currentTrack!.uri == 'plex:101' &&
            controller.state.status == PlaybackStatus.playing,
        describe: 'the sibling copy to take over',
      );
      expect(plex.streamFetches, hasLength(1));
      expectCredentialsContained(controller);
    });

    test('every copy failing collapses to one safe error', () async {
      final FakeJellyfinServer jellyfin = await jellyfinServer();
      final FakeSubsonicServer subsonic = await subsonicServer();
      jellyfin.sessionValid = false;
      subsonic.sessionValid = false;
      final Track preferred = jellyfinTrack('101');
      final Track sibling = subsonicTrack('101');
      final LinuxPlaybackController controller = controllerFor(
        newEngine(),
        router(
          jellyfin: jellyfinSource(jellyfin),
          subsonic: subsonicSource(subsonic),
        ),
        candidates: MapPlaybackCandidateSource(
          () => <String, List<Track>>{
            preferred.uri: <Track>[preferred, sibling],
          },
        ),
      );

      await controller.playTrack(preferred);

      expect(controller.state.status, PlaybackStatus.error);
      // Both failed the same way, so the kind survives but the wording does not
      // pin it on one provider.
      expect(
        controller.state.failure!.kind,
        PlaybackFailureKind.sourceSignInRequired,
      );
      expect(
          controller.state.failure!.message, contains('any available source'));
      expectCredentialsContained(controller);
    });
  });

  // ---------------------------------------------------------------------------
  // The Linux-specific engine seam, with a real provider behind it
  // ---------------------------------------------------------------------------

  group('the Linux audio backend seam', () {
    /// A registration that fails while [broken] — what a machine with no
    /// libmpv does. Clearing it is the listener installing the package.
    late bool broken;
    late int registrations;

    LinuxPlaybackBackendInitializer brokenBackend() {
      broken = true;
      registrations = 0;
      return LinuxPlaybackBackendInitializer(
        registerBackend: () {
          registrations++;
          if (broken) {
            throw Exception(
              'Exception: Cannot find libmpv at the usual places. Depending '
              'upon your distribution, you can install the libmpv package to '
              'make shared library available globally.',
            );
          }
        },
      );
    }

    test('refuses before a single credential is minted', () async {
      final FakeJellyfinServer server = await jellyfinServer();
      final LoopbackEngine engine = newEngine();
      final LinuxPlaybackController controller = LinuxPlaybackController(
        player: engine,
        resolver: router(jellyfin: jellyfinSource(server)),
        backend: brokenBackend(),
      );
      addTearDown(controller.dispose);

      await controller.playTrack(jellyfinTrack('101'));

      expect(
        controller.state.failure!.kind,
        PlaybackFailureKind.playbackEngineUnavailable,
      );
      // The whole point of settling this at the preflight: no session check, no
      // minted URL, no round trip to the provider for an engine that cannot
      // take the bytes anyway.
      expect(server.requests, isEmpty);
      expect(engine.opened, isEmpty);
      expectCredentialsContained(controller);
    });

    test('Retry after the package is installed reaches the provider and plays',
        () async {
      final FakeJellyfinServer server = await jellyfinServer();
      final LoopbackEngine engine = newEngine();
      final LinuxPlaybackController controller = LinuxPlaybackController(
        player: engine,
        resolver: router(jellyfin: jellyfinSource(server)),
        backend: brokenBackend(),
      );
      addTearDown(controller.dispose);

      await controller.playTrack(jellyfinTrack('101'));
      expect(controller.state.status, PlaybackStatus.error);

      // The listener installs libmpv and presses Retry.
      broken = false;
      await controller.retryCurrentTrack();

      expect(controller.state.status, PlaybackStatus.playing);
      expect(registrations, greaterThan(1));
      expect(server.streamProbes, hasLength(1));
      expect(engine.fetched, hasLength(1));
      expectCredentialsContained(controller);
    });
  });

  // ---------------------------------------------------------------------------
  // Security invariants
  // ---------------------------------------------------------------------------

  group('credentials stay at the runtime boundary', () {
    test('a token reaches the engine and the socket, and nothing else',
        () async {
      final FakeJellyfinServer server = await jellyfinServer();
      final LoopbackEngine engine = newEngine();
      final LinuxPlaybackController controller = controllerFor(
        engine,
        router(jellyfin: jellyfinSource(server)),
      );
      final List<PlaybackState> observed = <PlaybackState>[];
      final StreamSubscription<PlaybackState> sub =
          controller.stateStream.listen(observed.add);
      addTearDown(sub.cancel);

      await controller.playTrack(jellyfinTrack('101'));
      await pumpEventQueue();

      // The one place it is allowed: the URL handed to the engine.
      expect(engine.opened.single, contains(syntheticJellyfinToken));
      // Nowhere the app keeps, shows, or records anything.
      for (final PlaybackState state in observed) {
        expectFreeOfSecrets(state.errorMessage, what: 'streamed error message');
        expectFreeOfSecrets(state.currentTrack?.uri,
            what: 'streamed track uri');
      }
      expectCredentialsContained(controller);
    });

    test('an engine failure quoting the URL surfaces without it', () async {
      final FakeJellyfinServer server = await jellyfinServer();
      final LoopbackEngine engine = newEngine()..failLoadQuotingUrl = true;
      final LinuxPlaybackController controller = controllerFor(
        engine,
        router(jellyfin: jellyfinSource(server)),
      );

      await controller.playTrack(jellyfinTrack('101'));

      expect(controller.state.status, PlaybackStatus.error);
      // The engine really did see the token (it is in the error it raised), and
      // none of it reached the listener.
      expect(engine.lastLoadError, contains(syntheticJellyfinToken));
      expectCredentialsContained(controller);
    });

    test('the crash-safe session persists logical identity, never a URL',
        () async {
      final FakeJellyfinServer jellyfin = await jellyfinServer();
      final FakeSubsonicServer subsonic = await subsonicServer();
      final LinuxPlaybackController controller = controllerFor(
        newEngine(),
        router(
          jellyfin: jellyfinSource(jellyfin),
          subsonic: subsonicSource(subsonic),
        ),
      );
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore();
      final PlaybackSessionPersistence persistence = PlaybackSessionPersistence(
        store: store,
        controller: controller,
        playbackStates: controller.stateStream,
        positionSaveInterval: Duration.zero,
      );
      addTearDown(persistence.dispose);

      await controller.playTracks(<Track>[
        jellyfinTrack('101'),
        subsonicTrack('song-7'),
      ]);
      await waitFor(
        () => controller.state.status == PlaybackStatus.playing,
        describe: 'the first track to start',
      );
      PersistedPlaybackSession? persisted = await store.load();
      await waitFor(
        () {
          unawaited(store
              .load()
              .then((PersistedPlaybackSession? s) => persisted = s));
          return persisted != null;
        },
        describe: 'the session to be persisted',
      );

      final PersistedPlaybackSession saved = persisted!;
      expect(
        saved.tracks.map((Track t) => t.uri),
        <String>['jellyfin:101', 'subsonic:song-7'],
      );
      // The whole on-disk document, as the store would write it.
      final String document = saved.toJson().toString();
      expectFreeOfSecrets(document, what: 'persisted session');
      expect(document, isNot(contains('127.0.0.1')));
      expect(document, isNot(contains('http')));
    });
  });
}
