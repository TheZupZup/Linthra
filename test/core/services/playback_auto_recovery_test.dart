import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_failure.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/linux_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_recovery_policy.dart';
import 'package:linthra/core/services/provider_reachability.dart';
import 'package:linthra/core/services/reachability_aware_playable_uri_resolver.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/features/player/player_providers.dart';

/// An engine with controllable state and error streams that opens whatever it
/// is handed, except URLs a test marks as failing.
class _Player extends Fake implements AudioPlayer {
  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast();
  final StreamController<PlaybackEvent> _events =
      StreamController<PlaybackEvent>.broadcast();

  final List<String> setUrlCalls = <String>[];
  int playCalls = 0;

  /// Opening a URL this answers true for throws, like a connection that drops
  /// while the engine is opening it.
  bool Function(String url) fails = (String _) => false;

  void emitState(PlayerState state) => _states.add(state);

  void emitError(Object error) => _events.addError(error, StackTrace.empty);

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;
  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();
  @override
  Stream<Duration?> get durationStream => const Stream<Duration?>.empty();
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
    setUrlCalls.add(url);
    if (fails(url)) throw Exception('connection reset while opening');
    return const Duration(minutes: 3);
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> play() async => playCalls++;
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration? position, {int? index}) async {}
  @override
  Future<void> dispose() async {
    await _states.close();
    await _events.close();
  }
}

const PlaybackResolutionException _serverDown = PlaybackResolutionException(
  "Couldn't reach your music server.",
  kind: PlaybackResolutionErrorKind.serverUnreachable,
);

/// Resolves remote tracks to a freshly minted URL on every call (so a retry is
/// visibly a *new* URL) and local paths to files. A test marks which remote
/// tracks are down, how many times one fails before it answers, or a specific
/// failure to throw.
class _Resolver implements PlayableUriResolver {
  _Resolver({Set<String> down = const <String>{}}) : down = <String>{...down};

  final Set<String> down;
  final Map<String, int> failuresLeft = <String, int>{};
  final Map<String, PlaybackResolutionException> failWith =
      <String, PlaybackResolutionException>{};
  final List<String> calls = <String>[];
  int _minted = 0;

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    calls.add(track.uri);
    final PlaybackResolutionException? failure = failWith[track.uri];
    if (failure != null) throw failure;
    if (down.contains(track.uri)) throw _serverDown;
    final int left = failuresLeft[track.uri] ?? 0;
    if (left > 0) {
      failuresLeft[track.uri] = left - 1;
      throw _serverDown;
    }
    if (track.uri.startsWith('/')) {
      return ResolvedPlayable(Uri.file(track.uri), PlaybackSource.localFile);
    }
    _minted++;
    return ResolvedPlayable(
      Uri.parse('https://server.example/stream/${track.id}?n=$_minted'),
      PlaybackSource.streamingDirect,
    );
  }
}

