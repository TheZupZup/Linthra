import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_failure.dart';
import 'package:linthra/core/models/playback_history.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/linux_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_history_recorder.dart';
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
  final List<Duration?> seekCalls = <Duration?>[];
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
  Future<void> seek(Duration? position, {int? index}) async =>
      seekCalls.add(position);
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

  /// Resolving a uri listed here waits for its completer, so a test can act
  /// while that load is still in flight. [holdSkips] lets that many resolves
  /// of the uri through first.
  final Map<String, Completer<void>> holds = <String, Completer<void>>{};
  final Map<String, int> holdSkips = <String, int>{};
  final List<String> calls = <String>[];
  int _minted = 0;

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    calls.add(track.uri);
    final int skips = holdSkips[track.uri] ?? 0;
    if (skips > 0) {
      holdSkips[track.uri] = skips - 1;
    } else {
      final Completer<void>? hold = holds.remove(track.uri);
      if (hold != null) await hold.future;
    }
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

      // Not an error, and not skipped: a retry is waiting to run. The track
      // never made a sound, so it waits as loading rather than reconnecting.
      expect(controller.state.status, PlaybackStatus.loading);
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

    test('a track that was playing waits as reconnecting, at its position',
        () async {
      final JustAudioPlaybackController controller = build(
        policy: const PlaybackRecoveryPolicy(retryDelay: Duration(minutes: 5)),
      );
      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      player.emitState(PlayerState(true, ProcessingState.ready));
      controller.setPositionForTesting(const Duration(seconds: 42));
      await _settle();

      // The server goes away mid-song; the quick retry can't reach it either.
      resolver.down.add('jellyfin:a');
      player.emitError(Exception('connection reset by peer'));
      await _settle();

      expect(controller.hasPendingAutomaticRecovery, isTrue);
      expect(controller.state.status, PlaybackStatus.reconnecting);
      expect(controller.state.position, const Duration(seconds: 42));
    });

    test('a track that never made a sound is not counted as played', () async {
      resolver.down.add('jellyfin:a');
      final JustAudioPlaybackController controller = build();
      final List<String> recorded = <String>[];
      final PlaybackHistoryRecorder history = PlaybackHistoryRecorder(
        states: controller.stateStream,
        onPlayed: (Track track, PlaybackHistoryOutcome outcome, DateTime _) =>
            recorded.add('${track.id}:${outcome.name}'),
      )..start();
      addTearDown(history.dispose);

      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      await _settle();

      expect(controller.state.currentTrack?.id, 'b');
      // Leaving 'a' behind must not record it as a skipped play.
      expect(recorded, isEmpty);
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

    test('a song queued twice is passed over, not taken for a full loop',
        () async {
      resolver.down.add('jellyfin:a');
      final JustAudioPlaybackController controller = build();

      await controller
          .playTracks(<Track>[_remote('a'), _remote('a'), _remote('b')]);
      await _settle();

      expect(
          resolver.calls, <String>['jellyfin:a', 'jellyfin:a', 'jellyfin:b']);
      expect(controller.state.currentTrack?.id, 'b');
      expect(controller.state.status, isNot(PlaybackStatus.error));
    });

    test('a song that already failed further on is passed over too', () async {
      resolver.down.addAll(<String>['jellyfin:a', 'jellyfin:b']);
      final JustAudioPlaybackController controller = build();

      await controller.playTracks(
          <Track>[_remote('a'), _remote('b'), _remote('a'), _remote('c')]);
      await _settle();

      expect(resolver.calls, <String>[
        'jellyfin:a',
        'jellyfin:a',
        'jellyfin:b',
        'jellyfin:c',
      ]);
      expect(controller.state.currentTrack?.id, 'c');
    });

    test('repeat-one stays on its track: one retry, then the error', () async {
      resolver.down.add('jellyfin:a');
      final JustAudioPlaybackController controller = build();
      controller.setRepeatMode(RepeatMode.one);

      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      await _settle();

      expect(resolver.calls, <String>['jellyfin:a', 'jellyfin:a']);
      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.currentTrack?.id, 'a');
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

    test('pressing play gives the next failure a fresh start', () async {
      resolver.down.add('jellyfin:a');
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      await _settle();
      expect(controller.state.currentTrack?.id, 'b');
      player.emitState(PlayerState(true, ProcessingState.ready));
      await _settle();

      // The listener pauses and plays 'b', then its server drops mid-song.
      await controller.pause();
      await controller.play();
      resolver.down.add('jellyfin:b');
      player.emitError(Exception('connection reset by peer'));
      await _settle();

      // The quick retry and then the one delayed retry a fresh run allows,
      // rather than giving up because 'a' failed before the listener acted.
      expect(
        resolver.calls.where((String uri) => uri == 'jellyfin:b'),
        hasLength(3),
      );
      expect(controller.state.status, PlaybackStatus.error);
    });

    test('seeking gives the next failure a fresh start too', () async {
      resolver.down.add('jellyfin:a');
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      await _settle();
      expect(controller.state.currentTrack?.id, 'b');
      player.emitState(PlayerState(true, ProcessingState.ready));
      await _settle();

      // The listener seeks within 'b', then its server drops mid-song.
      await controller.seek(const Duration(seconds: 10));
      resolver.down.add('jellyfin:b');
      player.emitError(Exception('connection reset by peer'));
      await _settle();

      expect(
        resolver.calls.where((String uri) => uri == 'jellyfin:b'),
        hasLength(3),
      );
      expect(controller.state.status, PlaybackStatus.error);
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

    test('unplugging headphones while a step waits starts nothing', () async {
      resolver.down.add('jellyfin:a');
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      expect(controller.hasPendingAutomaticRecovery, isTrue);

      controller.onBecomingNoisyForTesting();
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.hasPendingAutomaticRecovery, isFalse);
      expect(resolver.calls, <String>['jellyfin:a']);
      expect(player.playCalls, 0);
    });

    final Map<String, Future<void> Function(JustAudioPlaybackController)>
        standDowns =
        <String, Future<void> Function(JustAudioPlaybackController)>{
      'a pause': (JustAudioPlaybackController c) => c.pause(),
      'headphones unplugged': (JustAudioPlaybackController c) async =>
          c.onBecomingNoisyForTesting(),
      'another app taking audio': (JustAudioPlaybackController c) async =>
          c.onAudioInterruption(
            AudioInterruptionEvent(true, AudioInterruptionType.unknown),
          ),
      'a cast taking over': (JustAudioPlaybackController c) => c.suspend(),
    };
    for (final MapEntry<String,
            Future<void> Function(JustAudioPlaybackController)> standDown
        in standDowns.entries) {
      test('${standDown.key} while a move is still loading starts nothing',
          () async {
        resolver.down.add('jellyfin:a');
        final Completer<void> loadingB = Completer<void>();
        resolver.holds['jellyfin:b'] = loadingB;
        final JustAudioPlaybackController controller = build();

        await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
        await _settle();
        // The retry failed and the move to 'b' is resolving right now.
        expect(
            resolver.calls, <String>['jellyfin:a', 'jellyfin:a', 'jellyfin:b']);

        await standDown.value(controller);
        loadingB.complete();
        await _settle();

        expect(controller.state.currentTrack?.id, 'b');
        expect(player.playCalls, 0);
      });
    }

    test('seeking while a move is still loading starts it from there',
        () async {
      resolver.down.add('jellyfin:a');
      final Completer<void> loadingB = Completer<void>();
      resolver.holds['jellyfin:b'] = loadingB;
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      await _settle();

      final Future<void> seeking = controller.seek(const Duration(seconds: 30));
      loadingB.complete();
      await seeking;
      await _settle();

      // Not left on "Loading…": the seek took over and loaded 'b' there.
      expect(controller.state.currentTrack?.id, 'b');
      expect(player.setUrlCalls, hasLength(1));
      expect(player.seekCalls, contains(const Duration(seconds: 30)));
      expect(player.playCalls, 1);
    });

    test('seeking while a retry waits tries again from there', () async {
      resolver.failuresLeft['jellyfin:a'] = 1;
      final JustAudioPlaybackController controller = build(
        policy: const PlaybackRecoveryPolicy(retryDelay: Duration(minutes: 5)),
      );
      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      expect(controller.hasPendingAutomaticRecovery, isTrue);

      await controller.seek(const Duration(seconds: 20));
      await _settle();

      expect(resolver.calls, <String>['jellyfin:a', 'jellyfin:a']);
      expect(player.seekCalls, contains(const Duration(seconds: 20)));
      expect(player.playCalls, 1);
      expect(controller.hasPendingAutomaticRecovery, isFalse);
    });

    test('a pause that settles a waiting step keeps the error and its reload',
        () async {
      final JustAudioPlaybackController controller = build(
        policy: const PlaybackRecoveryPolicy(retryDelay: Duration(minutes: 5)),
      );
      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      player.emitState(PlayerState(true, ProcessingState.ready));
      await _settle();
      resolver.down.add('jellyfin:a');
      player.emitError(Exception('connection reset by peer'));
      await _settle();
      expect(controller.hasPendingAutomaticRecovery, isTrue);

      await controller.pause();
      // The engine reports that pause on the source it still holds.
      player.emitState(PlayerState(false, ProcessingState.ready));
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.failure, isNotNull);

      // So Play still reloads the track instead of poking the dead source.
      final int before = resolver.calls.length;
      resolver.down.clear();
      await controller.play();
      await _settle();
      expect(resolver.calls, hasLength(before + 1));
    });

    test('the failed source going quiet while a step waits leaves it waiting',
        () async {
      final JustAudioPlaybackController controller = build(
        policy: const PlaybackRecoveryPolicy(retryDelay: Duration(minutes: 5)),
      );
      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      player.emitState(PlayerState(true, ProcessingState.ready));
      await _settle();
      resolver.down.add('jellyfin:a');
      player.emitError(Exception('connection reset by peer'));
      await _settle();
      expect(controller.hasPendingAutomaticRecovery, isTrue);

      // What the dead source may still report: a pause, then its end.
      player.emitState(PlayerState(false, ProcessingState.ready));
      player.emitState(PlayerState(true, ProcessingState.completed));
      await _settle();

      expect(controller.state.status, PlaybackStatus.reconnecting);
      expect(controller.state.currentTrack?.id, 'a');
      expect(controller.hasPendingAutomaticRecovery, isTrue);
      expect(resolver.calls, isNot(contains('jellyfin:b')));
    });

    final Map<String, void Function(JustAudioPlaybackController)>
        secondFailures = <String, void Function(JustAudioPlaybackController)>{
      'the buffering watchdog': (JustAudioPlaybackController c) =>
          c.onBufferingTimeoutForTesting(),
      'a late engine error': (JustAudioPlaybackController _) =>
          player.emitError(Exception('connection reset by peer')),
    };
    for (final MapEntry<String,
            void Function(JustAudioPlaybackController)> second
        in secondFailures.entries) {
      test('${second.key} while a retry loads does not start another step',
          () async {
        final JustAudioPlaybackController controller = build();
        await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
        player.emitState(PlayerState(true, ProcessingState.ready));
        await _settle();
        // The quick retry can't reach the server either. By the time the
        // delayed one runs the server is back, but slow to answer.
        final Completer<void> loadingA = Completer<void>();
        resolver
          ..failuresLeft['jellyfin:a'] = 1
          ..holds['jellyfin:a'] = loadingA
          ..holdSkips['jellyfin:a'] = 1;
        player.emitError(Exception('connection reset by peer'));
        await _settle();
        expect(
            resolver.calls, <String>['jellyfin:a', 'jellyfin:a', 'jellyfin:a']);

        second.value(controller);
        await _settle();
        loadingA.complete();
        await _settle();

        // The retry that was already loading gets to finish; nothing moved on.
        expect(controller.state.currentTrack?.id, 'a');
        expect(resolver.calls, isNot(contains('jellyfin:b')));
        expect(player.setUrlCalls.last, contains('/stream/a'));
        expect(player.playCalls, 2);
      });
    }

    test('a retry that loads but never plays is still bounded', () async {
      final JustAudioPlaybackController controller = build()
        ..midStreamBufferingTimeout = Duration.zero;
      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      player.emitState(PlayerState(true, ProcessingState.ready));
      await _settle();
      // The delayed retry is slow to resolve, outlasting the watchdog, then
      // loads, but the engine never gets going again.
      final Completer<void> loadingA = Completer<void>();
      resolver
        ..failuresLeft['jellyfin:a'] = 1
        ..holds['jellyfin:a'] = loadingA
        ..holdSkips['jellyfin:a'] = 1;
      player.emitError(Exception('connection reset by peer'));
      await _settle();
      loadingA.complete();
      await _settle();

      // Not left on "Reconnecting…" for good: the watchdog runs out again
      // once the retry is done, and recovery moves on.
      expect(controller.state.currentTrack?.id, 'b');
      expect(controller.state.status, isNot(PlaybackStatus.reconnecting));
    });

    test('pressing play while a move is still loading loads where it moved to',
        () async {
      resolver.down.add('jellyfin:a');
      final Completer<void> loadingB = Completer<void>();
      resolver.holds['jellyfin:b'] = loadingB;
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      await _settle();
      expect(
          resolver.calls, <String>['jellyfin:a', 'jellyfin:a', 'jellyfin:b']);

      await controller.play();
      loadingB.complete();
      await _settle();

      // Play loaded 'b' afresh instead of poking the engine, which still held
      // the source that failed, and the move it replaced never started.
      expect(controller.state.currentTrack?.id, 'b');
      expect(resolver.calls,
          <String>['jellyfin:a', 'jellyfin:a', 'jellyfin:b', 'jellyfin:b']);
      expect(player.setUrlCalls.single, contains('/stream/b'));
      expect(player.playCalls, 1);
    });

    test('the old source finishing while a move loads changes nothing',
        () async {
      resolver.down.add('jellyfin:a');
      final Completer<void> loadingB = Completer<void>();
      resolver.holds['jellyfin:b'] = loadingB;
      final JustAudioPlaybackController controller = build();
      await controller
          .playTracks(<Track>[_remote('a'), _remote('b'), _remote('c')]);
      await _settle();

      player.emitState(PlayerState(true, ProcessingState.completed));
      await _settle();
      loadingB.complete();
      await _settle();

      // Still the move to 'b', not a finished track and a skip to 'c'.
      expect(controller.state.currentTrack?.id, 'b');
      expect(resolver.calls, isNot(contains('jellyfin:c')));
      expect(player.playCalls, 1);
    });

    test('play after a pause while a move still loads loads it afresh',
        () async {
      resolver.down.add('jellyfin:a');
      final Completer<void> loadingB = Completer<void>();
      resolver.holds['jellyfin:b'] = loadingB;
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      await _settle();

      await controller.pause();
      await controller.play();
      loadingB.complete();
      await _settle();

      // Play re-resolved 'b' instead of starting the source the engine held,
      // and the paused move it replaced never loaded.
      expect(resolver.calls,
          <String>['jellyfin:a', 'jellyfin:a', 'jellyfin:b', 'jellyfin:b']);
      expect(player.setUrlCalls.single, contains('/stream/b'));
      expect(player.playCalls, 1);
    });

    test('a load after a cast hands back supersedes a move still loading',
        () async {
      resolver.down.add('jellyfin:a');
      final Completer<void> loadingB = Completer<void>();
      resolver.holds['jellyfin:b'] = loadingB;
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      await _settle();
      // A cast takes over while the move to 'b' resolves, then hands back.
      await controller.suspend();
      await controller.resume(play: true);
      player.emitState(PlayerState(true, ProcessingState.ready));
      await _settle();

      // 'b' drops mid-song while the old move is still stuck resolving: the
      // drop is recovered like any other, not taken for that move's.
      final int before = resolver.calls.length;
      player.emitError(Exception('connection reset by peer'));
      await _settle();
      expect(resolver.calls, hasLength(before + 1));
      loadingB.complete();
      await _settle();
    });

    test('a completion from the source left behind an error changes nothing',
        () async {
      resolver.down.add('jellyfin:b');
      final JustAudioPlaybackController controller = build(policy: null);
      await controller.playTracks(<Track>[_remote('b'), _remote('c')]);
      expect(controller.state.status, PlaybackStatus.error);

      player.emitState(PlayerState(false, ProcessingState.completed));
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.currentTrack?.id, 'b');
      expect(resolver.calls, <String>['jellyfin:b']);
    });

    test('an error during a call is not resumed when the call ends', () async {
      final JustAudioPlaybackController controller = build()
        ..focusPauseDebounce = Duration.zero;
      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      player.emitState(PlayerState(true, ProcessingState.ready));
      await _settle();

      // A call comes in, and while it holds focus the server goes away.
      controller.onAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await _settle();
      resolver.down.addAll(<String>['jellyfin:a', 'jellyfin:b']);
      player.emitError(Exception('connection reset by peer'));
      await _settle();
      expect(controller.state.status, PlaybackStatus.error);
      final int playsBefore = player.playCalls;

      controller.onAudioInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await _settle();

      expect(player.playCalls, playsBefore);
    });

    test('a call that ends while a step waits leaves the start to the step',
        () async {
      final JustAudioPlaybackController controller = build(
        policy: const PlaybackRecoveryPolicy(retryDelay: Duration(minutes: 5)),
      )..focusPauseDebounce = Duration.zero;
      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      player.emitState(PlayerState(true, ProcessingState.ready));
      await _settle();
      resolver.down.add('jellyfin:a');
      player.emitError(Exception('connection reset by peer'));
      await _settle();
      expect(controller.hasPendingAutomaticRecovery, isTrue);
      final int playsBefore = player.playCalls;

      // A short call comes and goes while the retry waits.
      controller.onAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await _settle();
      controller.onAudioInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await _settle();

      // Nothing played the dead source the engine still holds, and the retry
      // is still there to start the track.
      expect(player.playCalls, playsBefore);
      expect(controller.hasPendingAutomaticRecovery, isTrue);
    });

    test('a call that ends while a retry loads lets the retry start it',
        () async {
      final JustAudioPlaybackController controller = build()
        ..focusPauseDebounce = Duration.zero;
      await controller.playTracks(<Track>[_remote('a'), _remote('b')]);
      player.emitState(PlayerState(true, ProcessingState.ready));
      await _settle();
      // A call comes in. While it holds focus the stream drops, the quick
      // retry fails, and the delayed one is slow to answer.
      controller.onAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await _settle();
      final Completer<void> loadingA = Completer<void>();
      resolver
        ..failuresLeft['jellyfin:a'] = 1
        ..holds['jellyfin:a'] = loadingA
        ..holdSkips['jellyfin:a'] = 1;
      player.emitError(Exception('connection reset by peer'));
      await _settle();
      final int playsBefore = player.playCalls;

      controller.onAudioInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await _settle();
      // The call is over, but the engine still holds the source that dropped.
      expect(player.playCalls, playsBefore);

      loadingA.complete();
      await _settle();
      expect(player.playCalls, playsBefore + 1);
      expect(player.setUrlCalls.last, 'https://server.example/stream/a?n=2');
    });

    test('a move told to stand down that then fails settles on the error',
        () async {
      resolver.down.addAll(<String>['jellyfin:a', 'jellyfin:b']);
      final Completer<void> loadingB = Completer<void>();
      resolver.holds['jellyfin:b'] = loadingB;
      final JustAudioPlaybackController controller = build();

      await controller
          .playTracks(<Track>[_remote('a'), _remote('b'), _remote('c')]);
      await _settle();
      await controller.pause();
      loadingB.complete();
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.currentTrack?.id, 'b');
      expect(controller.hasPendingAutomaticRecovery, isFalse);
      expect(resolver.calls, isNot(contains('jellyfin:c')));
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
      expect(controller.state.status, PlaybackStatus.loading);
      await controller.stop();
    });

    test('the production policy is on by default', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(playbackRecoveryPolicyProvider), isNotNull);
    });
  });
}
