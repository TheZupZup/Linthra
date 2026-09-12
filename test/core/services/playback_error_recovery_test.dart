import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_failure.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_candidate_source.dart';
import 'package:linthra/core/services/stream_interruption.dart';

/// A secret the fakes weave into every URL and raw error they produce, so a test
/// can assert that nothing the listener is shown was built from one.
const String _secret = 'token=SUPERSECRET';

/// A fake engine that records what it opened and can be told to fail opening
/// specific URLs, either as a generic start failure or as a decode failure,
/// whose raw error deliberately carries the tokenized URL a real engine echoes.
class _FakePlayer extends Fake implements AudioPlayer {
  _FakePlayer({
    Set<String> failUrls = const <String>{},
    Set<String> undecodableUrls = const <String>{},
  })  : failUrls = <String>{...failUrls},
        undecodableUrls = <String>{...undecodableUrls};

  final Set<String> failUrls;
  final Set<String> undecodableUrls;
  final List<String> setUrlCalls = <String>[];

  @override
  Stream<PlayerState> get playerStateStream =>
      const Stream<PlayerState>.empty();
  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();
  @override
  Stream<Duration?> get durationStream => const Stream<Duration?>.empty();
  @override
  Stream<PlaybackEvent> get playbackEventStream =>
      const Stream<PlaybackEvent>.empty();

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    setUrlCalls.add(url);
    if (undecodableUrls.contains(url)) {
      // What a real backend says when it cannot decode a container/codec,
      // including the request URL, secret and all.
      throw Exception('Unable to instantiate decoder for $url');
    }
    if (failUrls.contains(url)) {
      throw Exception('source error opening $url');
    }
    return const Duration(minutes: 3);
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration? position, {int? index}) async {}
  @override
  Future<void> dispose() async {}
}

/// A resolver driven by the track's opaque uri, whose behaviour a test can
/// change between attempts, which is how a retry that *works* is staged.
class _FakeResolver implements PlayableUriResolver {
  _FakeResolver({
    Map<String, ResolvedPlayable> resolved = const <String, ResolvedPlayable>{},
    Map<String, PlaybackResolutionException> failures =
        const <String, PlaybackResolutionException>{},
  })  : resolved = <String, ResolvedPlayable>{...resolved},
        failures = <String, PlaybackResolutionException>{...failures};

  final Map<String, ResolvedPlayable> resolved;
  final Map<String, PlaybackResolutionException> failures;
  final List<String> calls = <String>[];

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    calls.add(track.uri);
    final PlaybackResolutionException? failure = failures[track.uri];
    if (failure != null) throw failure;
    final ResolvedPlayable? playable = resolved[track.uri];
    if (playable == null) {
      throw const PlaybackResolutionException(
        "Couldn't reach this source.",
        kind: PlaybackResolutionErrorKind.serverUnreachable,
      );
    }
    return playable;
  }
}

Track _track(String id, String uri) => Track(
      id: id,
      title: 'Hello',
      uri: uri,
      artistName: 'Adele',
      albumName: '25',
      duration: const Duration(minutes: 3),
    );

ResolvedPlayable _stream(String url) => ResolvedPlayable(
    Uri.parse('$url?$_secret'), PlaybackSource.streamingDirect);

ResolvedPlayable _localFile(String path) =>
    ResolvedPlayable(Uri.file(path), PlaybackSource.localFile);

const PlaybackResolutionException _serverDown = PlaybackResolutionException(
  "Couldn't reach your music server. Check your connection and try again.",
  kind: PlaybackResolutionErrorKind.serverUnreachable,
);

const PlaybackResolutionException _fileMissing = PlaybackResolutionException(
  "This track's file isn't there anymore. It may have been moved or deleted.",
  kind: PlaybackResolutionErrorKind.localFileMissing,
);