Track _remote(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');

Track _local(String id) => Track(id: id, title: id, uri: '/music/$id.mp3');

/// The production bounds with the waits taken out, so a walk runs in a few
/// event-loop turns.
const PlaybackRecoveryPolicy _instant = PlaybackRecoveryPolicy(
  retryDelay: Duration.zero,
  advanceDelay: Duration.zero,
  maxAdvanceDelay: Duration.zero,
);

/// Lets every pending zero-length recovery timer and the awaits behind it run.
Future<void> _settle() async {
  for (int i = 0; i < 200; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Player player;
  late _Resolver resolver;

  JustAudioPlaybackController build({
    PlaybackRecoveryPolicy? policy = _instant,
  }) {
    final JustAudioPlaybackController controller = JustAudioPlaybackController(
      player: player,
      resolver: resolver,
      automaticRecovery: policy,
    )..streamRetryBackoff = Duration.zero;
    addTearDown(controller.dispose);
    return controller;
  }

  setUp(() {
    player = _Player();
    resolver = _Resolver();
  });

  group('recovery before skipping', () {
    test('a hiccup is retried once before anything is skipped', () async {
      resolver.failuresLeft['jellyfin:a'] = 1;
      final JustAudioPlaybackController controller = build();

      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);

      // Not an error, and not skipped: a retry is waiting to run.
      expect(controller.state.status, PlaybackStatus.reconnecting);
      expect(controller.state.currentTrack?.id, 'a');
      expect(controller.hasPendingAutomaticRecovery, isTrue);

      await _settle();

      expect(resolver.calls, <String>['jellyfin:a', 'jellyfin:a']);
      expect(controller.state.currentTrack?.id, 'a');
      expect(controller.state.source, PlaybackSource.streamingDirect);
      expect(player.playCalls, 1);
    });

    test('the retry reaches the server again, not its remembered outage',
        () async {
      // The real reachability memory in front of the provider: a failed probe
      // is remembered briefly so the next tracks fail fast. The retry waits
      // that memory out, so it is a genuine second attempt at the server.
      const Duration memory = Duration(milliseconds: 40);
      final _Resolver server = _Resolver()..failuresLeft['jellyfin:a'] = 1;
      resolver = server;
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(
        player: player,
        resolver: ReachabilityAwarePlayableUriResolver(
          inner: server,
          providerKey: () => 'jellyfin:account',
          reachability: CachingProviderReachability(ttl: memory),
        ),
        automaticRecovery: const PlaybackRecoveryPolicy(retryDelay: memory),
      );
      addTearDown(controller.dispose);

      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      await Future<void>.delayed(memory * 3);
      await _settle();

      expect(server.calls, <String>['jellyfin:a', 'jellyfin:a']);
      expect(controller.state.currentTrack?.id, 'a');
      expect(player.playCalls, 1);
    });

    test('a stream that fails to open is re-resolved fresh, not skipped',
        () async {
      // The first minted URL drops while the engine opens it; the retry mints
      // a new one, which opens fine.
      player.fails = (String url) => url.endsWith('n=1');
      final JustAudioPlaybackController controller = build();

      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      await _settle();

      expect(player.setUrlCalls, <String>[
        'https://server.example/stream/a?n=1',
        'https://server.example/stream/a?n=2',
      ]);
      expect(controller.state.currentTrack?.id, 'a');
      expect(resolver.calls, isNot(contains('jellyfin:b')));
    });

    test('a mid-stream drop keeps playing the same track from a fresh URL',
        () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      player.emitState(PlayerState(true, ProcessingState.ready));
      await _settle();

      player.emitError(Exception('connection reset by peer'));
      await _settle();

      expect(player.setUrlCalls.last, 'https://server.example/stream/a?n=2');
      expect(controller.state.currentTrack?.id, 'a');
      expect(resolver.calls, isNot(contains('jellyfin:b')));
    });
  });

  group('moving on', () {
    test('a track that stays down is left after one retry; the next plays',
        () async {
      resolver.down.add('jellyfin:a');
      final JustAudioPlaybackController controller = build();

      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      await _settle();

      expect(
          resolver.calls, <String>['jellyfin:a', 'jellyfin:a', 'jellyfin:b']);
      expect(controller.state.currentTrack?.id, 'b');
      expect(controller.state.status, isNot(PlaybackStatus.error));
      expect(player.setUrlCalls.single, contains('/stream/b'));
    });

    test('consecutive failures stop after a bounded number of tracks',
        () async {
      final List<Track> queue = <Track>[
        for (int i = 0; i < 10; i++) _remote('t$i'),
      ];
      resolver.down.addAll(queue.map((Track t) => t.uri));
      final JustAudioPlaybackController controller = build();

      await controller.playTracks(queue);
      await _settle();

      // One retry for the first failure, then one attempt per track, and a
      // stop at the cap: t6..t9 are never touched.
      expect(resolver.calls, <String>[
        'jellyfin:t0',
        'jellyfin:t0',
        'jellyfin:t1',
        'jellyfin:t2',
        'jellyfin:t3',
        'jellyfin:t4',
        'jellyfin:t5',
      ]);
      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.currentTrack?.id, 't5');
      expect(controller.hasPendingAutomaticRecovery, isFalse);
      // The listener can still skip on themselves.
      expect(controller.state.failure?.canSkip, isTrue);

      // Stable: nothing else happens on its own.
      await _settle();
      expect(resolver.calls, hasLength(7));
      expect(controller.state.status, PlaybackStatus.error);
    });

    test('an unavailable queue settles on a stable error at its end', () async {
      final List<Track> queue = <Track>[
        _remote('a'),
        _remote('b'),
        _remote('c')
      ];
      resolver.down.addAll(queue.map((Track t) => t.uri));
      final JustAudioPlaybackController controller = build();

      await controller.playTracks(queue);
      await _settle();

      expect(resolver.calls, <String>[
        'jellyfin:a',
        'jellyfin:a',
        'jellyfin:b',
        'jellyfin:c',
      ]);
      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.currentTrack?.id, 'c');
      expect(
          controller.state.failure?.kind, PlaybackFailureKind.temporarySource);
      expect(controller.state.failure?.canSkip, isFalse);
      expect(player.playCalls, 0);
    });

    test('repeat-all with the server down goes round once, not forever',
        () async {
      final List<Track> queue = <Track>[
        _remote('a'),
        _remote('b'),
        _remote('c')
      ];
      resolver.down.addAll(queue.map((Track t) => t.uri));
      final JustAudioPlaybackController controller = build();
      controller.setRepeatMode(RepeatMode.all);

      await controller.playTracks(queue);
      await _settle();
      await _settle();

      // Coming back round to 'a', which already failed, is where it stops.
      expect(resolver.calls, <String>[
        'jellyfin:a',
        'jellyfin:a',
        'jellyfin:b',
        'jellyfin:c',
      ]);
      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.hasPendingAutomaticRecovery, isFalse);
    });

    test('a local track further on still plays while the server is down',
        () async {
      resolver.down.addAll(<String>['jellyfin:r0', 'jellyfin:r1']);
      final JustAudioPlaybackController controller = build();

      await controller.playTracks(<Track>[
        _remote('r0'),
        _remote('r1'),
        _local('here'),
        _remote('r2'),
      ]);
      await _settle();

      expect(controller.state.currentTrack?.id, 'here');
      expect(controller.state.source, PlaybackSource.localFile);
      expect(player.setUrlCalls.single, Uri.file('/music/here.mp3').toString());
      expect(resolver.calls, isNot(contains('jellyfin:r2')));
    });

    test('a track that plays to its end gives the next failure a fresh start',
        () async {
      resolver.down.addAll(<String>['jellyfin:r0', 'jellyfin:r2']);
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[
        _remote('r0'),
        _local('here'),
        _remote('r2'),
      ]);
      await _settle();
      expect(controller.state.currentTrack?.id, 'here');

      // 'here' finishes; 'r2' is still down and gets its own retry again.
      player.emitState(PlayerState(true, ProcessingState.completed));
      await _settle();

      expect(
        resolver.calls,
        <String>[
          'jellyfin:r0',
          'jellyfin:r0',
          '/music/here.mp3',
          'jellyfin:r2',
          'jellyfin:r2',
        ],
      );
      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.currentTrack?.id, 'r2');
    });

    test('repeat-all keeps playing what can play while the rest stays down',
        () async {
      resolver.down.add('jellyfin:r0');
      final JustAudioPlaybackController controller = build();
      controller.setRepeatMode(RepeatMode.all);
      await controller.playTracks(<Track>[_remote('r0'), _local('here')]);
      await _settle();
      expect(controller.state.currentTrack?.id, 'here');

      // Three times round: each time the queue wraps, r0 gets its one retry
      // and is left again, and the local track plays. Playing it to the end
      // is what keeps this from counting as one endless failure streak.
      for (int round = 0; round < 3; round++) {
        player.emitState(PlayerState(true, ProcessingState.completed));
        await _settle();
        expect(controller.state.currentTrack?.id, 'here', reason: '$round');
        expect(controller.state.status, isNot(PlaybackStatus.error));
      }
      expect(
        resolver.calls.where((String uri) => uri == 'jellyfin:r0'),
        hasLength(8),
      );
    });

    test('pressing play after it settles starts a new, still bounded, attempt',
        () async {
      final List<Track> queue = <Track>[_remote('a'), _remote('b')];
      resolver.down.addAll(queue.map((Track t) => t.uri));
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(queue);
      await _settle();
      expect(controller.state.status, PlaybackStatus.error);
      final int before = resolver.calls.length;

      // The server came back while the listener wasn't looking.
      resolver.down.clear();
      await controller.play();
      await _settle();

      expect(resolver.calls.length, before + 1);
      expect(controller.state.currentTrack?.id, 'b');
      expect(controller.state.status, isNot(PlaybackStatus.error));
    });
  });

  group('never on its own when it must not', () {
    test('an engine that cannot play anything does not walk the queue',
        () async {
      resolver.failWith['jellyfin:a'] = const PlaybackResolutionException(
        'The audio engine could not start.',
        kind: PlaybackResolutionErrorKind.playbackEngineUnavailable,
      );
      final JustAudioPlaybackController controller = build();

      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      await _settle();

      expect(resolver.calls, <String>['jellyfin:a']);
      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.failure?.kind,
          PlaybackFailureKind.playbackEngineUnavailable);
    });

    test('a restored session never starts anything after a failure', () async {
      resolver.down.add('jellyfin:a');
      final JustAudioPlaybackController controller = build();

      await controller
          .restoreSession(tracks: <Track>[_remote('a'), _remote('b')]);
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.hasPendingAutomaticRecovery, isFalse);
      expect(resolver.calls, <String>['jellyfin:a']);
      expect(player.playCalls, 0);
    });

    test('pausing while a step waits shows the error and starts nothing',
        () async {
      resolver.down.add('jellyfin:a');
      final JustAudioPlaybackController controller = build(
        policy: const PlaybackRecoveryPolicy(retryDelay: Duration(minutes: 5)),
      );
      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      expect(controller.hasPendingAutomaticRecovery, isTrue);

      await controller.pause();
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.failure?.canRetry, isTrue);
      expect(controller.hasPendingAutomaticRecovery, isFalse);
      expect(resolver.calls, <String>['jellyfin:a']);
    });

    test('a skip while a step waits wins, and the step never runs', () async {
      resolver.down.add('jellyfin:a');
      final JustAudioPlaybackController controller = build(
        policy: const PlaybackRecoveryPolicy(retryDelay: Duration(minutes: 5)),
      );
      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);

      await controller.skipToNext();
      await _settle();

      expect(resolver.calls, <String>['jellyfin:a', 'jellyfin:b']);
      expect(controller.state.currentTrack?.id, 'b');
      expect(controller.hasPendingAutomaticRecovery, isFalse);
    });

    test('disposing while a step waits leaves nothing running', () async {
      resolver.down.add('jellyfin:a');
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(
        player: player,
        resolver: resolver,
        automaticRecovery: _instant,
      );
      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      expect(controller.hasPendingAutomaticRecovery, isTrue);

      await controller.dispose();
      await _settle();

      expect(resolver.calls, <String>['jellyfin:a']);
      expect(player.setUrlCalls, isEmpty);
    });

    test('without a policy a failure waits on the panel, as before', () async {
      resolver.down.add('jellyfin:a');
      final JustAudioPlaybackController controller = build(policy: null);

      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(resolver.calls, <String>['jellyfin:a']);
    });
  });

  group('Linux', () {
    test('the Linux controller walks the queue the same way', () async {
      resolver.down.add('jellyfin:a');
      final LinuxPlaybackController controller = LinuxPlaybackController(
        player: player,
        resolver: resolver,
        automaticRecovery: _instant,
      );
      addTearDown(controller.dispose);

      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      await _settle();

      expect(
          resolver.calls, <String>['jellyfin:a', 'jellyfin:a', 'jellyfin:b']);
      expect(controller.state.currentTrack?.id, 'b');
    });

    test('the app turns automatic recovery on for the Linux engine', () async {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          hostPlatformProvider.overrideWithValue(HostPlatform.linux),
          linuxAudioPlayerProvider.overrideWithValue(player),
          playableUriResolverProvider.overrideWithValue(resolver),
          playbackRecoveryPolicyProvider.overrideWithValue(
            const PlaybackRecoveryPolicy(retryDelay: Duration(minutes: 5)),
          ),
        ],
      );
      addTearDown(container.dispose);
      resolver.down.add('jellyfin:a');

      await container
          .read(localPlaybackControllerProvider)
          .playTracks(<Track>[_remote('a'), _remote('b')]);

      final JustAudioPlaybackController controller = container
          .read(localPlaybackControllerProvider) as JustAudioPlaybackController;
      expect(controller.hasPendingAutomaticRecovery, isTrue);
      expect(controller.state.status, PlaybackStatus.reconnecting);
      await controller.stop();
    });

    test('the production policy is on by default', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(playbackRecoveryPolicyProvider), isNotNull);
    });
  });
}
