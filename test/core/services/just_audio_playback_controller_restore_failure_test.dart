import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_candidate_source.dart';
import 'package:linthra/core/services/playback_recovery_policy.dart';

/// An engine with just_audio's Android semantics where they matter for #832:
///
///  * its `playing` flag survives a failure and a load, so a reload of a
///    track that was playing comes up ready and playing (at the start);
///  * a seek is answered only when the engine next reports ready, or when a
///    newer seek replaces it. A source that fails first never gets there, and
///    the error leaves the seek waiting: only the next source's ready (setUrl
///    does not clear it) or a newer seek answers it. The ready report, the
///    answer to a setUrl and the answer to that seek are separate messages,
///    handled in that order;
///  * a failure is raised on the event channel. A failed open is raised from
///    setUrl first and on the event channel after, as `sendError` does: the
///    two are separate messages, handled in the order they were sent.
class _AndroidEngine extends Fake implements AudioPlayer {
  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast();
  final StreamController<PlaybackEvent> _events =
      StreamController<PlaybackEvent>.broadcast();

  final List<String> opened = <String>[];
  final List<Duration> seeks = <Duration>[];

  /// Seeks wait for the test to say the target was reached
  /// ([reachSeekTarget]) or that the source failed ([failSource]).
  bool stallSeeks = false;

  /// How many of the next opens fail.
  int failingOpens = 0;

  /// Holds the answer to the next setVolume, which every load awaits between
  /// its source opening and moving it to its start.
  Completer<void>? holdVolume;

  /// Holds the next open between its loading report and its ready.
  Completer<void>? holdOpen;

  bool _playing = false;
  bool _failed = false;
  ProcessingState _processing = ProcessingState.idle;
  Completer<void>? _seek;

  bool get seekWaiting => _seek != null;

  /// The flag play/pause set, which survives a failure.
  @override
  bool get playing => _playing;

  /// Whether anything can be heard.
  bool get sounding =>
      _playing && !_failed && _processing == ProcessingState.ready;

  void _report() => _states.add(PlayerState(_playing, _processing));

  /// Answers the waiting seek, as a message of its own after whatever the
  /// engine has sent so far.
  void _answerSeek() {
    final Completer<void>? seek = _seek;
    _seek = null;
    if (seek != null) Timer.run(seek.complete);
  }

  void _reportReady() {
    _processing = ProcessingState.ready;
    _report();
  }

  void _ready() {
    _reportReady();
    _answerSeek();
  }

  /// The source fails: a dropped connection, or a range request for the
  /// seek target that the server refuses.
  void failSource() {
    _failed = true;
    _events.addError(PlayerException(0, 'Source error'));
  }

  /// The engine has buffered enough at the seek target.
  void reachSeekTarget() => _ready();

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
    opened.add(url);
    _failed = false;
    _processing = ProcessingState.loading;
    _report();
    final Completer<void>? hold = holdOpen;
    holdOpen = null;
    if (hold != null) await hold.future;
    await Future<void>.delayed(Duration.zero);
    if (failingOpens > 0) {
      failingOpens--;
      _failed = true;
      Timer.run(() => _events.addError(PlayerException(0, 'Source error')));
      throw PlayerException(0, 'Source error');
    }
    _reportReady();
    await Future<void>.delayed(Duration.zero);
    // The seek answered by this ready is answered after setUrl is.
    _answerSeek();
    return const Duration(minutes: 3);
  }

  @override
  Future<void> seek(Duration? position, {int? index}) {
    seeks.add(position!);
    if (_processing == ProcessingState.idle ||
        _processing == ProcessingState.loading) {
      return Future<void>.value();
    }
    // A newer seek answers the one it replaces.
    _answerSeek();
    final Completer<void> seek = _seek = Completer<void>();
    _processing = ProcessingState.buffering;
    _report();
    if (!stallSeeks && !_failed) _ready();
    return seek.future;
  }

  @override
  Future<void> play() async {
    if (_playing) return;
    _playing = true;
    _report();
  }

  @override
  Future<void> pause() async {
    if (!_playing) return;
    _playing = false;
    _report();
  }

  @override
  Future<void> setVolume(double volume) async {
    final Completer<void>? hold = holdVolume;
    holdVolume = null;
    if (hold != null) await hold.future;
  }

  /// just_audio drops its playing flag on a stop. A seek still waiting is
  /// left waiting, as on Android.
  @override
  Future<void> stop() async {
    _playing = false;
    _processing = ProcessingState.idle;
    _report();
  }

  @override
  Future<void> dispose() async {
    await _states.close();
    await _events.close();
  }
}

/// Resolves at once, except a uri the test holds. A uri in [cached] resolves
/// to its offline-cache file.
class _Resolver implements PlayableUriResolver {
  final Map<String, Completer<void>> held = <String, Completer<void>>{};
  final Set<String> cached = <String>{};

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    final Completer<void>? gate = held.remove(track.uri);
    if (gate != null) await gate.future;
    final String path = track.uri.replaceAll(':', '/');
    if (cached.contains(track.uri)) {
      return ResolvedPlayable(
        Uri.parse('file:///cache/$path'),
        PlaybackSource.offlineCache,
      );
    }
    return ResolvedPlayable(
      Uri.parse('https://host/$path'),
      PlaybackSource.streamingDirect,
    );
  }
}