const PlaybackResolutionException _sessionExpired = PlaybackResolutionException(
  'Your session expired. Sign in again to keep streaming.',
  kind: PlaybackResolutionErrorKind.sessionExpired,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The same song on two providers, plus an unrelated third track to queue
  // behind it so Skip has somewhere to go.
  final Track jelly = _track('j', 'jellyfin:j');
  final Track sub = _track('s', 'subsonic:s');
  final Track next = _track('n', 'jellyfin:n');
  final Track localOnly = _track('l', '/music/one.mp3');

  JustAudioPlaybackController build({
    required _FakePlayer player,
    required _FakeResolver resolver,
    Map<String, List<Track>> candidates = const <String, List<Track>>{},
  }) {
    final JustAudioPlaybackController controller = JustAudioPlaybackController(
      player: player,
      resolver: resolver,
      candidates: MapPlaybackCandidateSource(() => candidates),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  group('the failure a listener is shown', () {
    test('a provider that is down is temporary, retryable and skippable',
        () async {
      final _FakeResolver resolver = _FakeResolver(
        failures: <String, PlaybackResolutionException>{
          'jellyfin:j': _serverDown,
        },
        resolved: <String, ResolvedPlayable>{
          'jellyfin:n': _stream('https://jelly/stream/n'),
        },
      );
      final JustAudioPlaybackController controller = build(
        player: _FakePlayer(),
        resolver: resolver,
      );

      await controller.playTracks(<Track>[jelly, next]);

      final PlaybackFailure? failure = controller.state.failure;
      expect(controller.state.status, PlaybackStatus.error);
      expect(failure?.kind, PlaybackFailureKind.temporarySource);
      expect(failure?.message, _serverDown.message);
      expect(failure?.canRetry, isTrue);
      // A single-source song has nowhere else to play from.
      expect(failure?.canTryAnotherSource, isFalse);
      expect(failure?.canSkip, isTrue);
      expect(
        failure?.actions,
        <PlaybackRecoveryAction>[
          PlaybackRecoveryAction.retry,
          PlaybackRecoveryAction.skip,
        ],
      );
    });

    test('a local file that is gone reads as a file problem, not a server one',
        () async {
      final _FakeResolver resolver = _FakeResolver(
        failures: <String, PlaybackResolutionException>{
          '/music/one.mp3': _fileMissing,
        },
      );
      final JustAudioPlaybackController controller = build(
        player: _FakePlayer(),
        resolver: resolver,
      );

      await controller.playTracks(<Track>[localOnly]);

      final PlaybackFailure? failure = controller.state.failure;
      expect(failure?.kind, PlaybackFailureKind.localFileUnavailable);
      // A reconnected drive (or a rescan) makes the same copy playable again,
      // so Retry stays on offer; there is no next track, so Skip does not.
      expect(failure?.canRetry, isTrue);
      expect(failure?.canSkip, isFalse);
      expect(failure?.canTryAnotherSource, isFalse);
    });

    test('a backend that cannot decode the media offers no retry', () async {
      final _FakePlayer player = _FakePlayer(
        undecodableUrls: <String>{'https://jelly/stream/j?$_secret'},
      );
      final _FakeResolver resolver = _FakeResolver(
        resolved: <String, ResolvedPlayable>{
          'jellyfin:j': _stream('https://jelly/stream/j'),
        },
      );
      final JustAudioPlaybackController controller = build(
        player: player,
        resolver: resolver,
      );

      await controller.playTracks(<Track>[jelly]);

      final PlaybackFailure? failure = controller.state.failure;
      expect(controller.state.status, PlaybackStatus.error);
      expect(failure?.kind, PlaybackFailureKind.unplayableMedia);
      // The same bytes decode the same way next time, so Retry is not offered.
      expect(failure?.canRetry, isFalse);
      expect(failure?.actions, isEmpty);
    });

    test('an expired session asks for a sign-in rather than another attempt',
        () async {
      final _FakeResolver resolver = _FakeResolver(
        failures: <String, PlaybackResolutionException>{
          'jellyfin:j': _sessionExpired,
        },
      );
      final JustAudioPlaybackController controller = build(
        player: _FakePlayer(),
        resolver: resolver,
      );

      await controller.playTracks(<Track>[jelly]);

      expect(
        controller.state.failure?.kind,
        PlaybackFailureKind.sourceSignInRequired,
      );
      expect(controller.state.failure?.canRetry, isFalse);
    });

    test('a mid-stream rejection asks for a sign-in, not another attempt',
        () async {
      final _FakeResolver resolver = _FakeResolver(
        resolved: <String, ResolvedPlayable>{
          'jellyfin:j': _stream('https://jelly/stream/j'),
          'jellyfin:n': _stream('https://jelly/stream/n'),
        },
      );
      final JustAudioPlaybackController controller = build(
        player: _FakePlayer(),
        resolver: resolver,
      );

      await controller.playTracks(<Track>[jelly, next]);
      expect(controller.state.failure, isNull);

      // The server rejects the session part-way through the stream.
      await controller.handleStreamFailureForTestingAsync(
        const StreamInterruption(
          StreamInterruptionKind.sessionExpired,
          'Your session expired. Sign in again to keep streaming.',
          retryable: false,
        ),
      );

      final PlaybackFailure? failure = controller.state.failure;
      expect(failure?.kind, PlaybackFailureKind.sourceSignInRequired);
      expect(failure?.canRetry, isFalse);
      expect(failure?.canSkip, isTrue);
      // The classification is what reaches the listener, not the engine's text.
      expect(failure?.message,
          'Your session expired. Sign in again to keep streaming.');
    });

    test('no message carries a URL, a token or a file path', () async {
      final _FakePlayer player = _FakePlayer(
        undecodableUrls: <String>{'https://jelly/stream/j?$_secret'},
      );
      final _FakeResolver resolver = _FakeResolver(
        resolved: <String, ResolvedPlayable>{
          'jellyfin:j': _stream('https://jelly/stream/j'),
        },
      );
      final JustAudioPlaybackController controller = build(
        player: player,
        resolver: resolver,
      );

      await controller.playTracks(<Track>[jelly]);

      final String message = controller.state.failure!.message;
      expect(message, isNot(contains('SUPERSECRET')));
      expect(message, isNot(contains('token')));
      expect(message, isNot(contains('http')));
      expect(message, isNot(contains('jelly')));
      expect(message, isNot(contains('/')));
      expect(message, isNot(contains('Exception')));
      // The classification is logged/diagnosed, never the engine's own text.
      expect(controller.state.failure.toString(), isNot(contains('http')));
    });
  });

  group('retry', () {
    test('retries the same logical track and plays it when the source is back',
        () async {
      final _FakeResolver resolver = _FakeResolver(
        failures: <String, PlaybackResolutionException>{
          'jellyfin:j': _serverDown,
        },
      );
      final JustAudioPlaybackController controller = build(
        player: _FakePlayer(),
        resolver: resolver,
      );

      await controller.playTracks(<Track>[jelly, next]);
      expect(controller.state.status, PlaybackStatus.error);

      // The server comes back.
      resolver.failures.remove('jellyfin:j');
      resolver.resolved['jellyfin:j'] = _stream('https://jelly/stream/j');
      await controller.retryCurrentTrack();

      expect(controller.state.failure, isNull);
      expect(controller.state.currentTrack?.uri, 'jellyfin:j');
      expect(controller.state.source, PlaybackSource.streamingDirect);
      // Same queue entry, same up-next: a retry is not a re-queue.
      expect(
        controller.state.upNext.map((Track t) => t.uri),
        <String>['jellyfin:n'],
      );
    });

    test('is bounded: repeated failures stop offering it instead of looping',
        () async {
      final _FakeResolver resolver = _FakeResolver(
        failures: <String, PlaybackResolutionException>{
          'jellyfin:j': _serverDown,
        },
      );
      final JustAudioPlaybackController controller = build(
        player: _FakePlayer(),
        resolver: resolver,
      );

      await controller.playTracks(<Track>[jelly, next]);
      final int callsAfterFirstPlay = resolver.calls.length;

      // Spend the whole budget, then keep asking.
      for (int i = 0;
          i < JustAudioPlaybackController.maxRecoveryAttemptsPerTrack;
          i++) {
        expect(controller.state.failure?.canRetry, isTrue,
            reason: 'attempt ${i + 1} should still be offered');
        await controller.retryCurrentTrack();
      }

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.failure?.canRetry, isFalse);

      final int callsAfterBudget = resolver.calls.length;
      await controller.retryCurrentTrack();
      await controller.retryCurrentTrack();

      // A spent budget is a no-op, so the source is not hit again: the failure
      // cannot become a retry loop, however many times the button is tapped.
      expect(resolver.calls.length, callsAfterBudget);
      expect(
        callsAfterBudget - callsAfterFirstPlay,
        JustAudioPlaybackController.maxRecoveryAttemptsPerTrack,
      );
      // Moving on is still offered, so the listener is never stuck.
      expect(controller.state.failure?.canSkip, isTrue);
    });

    test('a track that plays again gets its full budget back', () async {
      final _FakeResolver resolver = _FakeResolver(
        failures: <String, PlaybackResolutionException>{
          'jellyfin:j': _serverDown,
        },
      );
      final JustAudioPlaybackController controller = build(
        player: _FakePlayer(),
        resolver: resolver,
      );

      await controller.playTracks(<Track>[jelly, next]);
      await controller.retryCurrentTrack();
      await controller.retryCurrentTrack();

      // It finally works, and then fails again later.
      resolver.failures.remove('jellyfin:j');
      resolver.resolved['jellyfin:j'] = _stream('https://jelly/stream/j');
      await controller.retryCurrentTrack();
      expect(controller.state.failure, isNull);

      resolver.failures['jellyfin:j'] = _serverDown;
      resolver.resolved.remove('jellyfin:j');
      await controller.playTracks(<Track>[jelly, next]);

      expect(controller.state.failure?.canRetry, isTrue);
    });

    test('does nothing when playback is healthy', () async {
      final _FakeResolver resolver = _FakeResolver(
        resolved: <String, ResolvedPlayable>{
          'jellyfin:j': _stream('https://jelly/stream/j'),
        },
      );
      final JustAudioPlaybackController controller = build(
        player: _FakePlayer(),
        resolver: resolver,
      );

      await controller.playTracks(<Track>[jelly]);
      final int calls = resolver.calls.length;
      await controller.retryCurrentTrack();

      expect(resolver.calls.length, calls);
    });
  });

  group('another source', () {
    test('plays the sibling copy and keeps the same place in the queue',
        () async {
      final _FakeResolver resolver = _FakeResolver(
        failures: <String, PlaybackResolutionException>{
          'jellyfin:j': _serverDown,
          'subsonic:s': _serverDown,
        },
        resolved: <String, ResolvedPlayable>{
          'jellyfin:n': _stream('https://jelly/stream/n'),
        },
      );
      final JustAudioPlaybackController controller = build(
        player: _FakePlayer(),
        resolver: resolver,
        candidates: <String, List<Track>>{
          'jellyfin:j': <Track>[jelly, sub],
        },
      );

      await controller.playTracks(<Track>[jelly, next]);
      expect(controller.state.failure?.canTryAnotherSource, isTrue);

      // Navidrome answers now.
      resolver.failures.remove('subsonic:s');
      resolver.resolved['subsonic:s'] = _stream('https://sub/stream/s');
      await controller.tryAnotherSource();

      expect(controller.state.failure, isNull);
      // The queue entry became the copy that works: it was replaced, not
      // duplicated, so the song keeps its one place in the queue.
      expect(controller.state.currentTrack?.uri, 'subsonic:s');
      expect(
        controller.state.upNext.map((Track t) => t.uri),
        <String>['jellyfin:n'],
      );
      expect(controller.state.previous, isEmpty);
      expect(controller.state.source, PlaybackSource.streamingDirect);
    });

    test('is not offered, and does nothing, for a single-source song',
        () async {
      final _FakeResolver resolver = _FakeResolver(
        failures: <String, PlaybackResolutionException>{
          'jellyfin:j': _serverDown,
        },
      );
      final JustAudioPlaybackController controller = build(
        player: _FakePlayer(),
        resolver: resolver,
        candidates: <String, List<Track>>{
          'jellyfin:j': <Track>[jelly],
        },
      );

      await controller.playTracks(<Track>[jelly]);
      final int calls = resolver.calls.length;

      expect(controller.state.failure?.canTryAnotherSource, isFalse);
      await controller.tryAnotherSource();

      // No candidate to try means no work and no state churn, not a silent
      // re-run of the copy that just failed.
      expect(resolver.calls.length, calls);
      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.currentTrack?.uri, 'jellyfin:j');
    });

    test('every copy failing leaves one clear error on the same queue entry',
        () async {
      final _FakeResolver resolver = _FakeResolver(
        failures: <String, PlaybackResolutionException>{
          'jellyfin:j': _serverDown,
          'subsonic:s': _serverDown,
        },
        resolved: <String, ResolvedPlayable>{
          'jellyfin:n': _stream('https://jelly/stream/n'),
        },
      );
      final JustAudioPlaybackController controller = build(
        player: _FakePlayer(),
        resolver: resolver,
        candidates: <String, List<Track>>{
          'jellyfin:j': <Track>[jelly, sub],
        },
      );

      await controller.playTracks(<Track>[jelly, next]);
      await controller.tryAnotherSource();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.currentTrack?.uri, 'jellyfin:j');
      expect(controller.state.failure?.message, isNot(contains('http')));
      expect(
        controller.state.upNext.map((Track t) => t.uri),
        <String>['jellyfin:n'],
      );
    });
  });

  group('skip', () {
    test('advances exactly one track and leaves the rest of the queue alone',
        () async {
      final Track third = _track('t', 'jellyfin:t');
      final _FakeResolver resolver = _FakeResolver(
        failures: <String, PlaybackResolutionException>{
          'jellyfin:j': _serverDown,
        },
        resolved: <String, ResolvedPlayable>{
          'jellyfin:n': _stream('https://jelly/stream/n'),
          'jellyfin:t': _stream('https://jelly/stream/t'),
        },
      );
      final JustAudioPlaybackController controller = build(
        player: _FakePlayer(),
        resolver: resolver,
      );

      await controller.playTracks(<Track>[jelly, next, third]);
      expect(controller.state.failure?.canSkip, isTrue);

      await controller.skipToNext();

      expect(controller.state.failure, isNull);
      expect(controller.state.currentTrack?.uri, 'jellyfin:n');
      expect(
        controller.state.upNext.map((Track t) => t.uri),
        <String>['jellyfin:t'],
      );
      // The failed track is history, exactly once.
      expect(
        controller.state.previous.map((Track t) => t.uri),
        <String>['jellyfin:j'],
      );
    });

    test('is not offered for the last track in the queue', () async {
      final _FakeResolver resolver = _FakeResolver(
        failures: <String, PlaybackResolutionException>{
          'jellyfin:j': _serverDown,
        },
      );
      final JustAudioPlaybackController controller = build(
        player: _FakePlayer(),
        resolver: resolver,
      );

      await controller.playTracks(<Track>[jelly]);

      expect(controller.state.failure?.canSkip, isFalse);
    });
  });

  test('a failed track leaves the queue exactly as it was', () async {
    final _FakeResolver resolver = _FakeResolver(
      failures: <String, PlaybackResolutionException>{
        'jellyfin:n': _serverDown,
      },
      resolved: <String, ResolvedPlayable>{
        'jellyfin:j': _stream('https://jelly/stream/j'),
        '/music/one.mp3': _localFile('/music/one.mp3'),
      },
    );
    final JustAudioPlaybackController controller = build(
      player: _FakePlayer(),
      resolver: resolver,
    );

    await controller.playTracks(<Track>[jelly, next, localOnly]);
    // Move onto the track that cannot play.
    await controller.skipToNext();

    expect(controller.state.status, PlaybackStatus.error);
    expect(controller.state.currentTrack?.uri, 'jellyfin:n');
    expect(
      controller.state.previous.map((Track t) => t.uri),
      <String>['jellyfin:j'],
    );
    expect(
      controller.state.upNext.map((Track t) => t.uri),
      <String>['/music/one.mp3'],
    );
    expect(controller.state.hasPrevious, isTrue);
  });
}