/// The streaming fallback: resolves past the offline cache to the live
/// stream, and records what it was asked for.
class _StreamResolver implements PlayableUriResolver {
  final List<String> calls = <String>[];

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    calls.add(track.uri);
    return ResolvedPlayable(
      Uri.parse('https://host/stream/${track.uri.replaceAll(':', '/')}'),
      PlaybackSource.streamingDirect,
    );
  }
}

/// Every track has a second copy of the song on another server.
class _TwoCopies implements PlaybackCandidateSource {
  @override
  List<Track> candidatesFor(Track track) => <Track>[
        Track(id: track.id, title: track.title, uri: 'jellyfin:${track.id}'),
        Track(id: track.id, title: track.title, uri: 'subsonic:${track.id}'),
      ];
}

Track _track(String id) => Track(
      id: id,
      title: id,
      uri: 'jellyfin:$id',
      duration: const Duration(minutes: 3),
    );

const PlaybackRecoveryPolicy _instant = PlaybackRecoveryPolicy(
  retryDelay: Duration.zero,
  advanceDelay: Duration.zero,
  maxAdvanceDelay: Duration.zero,
);

const Duration _spot = Duration(seconds: 90);

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _AndroidEngine engine;
  late _Resolver resolver;

  JustAudioPlaybackController controllerFor({
    PlaybackRecoveryPolicy? policy,
    PlaybackCandidateSource candidates = const NoFallbackCandidateSource(),
    PlayableUriResolver? streaming,
  }) {
    final JustAudioPlaybackController controller = JustAudioPlaybackController(
      player: engine,
      resolver: resolver,
      candidates: candidates,
      streamingFallbackResolver: streaming,
      automaticRecovery: policy,
    )
      ..streamRetryBackoff = Duration.zero
      ..midStreamBufferingTimeout = const Duration(hours: 1);
    addTearDown(controller.dispose);
    return controller;
  }

  /// Plays [tracks] and drops the first one's stream at [_spot], with the
  /// engine unable to reach that spot again: the quick reconnect reopens the
  /// stream and is left seeking back to it.
  Future<void> reconnectStuckSeeking(
    JustAudioPlaybackController controller,
    List<Track> tracks,
  ) async {
    await controller.playTracks(tracks);
    await _settle();
    expect(controller.state.status, PlaybackStatus.playing);
    controller.setPositionForTesting(_spot);
    engine.stallSeeks = true;
    engine.failSource();
    await _settle();
    expect(engine.opened, hasLength(2), reason: 'the reconnect reopened it');
    expect(engine.seeks.last, _spot);
    expect(engine.seekWaiting, isTrue);
    expect(controller.state.status, PlaybackStatus.buffering);
  }

  /// Leaves [track] on the error panel at [_spot] with nothing playing in the
  /// engine: its first open fails, and the listener moves the bar there.
  Future<void> failedAtSpot(
    JustAudioPlaybackController controller,
    Track track,
  ) async {
    engine.failingOpens = 1;
    await controller.playTracks(<Track>[track]);
    await _settle();
    expect(controller.state.status, PlaybackStatus.error);
    await controller.seek(_spot);
    expect(controller.state.position, _spot);
  }

  setUp(() {
    engine = _AndroidEngine();
    resolver = _Resolver();
  });

  group('a source that fails while its reload seeks back (#832)', () {
    test(
        'a reconnect settles on the failure instead of buffering for good, '
        'and Retry still picks the song up where it was', () async {
      final JustAudioPlaybackController controller = controllerFor();
      await reconnectStuckSeeking(controller, <Track>[_track('a')]);

      engine.failSource();
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.failure?.canRetry, isTrue);
      expect(controller.state.position, _spot,
          reason: 'where the song was, not where the dead source opened');
      expect(engine.opened, hasLength(2),
          reason: 'its one quick reconnect was spent');

      engine.stallSeeks = false;
      await controller.retryCurrentTrack();
      await _settle();
      expect(engine.opened, hasLength(3));
      expect(engine.seeks.last, _spot);
      expect(controller.state.status, PlaybackStatus.playing);
      expect(engine.sounding, isTrue);
    });

    test(
        'the reconnect lets go of recovery: the automatic retry reloads it '
        'and it plays on from the same spot', () async {
      final JustAudioPlaybackController controller =
          controllerFor(policy: _instant);
      await reconnectStuckSeeking(controller, <Track>[_track('a')]);

      engine.stallSeeks = false;
      engine.failSource();
      await _settle();

      expect(engine.opened, hasLength(3),
          reason: 'one automatic retry, after the reconnect gave up');
      expect(engine.seeks.last, _spot);
      expect(controller.state.status, PlaybackStatus.playing);
      expect(engine.sounding, isTrue);
    });

    test(
        'a reload that keeps failing the same way still stops where the '
        'policy says', () async {
      final JustAudioPlaybackController controller =
          controllerFor(policy: _instant);
      await reconnectStuckSeeking(controller, <Track>[_track('a')]);

      // The reconnect fails seeking back; so does the automatic retry.
      engine.failSource();
      await _settle();
      expect(engine.opened, hasLength(3));
      expect(engine.seekWaiting, isTrue);
      engine.failSource();
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.hasPendingAutomaticRecovery, isFalse);
      expect(engine.opened, hasLength(3),
          reason: 'one quick reconnect and one automatic retry, no more');
      expect(controller.state.position, _spot);
    });

    test('a pause while the reconnect seeks back holds through its failure',
        () async {
      final JustAudioPlaybackController controller =
          controllerFor(policy: _instant);
      await reconnectStuckSeeking(controller, <Track>[_track('a')]);

      await controller.pause();
      await _settle();
      engine.stallSeeks = false;
      engine.failSource();
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.playWhenReady, isFalse);
      expect(controller.hasPendingAutomaticRecovery, isFalse);
      expect(engine.opened, hasLength(2),
          reason: 'nothing reloads a song the listener paused');
      expect(engine.sounding, isFalse);

      await controller.play();
      await _settle();
      expect(engine.seeks.last, _spot);
      expect(controller.state.status, PlaybackStatus.playing);
      expect(engine.sounding, isTrue);
    });

    test(
        'Retry returns, rather than staying on Loading, when the source '
        'fails while it seeks back', () async {
      final JustAudioPlaybackController controller = controllerFor();
      await failedAtSpot(controller, _track('a'));

      engine.stallSeeks = true;
      bool returned = false;
      unawaited(controller.retryCurrentTrack().whenComplete(() {
        returned = true;
      }));
      await _settle();
      expect(engine.seekWaiting, isTrue);
      expect(controller.state.status, PlaybackStatus.loading);
      expect(returned, isFalse);

      engine.failSource();
      await _settle();

      expect(returned, isTrue);
      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.position, _spot);
      expect(controller.state.failure?.canRetry, isTrue);

      // Nothing was left behind holding playback: the next Retry plays.
      engine.stallSeeks = false;
      await controller.retryCurrentTrack();
      await _settle();
      expect(engine.seeks.last, _spot);
      expect(controller.state.status, PlaybackStatus.playing);
      expect(engine.sounding, isTrue);
    });

    test(
        'a seek made while Retry loads is where the song stays when that '
        'load fails getting there', () async {
      const Duration later = Duration(minutes: 2);
      final Track a = _track('a');
      final JustAudioPlaybackController controller = controllerFor();
      await failedAtSpot(controller, a);

      final Completer<void> server = resolver.held[a.uri] = Completer<void>();
      engine.stallSeeks = true;
      final Future<void> retry = controller.retryCurrentTrack();
      await _settle();
      await controller.seek(later);
      server.complete();
      await _settle();
      expect(engine.seeks.last, later);

      engine.failSource();
      await retry;
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.position, later);
    });

    test(
        'Play pressed while Retry gets back to its spot changes nothing about '
        'who answers its failure', () async {
      final JustAudioPlaybackController controller = controllerFor();
      await failedAtSpot(controller, _track('a'));
      engine.stallSeeks = true;
      final Future<void> retry = controller.retryCurrentTrack();
      await _settle();
      await controller.play();
      await _settle();
      expect(engine.seekWaiting, isTrue);

      engine.failSource();
      await retry;
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.position, _spot);
      expect(engine.opened, hasLength(2), reason: 'nothing reloaded by itself');
      expect(engine.sounding, isFalse);
    });

    test('a Retry that opens but fails seeking back still spends its attempt',
        () async {
      final JustAudioPlaybackController controller = controllerFor();
      await failedAtSpot(controller, _track('a'));
      engine.stallSeeks = true;

      for (int i = 0;
          i < JustAudioPlaybackController.maxRecoveryAttemptsPerTrack;
          i++) {
        expect(controller.state.failure?.canRetry, isTrue);
        final Future<void> retry = controller.retryCurrentTrack();
        await _settle();
        engine.failSource();
        await retry;
        await _settle();
        expect(controller.state.status, PlaybackStatus.error);
      }

      expect(controller.state.failure?.canRetry, isFalse);
      final int opens = engine.opened.length;
      await controller.retryCurrentTrack();
      await _settle();
      expect(engine.opened, hasLength(opens));
    });

    test('Try another source returns when that copy fails seeking back',
        () async {
      final JustAudioPlaybackController controller =
          controllerFor(candidates: _TwoCopies());
      engine.failingOpens = 2;
      await controller.playTracks(<Track>[_track('a')]);
      await _settle();
      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.failure?.canTryAnotherSource, isTrue);
      await controller.seek(_spot);

      engine.stallSeeks = true;
      final Future<void> attempt = controller.tryAnotherSource();
      await _settle();
      expect(engine.opened.last, 'https://host/subsonic/a');
      expect(engine.seekWaiting, isTrue);

      engine.failSource();
      await attempt;
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.position, _spot);
    });

    test(
        'a reconnect the listener skipped away from does not touch the next '
        'song, and that song\'s own drop is still handled', () async {
      final Track a = _track('a');
      final Track b = _track('b');
      final JustAudioPlaybackController controller = controllerFor();
      await reconnectStuckSeeking(controller, <Track>[a, b]);

      engine.stallSeeks = false;
      await controller.skipToNext();
      await _settle();
      expect(controller.state.currentTrack, b);
      expect(controller.state.status, PlaybackStatus.playing);
      expect(engine.sounding, isTrue);

      engine.failSource();
      await _settle();
      expect(engine.opened.last, 'https://host/jellyfin/b',
          reason: 'B gets its quick reconnect');
      expect(controller.state.currentTrack, b);
      expect(controller.state.status, PlaybackStatus.playing);
    });

    // Every load that can be left moving its source to its start when the
    // listener skips away, and so leave its source's failure to arrive while
    // the next song still resolves.
    final Map<String,
            Future<void> Function(JustAudioPlaybackController, Track, Track)>
        stuckGettingBack = <String,
            Future<void> Function(JustAudioPlaybackController, Track, Track)>{
      'a reconnect': (controller, a, b) =>
          reconnectStuckSeeking(controller, <Track>[a, b]),
      'a Retry': (controller, a, b) async {
        engine.failingOpens = 2;
        await controller.playTracks(<Track>[a, b]);
        await _settle();
        await controller.seek(_spot);
        engine.stallSeeks = true;
        unawaited(controller.retryCurrentTrack());
        await _settle();
      },
      'Try another source': (controller, a, b) async {
        engine.failingOpens = 2;
        await controller.playTracks(<Track>[a, b]);
        await _settle();
        await controller.seek(_spot);
        engine.stallSeeks = true;
        unawaited(controller.tryAnotherSource());
        await _settle();
        expect(engine.opened.last, 'https://host/subsonic/a');
      },
      'the walk to another copy after a second drop': (controller, a, b) async {
        await controller.playTracks(<Track>[a, b]);
        await _settle();
        controller.setPositionForTesting(_spot);
        engine.failSource();
        await _settle();
        expect(controller.state.status, PlaybackStatus.playing);
        engine.stallSeeks = true;
        engine.failSource();
        await _settle();
        expect(engine.opened.last, 'https://host/subsonic/a');
      },
    };
    stuckGettingBack.forEach((String load,
        Future<void> Function(JustAudioPlaybackController, Track, Track)
            stuck) {
      test(
          'the old source failing while the next song still resolves is not '
          'that song\'s failure, after $load', () async {
        final Track a = _track('a');
        final Track b = _track('b');
        final JustAudioPlaybackController controller =
            controllerFor(candidates: _TwoCopies());
        await stuck(controller, a, b);
        expect(engine.seekWaiting, isTrue);

        final Completer<void> bServer =
            resolver.held['jellyfin:b'] = Completer<void>();
        final Future<void> skip = controller.skipToNext();
        await _settle();
        engine.failSource();
        await _settle();
        expect(controller.state.status, PlaybackStatus.loading);
        expect(controller.state.failure, isNull);

        engine.stallSeeks = false;
        bServer.complete();
        await skip;
        await _settle();
        expect(controller.state.currentTrack?.id, 'b');
        expect(controller.state.failure, isNull);
        expect(controller.state.status, PlaybackStatus.playing);
        expect(engine.sounding, isTrue);
      });
    });

    test(
        'a restored queue that fails getting back to its spot stays paused, '
        'where the listener last put it', () async {
      const Duration later = Duration(minutes: 2);
      final JustAudioPlaybackController controller =
          controllerFor(policy: _instant);
      engine.stallSeeks = true;
      final Future<void> restore = controller.restoreSession(
        tracks: <Track>[_track('a'), _track('b')],
        position: _spot,
      );
      await _settle();
      expect(engine.seekWaiting, isTrue);
      // MPRIS or a lyric tap moves it while it is still getting there.
      await controller.seek(later);

      engine.failSource();
      await restore;
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.position, later);
      expect(controller.state.playWhenReady, isFalse);
      expect(controller.hasPendingAutomaticRecovery, isFalse,
          reason:
              'nothing recovers on its own for a load nobody asked to hear');
      expect(engine.opened, hasLength(1));
      expect(engine.playing, isFalse);

      engine.stallSeeks = false;
      await controller.play();
      await _settle();
      expect(engine.seeks.last, later);
      expect(controller.state.status, PlaybackStatus.playing);
    });

    test(
        'the stuck reconnect unwinding when the next song opens does not '
        'start that song after a pause', () async {
      final Track b = _track('b');
      final JustAudioPlaybackController controller = controllerFor();
      await reconnectStuckSeeking(controller, <Track>[_track('a'), b]);

      final Completer<void> bServer = resolver.held[b.uri] = Completer<void>();
      engine.stallSeeks = false;
      final Future<void> skip = controller.skipToNext();
      await _settle();
      await controller.pause();
      // B's ready answers the reconnect's seek, which has waited all along.
      bServer.complete();
      await skip;
      await _settle();

      expect(engine.seekWaiting, isFalse);
      expect(controller.state.currentTrack, b);
      expect(controller.state.status, PlaybackStatus.paused);
      expect(engine.playing, isFalse);
    });

    test('a Retry that plays gives the listener their attempts back', () async {
      final JustAudioPlaybackController controller = controllerFor();
      await failedAtSpot(controller, _track('a'));
      engine.stallSeeks = true;
      for (int i = 1;
          i < JustAudioPlaybackController.maxRecoveryAttemptsPerTrack;
          i++) {
        final Future<void> retry = controller.retryCurrentTrack();
        await _settle();
        engine.failSource();
        await retry;
        await _settle();
      }
      engine.stallSeeks = false;
      await controller.retryCurrentTrack();
      await _settle();
      expect(controller.state.status, PlaybackStatus.playing);

      // It drops later; the quick reconnect fails getting back there.
      engine.stallSeeks = true;
      engine.failSource();
      await _settle();
      engine.failSource();
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.failure?.canRetry, isTrue);
    });
  });

  group('loads that overlap', () {
    // The engine holds one source at a time, and its errors don't say which.
    // A load only starts listening for one once its own setUrl has answered:
    // anything before that fails the open itself, and the source before it
    // has been stopped by then. What a superseded load does as it unwinds
    // must not take that away from the load that replaced it.

    test(
        'a stuck Retry that unwinds while the load after Stop and Play sets '
        'its volume leaves that load its own failure', () async {
      const Duration later = Duration(minutes: 1);
      final JustAudioPlaybackController controller = controllerFor();
      await failedAtSpot(controller, _track('a'));
      engine.stallSeeks = true;
      unawaited(controller.retryCurrentTrack());
      await _settle();
      expect(engine.seekWaiting, isTrue);

      await controller.stop();
      await controller.seek(later);
      final Completer<void> volume = engine.holdVolume = Completer<void>();
      bool returned = false;
      unawaited(controller.play().whenComplete(() {
        returned = true;
      }));
      await _settle();
      // Open, and its ready has answered the Retry's seek: the Retry has
      // unwound while this load still sets its volume.
      expect(engine.opened, hasLength(3));
      expect(engine.seekWaiting, isFalse);

      engine.failSource();
      await _settle();
      volume.complete();
      await _settle();

      expect(returned, isTrue);
      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.position, later);
    });

    test(
        'a reconnect, a skip still resolving and a jump to a third song: '
        'only the third song\'s load answers for its source', () async {
      final Track a = _track('a');
      final Track b = _track('b');
      final Track c = _track('c');
      final JustAudioPlaybackController controller = controllerFor();
      await reconnectStuckSeeking(controller, <Track>[a, b, c]);

      final Completer<void> bServer = resolver.held[b.uri] = Completer<void>();
      unawaited(controller.skipToNext());
      await _settle();
      // A's source fails while B resolves: neither A nor B is told.
      engine.failSource();
      await _settle();
      expect(controller.state.status, PlaybackStatus.loading);
      expect(controller.state.failure, isNull);

      final Completer<void> volume = engine.holdVolume = Completer<void>();
      unawaited(controller.playFromQueue(0));
      await _settle();
      expect(controller.state.currentTrack, c);
      expect(engine.opened, <String>[
        'https://host/jellyfin/a',
        'https://host/jellyfin/a',
        'https://host/jellyfin/c',
      ]);
      expect(engine.seekWaiting, isFalse,
          reason: "C's ready answered A's seek");

      // C's source fails while C sets its volume, after A has unwound.
      engine.failSource();
      await _settle();
      volume.complete();
      await _settle();
      bServer.complete();
      await _settle();

      expect(controller.state.currentTrack, c);
      expect(controller.state.status, PlaybackStatus.error);
      expect(engine.opened, hasLength(3),
          reason: 'B never reached the engine, and nothing reconnected C');
    });

    test(
        'a source failing while a cast holds playback leaves the stuck '
        'reload alone, and the reload after the cast plays', () async {
      final JustAudioPlaybackController controller = controllerFor();
      await failedAtSpot(controller, _track('a'));
      engine.stallSeeks = true;
      bool returned = false;
      unawaited(controller.retryCurrentTrack().whenComplete(() {
        returned = true;
      }));
      await _settle();

      await controller.suspend();
      engine.failSource();
      await _settle();
      expect(controller.state.status, isNot(PlaybackStatus.error),
          reason: 'the cast owns playback; nothing local fails under it');

      engine.stallSeeks = false;
      await controller.resume(at: _spot, play: true);
      await _settle();

      expect(returned, isTrue);
      expect(engine.seeks.last, _spot);
      expect(controller.state.status, PlaybackStatus.playing);
      expect(engine.sounding, isTrue);
    });
  });

  group('a copy that opens and fails before it starts', () {
    // Such a copy is one that didn't work, exactly like one that wouldn't
    // open: the cached file gets its one try from the live stream, and the
    // song's other copies are walked, each once.
    const String cache = 'file:///cache/jellyfin/a';
    const String liveA = 'https://host/stream/jellyfin/a';
    const String otherA = 'https://host/subsonic/a';

    late _StreamResolver streaming;

    setUp(() {
      streaming = _StreamResolver();
      resolver.cached.add('jellyfin:a');
    });

    /// Plays A from its cached file, then drops it at [_spot]: the
    /// reconnect reopens the cached file and is left seeking back.
    Future<void> reconnectStuckOnCache(
      JustAudioPlaybackController controller,
    ) async {
      await controller.playTracks(<Track>[_track('a')]);
      await _settle();
      expect(controller.state.status, PlaybackStatus.playing);
      controller.setPositionForTesting(_spot);
      engine.stallSeeks = true;
      engine.failSource();
      await _settle();
      expect(engine.opened, <String>[cache, cache]);
      expect(engine.seekWaiting, isTrue);
    }

    test('a cached file that fails getting back plays on from the stream',
        () async {
      final JustAudioPlaybackController controller =
          controllerFor(streaming: streaming);
      await reconnectStuckOnCache(controller);

      engine.stallSeeks = false;
      engine.failSource();
      await _settle();

      expect(streaming.calls, <String>['jellyfin:a']);
      expect(engine.opened.last, liveA);
      expect(engine.seeks.last, _spot);
      expect(controller.state.status, PlaybackStatus.playing);
      expect(controller.state.failure, isNull);
      expect(controller.state.source, PlaybackSource.streamingDirect);
      expect(engine.sounding, isTrue);
    });

    test(
        'a copy that fails getting back hands over to the next copy, which '
        'takes its place in the queue', () async {
      resolver.cached.clear();
      final JustAudioPlaybackController controller =
          controllerFor(candidates: _TwoCopies());
      await reconnectStuckSeeking(
          controller, <Track>[_track('a'), _track('b')]);

      engine.stallSeeks = false;
      engine.failSource();
      await _settle();

      expect(engine.opened.last, otherA);
      expect(engine.seeks.last, _spot);
      expect(controller.state.currentTrack?.uri, 'subsonic:a');
      expect(controller.state.upNext.single.uri, 'jellyfin:b');
      expect(controller.state.status, PlaybackStatus.playing);
      expect(controller.state.failure, isNull);
      expect(engine.sounding, isTrue);
    });

    test(
        'a cached file and its stream that both fail still leave the other '
        'copy its one try, and nothing after it', () async {
      final JustAudioPlaybackController controller =
          controllerFor(candidates: _TwoCopies(), streaming: streaming);
      await reconnectStuckOnCache(controller);

      engine.failingOpens = 1;
      engine.failSource();
      await _settle();
      expect(engine.opened, <String>[cache, cache, liveA, otherA]);
      expect(engine.seekWaiting, isTrue);

      engine.failSource();
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.currentTrack?.uri, 'jellyfin:a');
      expect(controller.state.position, _spot);
      expect(streaming.calls, <String>['jellyfin:a']);
      expect(engine.opened, hasLength(4));
    });

    test('a restored queue that falls back to the stream stays paused',
        () async {
      final JustAudioPlaybackController controller =
          controllerFor(streaming: streaming, policy: _instant);
      engine.stallSeeks = true;
      final Future<void> restore = controller.restoreSession(
        tracks: <Track>[_track('a')],
        position: _spot,
      );
      await _settle();
      expect(engine.opened, <String>[cache]);

      engine.stallSeeks = false;
      engine.failSource();
      await restore;
      await _settle();

      expect(engine.opened.last, liveA);
      expect(engine.seeks.last, _spot);
      expect(controller.state.status, PlaybackStatus.paused);
      expect(controller.state.playWhenReady, isFalse);
      expect(controller.state.failure, isNull);
      expect(engine.playing, isFalse);
    });

    test('a call during an automatic retry\'s fallback keeps it from starting',
        () async {
      final JustAudioPlaybackController controller =
          controllerFor(streaming: streaming, policy: _instant)
            ..focusPauseDebounce = Duration.zero;
      await controller.playTracks(<Track>[_track('a')]);
      await _settle();
      controller.setPositionForTesting(_spot);
      // The quick reconnect opens neither the cached file nor the stream;
      // the automatic retry after it opens the cached file and is left
      // seeking back.
      engine.failingOpens = 2;
      engine.stallSeeks = true;
      engine.failSource();
      await _settle();
      expect(engine.opened, <String>[cache, cache, liveA, cache]);
      expect(engine.seekWaiting, isTrue);

      controller.onAudioInterruption(
          AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await _settle();
      expect(engine.playing, isFalse);

      engine.stallSeeks = false;
      engine.failSource();
      await _settle();

      expect(engine.opened.last, liveA);
      expect(engine.seeks.last, _spot);
      expect(engine.playing, isFalse, reason: 'the call holds playback');
      expect(controller.state.status, isNot(PlaybackStatus.playing));
    });

    test('a pause while the next copy resolves holds when it lands', () async {
      resolver.cached.clear();
      final JustAudioPlaybackController controller =
          controllerFor(candidates: _TwoCopies());
      await reconnectStuckSeeking(controller, <Track>[_track('a')]);
      final Completer<void> other =
          resolver.held['subsonic:a'] = Completer<void>();
      engine.stallSeeks = false;
      engine.failSource();
      await _settle();

      await controller.pause();
      other.complete();
      await _settle();

      expect(engine.opened.last, otherA);
      expect(engine.seeks.last, _spot);
      expect(controller.state.currentTrack?.uri, 'subsonic:a');
      expect(controller.state.status, PlaybackStatus.paused);
      expect(engine.playing, isFalse);
    });

    test(
        'a skip while the next copy resolves leaves the queue and the engine '
        'to the next song', () async {
      resolver.cached.clear();
      final JustAudioPlaybackController controller =
          controllerFor(candidates: _TwoCopies());
      await reconnectStuckSeeking(
          controller, <Track>[_track('a'), _track('b')]);
      final Completer<void> other =
          resolver.held['subsonic:a'] = Completer<void>();
      engine.stallSeeks = false;
      engine.failSource();
      await _settle();

      await controller.skipToNext();
      await _settle();
      other.complete();
      await _settle();

      expect(engine.opened, isNot(contains(otherA)));
      expect(controller.state.currentTrack?.uri, 'jellyfin:b');
      expect(controller.state.previous.single.uri, 'jellyfin:a');
      expect(controller.state.status, PlaybackStatus.playing);
    });

    test('a seek while the next copy resolves is where that copy starts',
        () async {
      const Duration later = Duration(minutes: 2);
      resolver.cached.clear();
      final JustAudioPlaybackController controller =
          controllerFor(candidates: _TwoCopies());
      await reconnectStuckSeeking(controller, <Track>[_track('a')]);
      final Completer<void> other =
          resolver.held['subsonic:a'] = Completer<void>();
      engine.stallSeeks = false;
      engine.failSource();
      await _settle();

      bool sought = false;
      unawaited(controller.seek(later).whenComplete(() {
        sought = true;
      }));
      await _settle();
      expect(sought, isTrue);
      other.complete();
      await _settle();

      expect(engine.opened.last, otherA);
      expect(engine.seeks.last, later);
      expect(controller.state.status, PlaybackStatus.playing);
      expect(engine.sounding, isTrue);
    });

    test(
        'a skip while the next copy opens leaves the next song its own place '
        'in the queue', () async {
      resolver.cached.clear();
      final Track b = _track('b');
      final JustAudioPlaybackController controller =
          controllerFor(candidates: _TwoCopies());
      await reconnectStuckSeeking(controller, <Track>[_track('a'), b]);
      final Completer<void> opening = engine.holdOpen = Completer<void>();
      engine.stallSeeks = false;
      engine.failSource();
      await _settle();
      expect(engine.opened.last, otherA);

      // The skip's song still resolves when the old copy's open answers.
      final Completer<void> bServer = resolver.held[b.uri] = Completer<void>();
      final Future<void> skip = controller.skipToNext();
      await _settle();
      opening.complete();
      await _settle();
      expect(controller.state.currentTrack?.uri, 'jellyfin:b');

      bServer.complete();
      await skip;
      await _settle();
      expect(engine.opened.last, 'https://host/jellyfin/b');
      expect(controller.state.currentTrack?.uri, 'jellyfin:b');
      expect(controller.state.previous.single.uri, 'jellyfin:a');
      expect(controller.state.status, PlaybackStatus.playing);
    });

    test('a stop while the next copy resolves loads nothing more', () async {
      resolver.cached.clear();
      final JustAudioPlaybackController controller =
          controllerFor(candidates: _TwoCopies());
      await reconnectStuckSeeking(controller, <Track>[_track('a')]);
      final Completer<void> other =
          resolver.held['subsonic:a'] = Completer<void>();
      engine.stallSeeks = false;
      engine.failSource();
      await _settle();

      await controller.stop();
      other.complete();
      await _settle();

      expect(engine.opened, isNot(contains(otherA)));
      expect(controller.state.currentTrack?.uri, 'jellyfin:a');
      expect(controller.state.status, PlaybackStatus.idle);
      expect(engine.playing, isFalse);
    });

    test(
        'a skip while the next copy starts does not start it under the next '
        'song', () async {
      resolver.cached.clear();
      final JustAudioPlaybackController controller =
          controllerFor(candidates: _TwoCopies());
      await reconnectStuckSeeking(
          controller, <Track>[_track('a'), _track('b')]);
      engine.stallSeeks = false;
      final Completer<void> volume = engine.holdVolume = Completer<void>();
      engine.failSource();
      await _settle();
      expect(engine.opened.last, otherA);

      await controller.skipToNext();
      volume.complete();
      await _settle();

      expect(engine.opened.last, 'https://host/jellyfin/b');
      expect(controller.state.currentTrack?.uri, 'jellyfin:b');
      expect(controller.state.status, PlaybackStatus.playing);
      expect(controller.state.failure, isNull);
    });

    test(
        'a Retry that walks every copy and fails spends one attempt, '
        'however many copies failed', () async {
      resolver.cached.clear();
      final JustAudioPlaybackController controller =
          controllerFor(candidates: _TwoCopies());
      engine.failingOpens = 2;
      await controller.playTracks(<Track>[_track('a')]);
      await _settle();
      await controller.seek(_spot);

      engine.stallSeeks = true;
      final Future<void> retry = controller.retryCurrentTrack();
      await _settle();
      engine.failSource();
      await _settle();
      expect(engine.opened.last, otherA);
      engine.failSource();
      await retry;
      await _settle();
      expect(controller.state.status, PlaybackStatus.error);

      int offered = 0;
      while (controller.state.failure?.canRetry ?? false) {
        offered++;
        engine.failingOpens = 2;
        await controller.retryCurrentTrack();
        await _settle();
      }
      expect(
          offered, JustAudioPlaybackController.maxRecoveryAttemptsPerTrack - 1);
    });

    test(
        'a Retry that plays from the next copy gives the song its attempts '
        'back', () async {
      resolver.cached.clear();
      final JustAudioPlaybackController controller =
          controllerFor(candidates: _TwoCopies());
      engine.failingOpens = 2;
      await controller.playTracks(<Track>[_track('a')]);
      await _settle();
      await controller.seek(_spot);
      engine.failingOpens = 2;
      await controller.retryCurrentTrack();
      await _settle();
      expect(controller.state.status, PlaybackStatus.error);

      engine.stallSeeks = true;
      final Future<void> retry = controller.retryCurrentTrack();
      await _settle();
      engine.stallSeeks = false;
      engine.failSource();
      await retry;
      await _settle();
      expect(controller.state.currentTrack?.uri, 'subsonic:a');
      expect(controller.state.status, PlaybackStatus.playing);

      // Later the song is played again and neither copy opens.
      engine.failingOpens = 2;
      await controller.playTracks(<Track>[_track('a')]);
      await _settle();
      int offered = 0;
      while (controller.state.failure?.canRetry ?? false) {
        offered++;
        engine.failingOpens = 2;
        await controller.retryCurrentTrack();
        await _settle();
      }
      expect(offered, JustAudioPlaybackController.maxRecoveryAttemptsPerTrack);
    });
  });

  group('the Retry budget', () {
    /// Retries [track] from the error panel, failing each one as it gets back
    /// to its spot, for as long as Retry is offered. Returns how many it took.
    Future<int> retriesOffered(JustAudioPlaybackController controller) async {
      engine.stallSeeks = true;
      int offered = 0;
      while (controller.state.failure?.canRetry ?? false) {
        offered++;
        final Future<void> retry = controller.retryCurrentTrack();
        await _settle();
        engine.failSource();
        await retry;
        await _settle();
        expect(controller.state.status, PlaybackStatus.error);
      }
      return offered;
    }

    test(
        'a Retry stopped while it gets back is not given back by the load '
        'that replaces it', () async {
      final JustAudioPlaybackController controller = controllerFor();
      await failedAtSpot(controller, _track('a'));
      engine.stallSeeks = true;
      unawaited(controller.retryCurrentTrack());
      await _settle();
      expect(engine.seekWaiting, isTrue);

      await controller.stop();
      await controller.seek(_spot);
      unawaited(controller.play());
      await _settle();
      // The Retry's seek has been answered by this load's ready, and that
      // load is now stuck getting back to the spot in turn.
      expect(engine.opened, hasLength(3));
      expect(engine.seekWaiting, isTrue);
      engine.failSource();
      await _settle();
      expect(controller.state.status, PlaybackStatus.error);

      expect(await retriesOffered(controller),
          JustAudioPlaybackController.maxRecoveryAttemptsPerTrack - 1);
    });

    test('a copy that plays gives the song its attempts back', () async {
      final Track a = _track('a');
      final JustAudioPlaybackController controller =
          controllerFor(candidates: _TwoCopies());
      engine.failingOpens = 2;
      await controller.playTracks(<Track>[a]);
      await _settle();
      for (int i = 1;
          i < JustAudioPlaybackController.maxRecoveryAttemptsPerTrack;
          i++) {
        engine.failingOpens = 1;
        await controller.tryAnotherSource();
        await _settle();
        expect(controller.state.status, PlaybackStatus.error);
      }
      await controller.tryAnotherSource();
      await _settle();
      expect(controller.state.status, PlaybackStatus.playing);

      // Later, the song is played again and neither copy opens.
      engine.failingOpens = 2;
      await controller.playTracks(<Track>[a]);
      await _settle();
      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.failure?.canRetry, isTrue);
    });
  });

  group('who answers a source failing as a Retry reloads it', () {
    /// Retry on a track left on the error panel at [startAt].
    Future<JustAudioPlaybackController> onErrorPanelAt(Duration startAt) async {
      final JustAudioPlaybackController controller = controllerFor();
      engine.failingOpens = 1;
      await controller.playTracks(<Track>[_track('a')]);
      await _settle();
      expect(controller.state.status, PlaybackStatus.error);
      if (startAt > Duration.zero) await controller.seek(startAt);
      return controller;
    }

    test('while it opens: setUrl, and only once', () async {
      final JustAudioPlaybackController controller =
          await onErrorPanelAt(_spot);
      engine.failingOpens = 1;
      await controller.retryCurrentTrack();
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.position, _spot);
      expect(engine.opened, hasLength(2),
          reason: 'the event that follows the failed open starts nothing');
    });

    for (final Duration startAt in <Duration>[Duration.zero, _spot]) {
      test(
          'after it opens, while its volume is set (from $startAt): the '
          'reload', () async {
        final JustAudioPlaybackController controller =
            await onErrorPanelAt(startAt);
        final Completer<void> volume = engine.holdVolume = Completer<void>();
        bool returned = false;
        unawaited(controller.retryCurrentTrack().whenComplete(() {
          returned = true;
        }));
        await _settle();
        expect(engine.opened, hasLength(2));

        engine.failSource();
        await _settle();
        volume.complete();
        await _settle();

        expect(returned, isTrue);
        expect(controller.state.status, PlaybackStatus.error);
        expect(controller.state.position, startAt);
        expect(engine.playing, isFalse,
            reason: 'a source that failed is not started');
      });
    }

    test('once it has started: the ordinary quick reconnect', () async {
      final JustAudioPlaybackController controller =
          await onErrorPanelAt(_spot);
      await controller.retryCurrentTrack();
      await _settle();
      expect(controller.state.status, PlaybackStatus.playing);

      engine.failSource();
      await _settle();

      expect(engine.opened, hasLength(3));
      expect(engine.seeks.last, _spot);
      expect(controller.state.status, PlaybackStatus.playing);
      expect(engine.sounding, isTrue);
    });
  });
}
