import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_candidate_source.dart';
import 'package:linthra/core/services/playback_recovery_policy.dart';

/// An engine whose state, position and duration streams the test drives by
/// hand, recording every transport call in order. Like just_audio, it goes on
/// holding (and reporting) the previous source until a new one is opened, and
/// it keeps that source across a stop: the next play opens it again.
class _Engine extends Fake implements AudioPlayer {
  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast();
  final StreamController<Duration> _positions =
      StreamController<Duration>.broadcast();
  final StreamController<Duration?> _durations =
      StreamController<Duration?>.broadcast();

  final List<String> calls = <String>[];

  /// URLs the engine refuses to open, like a source it can't decode.
  final Set<String> failingUrls = <String>{};

  /// URLs the engine refuses to open once, then opens.
  final Set<String> failingOnce = <String>{};

  /// While set, opening a source waits on it: the engine is still opening
  /// the new source.
  Completer<void>? openGate;

  /// While set, the next seek waits on it before it lands.
  Completer<void>? seekGate;

  /// The source last handed over, and whether a stop has let go of the
  /// platform since. just_audio keeps the source across a stop, and a play
  /// then opens it again by itself: loading, then ready, or back to idle
  /// when it no longer opens ([failingUrls]).
  String? _source;
  bool _stopped = false;

  void emitState(bool playing, ProcessingState processing) =>
      _states.add(PlayerState(playing, processing));
  void emitPosition(Duration position) => _positions.add(position);
  void emitDuration(Duration duration) => _durations.add(duration);

  String get lastTransport => calls.lastWhere(
        (String call) => call == 'play' || call == 'pause',
        orElse: () => 'none',
      );

  List<String> get loadedUrls => <String>[
        for (final String call in calls)
          if (call.startsWith('setUrl:')) call.substring('setUrl:'.length),
      ];

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;
  @override
  Stream<Duration> get positionStream => _positions.stream;
  @override
  Stream<Duration?> get durationStream => _durations.stream;
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
    calls.add('setUrl:$url');
    _source = url;
    _stopped = false;
    final Completer<void>? gate = openGate;
    if (gate != null) await gate.future;
    if (failingUrls.contains(url) || failingOnce.remove(url)) {
      throw Exception('could not open source');
    }
    return const Duration(minutes: 3);
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> play() async {
    calls.add('play');
    final String? kept = _source;
    if (!_stopped || kept == null) return;
    _stopped = false;
    emitState(true, ProcessingState.loading);
    emitState(
      true,
      failingUrls.contains(kept) ? ProcessingState.idle : ProcessingState.ready,
    );
  }

  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> stop() async {
    calls.add('stop');
    _stopped = true;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    calls.add('seek:${position?.inMilliseconds}');
    final Completer<void>? gate = seekGate;
    seekGate = null;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> dispose() async {
    await _states.close();
    await _positions.close();
    await _durations.close();
  }
}

const PlaybackResolutionException _serverDown = PlaybackResolutionException(
  "Couldn't reach your music server.",
  kind: PlaybackResolutionErrorKind.serverUnreachable,
);

/// Resolves at once unless a uri is gated (the test releases it) or down.
class _Resolver implements PlayableUriResolver {
  final Map<String, Completer<void>> gates = <String, Completer<void>>{};
  final Set<String> down = <String>{};

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    final Completer<void>? gate = gates[track.uri];
    if (gate != null) await gate.future;
    if (down.contains(track.uri)) throw _serverDown;
    return ResolvedPlayable(
      Uri.parse(_url(track)),
      PlaybackSource.streamingDirect,
    );
  }

  void gate(Track track) => gates[track.uri] = Completer<void>();

  void release(Track track) => gates.remove(track.uri)!.complete();
}

/// Other copies of the same song, tried in order when one will not play.
class _Copies implements PlaybackCandidateSource {
  _Copies(this.copies);

  final Map<String, List<Track>> copies;

  @override
  List<Track> candidatesFor(Track track) => copies[track.uri] ?? <Track>[track];
}

Track _track(String id) => Track(
      id: id,
      title: id,
      uri: 'jellyfin:$id',
      duration: const Duration(minutes: 3),
    );

String _url(Track track) => 'https://host/stream/${track.id}';

/// Lets stream deliveries and the awaits behind them run.
Future<void> _settle() async {
  for (int i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final Track a = _track('a');
  final Track b = _track('b');
  final Track c = _track('c');

  late _Engine engine;
  late _Resolver resolver;
  late List<Track> completed;

  JustAudioPlaybackController build() {
    completed = <Track>[];
    final JustAudioPlaybackController controller = JustAudioPlaybackController(
      player: engine,
      resolver: resolver,
      onTrackCompleted: completed.add,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  setUp(() {
    engine = _Engine();
    resolver = _Resolver();
  });

  group('while a new track loads, the previous one is not reported as it', () {
    test('the previous song ending is not the loading track ending', () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a, b, c]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      // Next pressed in A's last seconds; B is slow to resolve and A ends.
      resolver.gate(b);
      final Future<void> skip = controller.skipToNext();
      await _settle();
      engine.emitState(true, ProcessingState.completed);
      await _settle();
      resolver.release(b);
      await skip;
      await _settle();

      expect(controller.state.currentTrack, b,
          reason: 'the listener asked for B and must get B, not C');
      expect(engine.loadedUrls, <String>[_url(a), _url(b)]);
      expect(completed, isEmpty,
          reason: 'B never played, so it must not be recorded as played');
    });

    test(
        'a pause after a natural end, while the next track loads, does not '
        'end it again', () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a, b, c]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      // A ends naturally and B starts loading, slowly.
      resolver.gate(b);
      engine.emitState(true, ProcessingState.completed);
      await _settle();
      expect(controller.state.currentTrack, b);
      expect(completed, <Track>[a]);

      // just_audio keeps "playing" true after the end, so a pause now
      // re-sends the completed pair with playing false.
      await controller.pause();
      engine.emitState(false, ProcessingState.completed);
      await _settle();
      resolver.release(b);
      await _settle();

      expect(controller.state.currentTrack, b,
          reason: 'the re-sent end is still A\'s, not a reason to skip B');
      expect(engine.loadedUrls, isNot(contains(_url(c))));
      expect(completed, <Track>[a]);
    });

    test('the previous song\'s progress never shows on the loading track',
        () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a, b]);
      engine.emitState(true, ProcessingState.ready);
      engine.emitDuration(const Duration(minutes: 4));
      await _settle();

      resolver.gate(b);
      final Future<void> skip = controller.skipToNext();
      await _settle();
      engine.emitPosition(const Duration(minutes: 2, seconds: 13));
      engine.emitDuration(const Duration(minutes: 4));
      engine.emitState(true, ProcessingState.ready);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(controller.state.currentTrack, b);
      expect(controller.state.status, PlaybackStatus.loading);
      expect(controller.state.position, Duration.zero);
      expect(controller.state.duration, Duration.zero);

      resolver.release(b);
      await skip;
    });

    test(
        'the previous song ending while the new source opens is not the new '
        'track ending', () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a, b, c]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      // B resolved and went to the engine, which is still opening it when
      // A's end, queued just before, is delivered.
      engine.openGate = Completer<void>();
      final Future<void> skip = controller.skipToNext();
      await _settle();
      expect(engine.loadedUrls.last, _url(b));
      engine.emitState(true, ProcessingState.completed);
      await _settle();
      engine.openGate!.complete();
      await skip;
      await _settle();

      expect(controller.state.currentTrack, b);
      expect(engine.loadedUrls, isNot(contains(_url(c))));
      expect(completed, isEmpty);
    });

    test(
        'a new source that loads and ends before it has finished opening is '
        'acted on', () async {
      // just_audio's setUrl only returns once the processing state has left
      // loading, so an empty or instantly ending source reports its end first.
      // It reports loading before that, which the replaced song's late end
      // never follows.
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a, b, c]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      engine.openGate = Completer<void>();
      final Future<void> skip = controller.skipToNext();
      await _settle();
      engine.emitState(true, ProcessingState.loading);
      engine.emitState(true, ProcessingState.completed);
      await _settle();
      engine.openGate!.complete();
      engine.openGate = null;
      await skip;
      await _settle();

      expect(completed, <Track>[b]);
      expect(controller.state.currentTrack, c);
      expect(engine.loadedUrls.last, _url(c));
    });

    test(
        'an end from a copy that failed to open is not taken for the next '
        'copy\'s', () async {
      final Track b2 = _track('b2');
      completed = <Track>[];
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(
        player: engine,
        resolver: resolver,
        onTrackCompleted: completed.add,
        candidates: _Copies(<String, List<Track>>{
          b.uri: <Track>[b, b2],
        }),
      );
      addTearDown(controller.dispose);
      await controller.playTracks(<Track>[a, b, c]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      // B's copy loads, reports an end, then fails to open; the other copy
      // opens fine.
      engine.failingUrls.add(_url(b));
      engine.openGate = Completer<void>();
      final Future<void> skip = controller.skipToNext();
      await _settle();
      engine.emitState(true, ProcessingState.loading);
      engine.emitState(true, ProcessingState.completed);
      await _settle();
      engine.openGate!.complete();
      engine.openGate = null;
      await skip;
      await _settle();

      expect(engine.loadedUrls, <String>[_url(a), _url(b), _url(b2)]);
      expect(completed, isEmpty,
          reason: 'the other copy has not played, let alone ended');
      expect(engine.loadedUrls, isNot(contains(_url(c))));
      expect(engine.lastTransport, 'play');
    });

    test('a seek back during the load undoes an end reported before it',
        () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a, b, c]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      // The load is moving B to its end, which it reports, when the listener
      // seeks back to 1:00.
      resolver.gate(b);
      final Future<void> skip = controller.skipToNext();
      await _settle();
      await controller.seek(const Duration(minutes: 3));
      engine.seekGate = Completer<void>();
      final Completer<void> toEnd = engine.seekGate!;
      resolver.release(b);
      await _settle();
      engine.emitDuration(const Duration(minutes: 3));
      engine.emitState(true, ProcessingState.completed);
      await _settle();
      await controller.seek(const Duration(minutes: 1));
      toEnd.complete();
      await skip;
      await _settle();

      expect(engine.calls, contains('seek:60000'));
      expect(completed, isEmpty);
      expect(controller.state.currentTrack, b);
      expect(engine.lastTransport, 'play');
    });

    test(
        'a seek back after the end, on a source with no known length, undoes '
        'the end', () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a, b, c]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      // A stream that never reports its duration: the load moves it on, it
      // reports an end, and then the listener goes back to the start.
      resolver.gate(b);
      final Future<void> skip = controller.skipToNext();
      await _settle();
      await controller.seek(const Duration(minutes: 3));
      final Completer<void> toEnd = engine.seekGate = Completer<void>();
      resolver.release(b);
      await _settle();
      engine.emitState(true, ProcessingState.completed);
      await _settle();
      await controller.seek(Duration.zero);
      toEnd.complete();
      await skip;
      await _settle();

      expect(engine.calls, contains('seek:0'));
      expect(completed, isEmpty);
      expect(controller.state.currentTrack, b);
      expect(engine.lastTransport, 'play');
    });

    test(
        'a superseded load\'s seek landing late does not undo the next '
        'source\'s end', () async {
      final Track d = _track('d');
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a, b, c, d]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      // B's load is moving it to 3:00 when the listener skips on to C.
      resolver.gate(b);
      final Future<void> toB = controller.skipToNext();
      await _settle();
      await controller.seek(const Duration(minutes: 3));
      final Completer<void> bSeek = engine.seekGate = Completer<void>();
      resolver.release(b);
      await _settle();
      final Completer<void> cOpen = engine.openGate = Completer<void>();
      final Future<void> toC = controller.skipToNext();
      await _settle();

      // C is empty: it loads, gives its length and ends while still opening.
      engine.emitState(true, ProcessingState.loading);
      engine.emitDuration(const Duration(minutes: 5));
      engine.emitState(true, ProcessingState.completed);
      await _settle();
      // Only then does B's old seek land.
      bSeek.complete();
      await toB;
      await _settle();
      engine.openGate = null;
      cOpen.complete();
      await toC;
      await _settle();

      expect(completed, <Track>[c]);
      expect(engine.loadedUrls.last, _url(d));
    });

    test(
        'an end reported during a load that then starts nothing settles paused',
        () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a, b]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      resolver.gate(b);
      final Future<void> skip = controller.skipToNext();
      await _settle();
      await controller.seek(const Duration(minutes: 3));
      engine.seekGate = Completer<void>();
      final Completer<void> toEnd = engine.seekGate!;
      resolver.release(b);
      await _settle();
      engine.emitState(true, ProcessingState.completed);
      await _settle();
      await controller.pause();
      toEnd.complete();
      await skip;
      await _settle();

      expect(controller.state.currentTrack, b);
      expect(controller.state.status, PlaybackStatus.paused,
          reason: 'not left on Loading with nothing coming');
      expect(completed, isEmpty);

      // Play flips the engine's playing flag, and the end comes again.
      await controller.play();
      engine.emitState(true, ProcessingState.completed);
      await _settle();
      expect(completed, <Track>[b]);
    });

    test('a source that reports an end and then fails to open is an error',
        () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a, b, c]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      engine.failingUrls.add(_url(b));
      engine.openGate = Completer<void>();
      final Future<void> skip = controller.skipToNext();
      await _settle();
      engine.emitState(false, ProcessingState.completed);
      await _settle();
      engine.openGate!.complete();
      await skip;
      await _settle();

      expect(controller.state.currentTrack, b,
          reason: 'B failed; it is not skipped as though it had played');
      expect(controller.state.status, PlaybackStatus.error);
      expect(completed, isEmpty);
    });

    test(
        'the new source ending while the load moves it to its start is acted '
        'on once the load settles', () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a, b, c]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      // Next, then a seek to B's very end while it still resolves. B opens,
      // and ends as the load moves it there: on an engine whose playing flag
      // never dropped, that end is the only report there will be.
      resolver.gate(b);
      final Future<void> skip = controller.skipToNext();
      await _settle();
      await controller.seek(const Duration(minutes: 3));
      final Completer<void> toEnd = engine.seekGate = Completer<void>();
      resolver.release(b);
      await _settle();
      engine.emitState(true, ProcessingState.completed);
      await _settle();
      toEnd.complete();
      await skip;
      await _settle();

      expect(completed, <Track>[b]);
      expect(controller.state.currentTrack, c);
      expect(engine.loadedUrls.last, _url(c));
    });

    test('once the new source is in the engine, its reports flow again',
        () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a, b]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();
      resolver.gate(b);
      final Future<void> skip = controller.skipToNext();
      await _settle();
      resolver.release(b);
      await skip;
      await _settle();

      engine.emitDuration(const Duration(minutes: 5));
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      expect(controller.state.status, PlaybackStatus.playing);
      expect(controller.state.duration, const Duration(minutes: 5));
    });
  });

  group('a source that fails to open takes none of the old song with it', () {
    test(
        'the old song\'s reports while the new source opened do not decide '
        'where the retry starts', () async {
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(
        player: engine,
        resolver: resolver,
        automaticRecovery: const PlaybackRecoveryPolicy(
          retryDelay: Duration.zero,
          advanceDelay: Duration.zero,
          maxAdvanceDelay: Duration.zero,
        ),
      );
      addTearDown(controller.dispose);
      await controller.playTracks(<Track>[a, b]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      // B goes to the engine, which is still opening it when A's last
      // reports come in: playing, 1:23 in, four minutes long. Then B fails to
      // open, once.
      engine.failingOnce.add(_url(b));
      engine.openGate = Completer<void>();
      final Future<void> skip = controller.skipToNext();
      await _settle();
      engine.emitState(true, ProcessingState.ready);
      engine.emitPosition(const Duration(minutes: 1, seconds: 23));
      engine.emitDuration(const Duration(minutes: 4));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      engine.openGate!.complete();
      engine.openGate = null;
      await skip;
      await _settle();

      // The automatic retry opens B from its start: B never played.
      expect(engine.loadedUrls, <String>[_url(a), _url(b), _url(b)]);
      expect(engine.calls, isNot(contains('seek:83000')));
      expect(controller.state.currentTrack, b);
      expect(controller.state.duration, isNot(const Duration(minutes: 4)));
    });

    test('a seek made while the new source opened is where the retry starts',
        () async {
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(
        player: engine,
        resolver: resolver,
        automaticRecovery: const PlaybackRecoveryPolicy(
          retryDelay: Duration.zero,
          advanceDelay: Duration.zero,
          maxAdvanceDelay: Duration.zero,
        ),
      );
      addTearDown(controller.dispose);
      await controller.playTracks(<Track>[a, b]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      // While B opens, the listener moves it to 1:30 (MPRIS, a lyric tap),
      // and A's last position comes in. Then B fails to open, once.
      engine.failingOnce.add(_url(b));
      final Completer<void> open = engine.openGate = Completer<void>();
      final Future<void> skip = controller.skipToNext();
      await _settle();
      await controller.seek(const Duration(minutes: 1, seconds: 30));
      engine.emitPosition(const Duration(minutes: 1, seconds: 23));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      engine.openGate = null;
      open.complete();
      await skip;
      await _settle();

      expect(engine.loadedUrls, <String>[_url(a), _url(b), _url(b)]);
      expect(engine.calls, contains('seek:90000'),
          reason: 'the retry starts where the listener put it');
      expect(engine.calls, isNot(contains('seek:83000')));
    });
  });

  group('a skip that fails leaves no previous song playing under it', () {
    test('the song skipped away from is silenced when the next one fails',
        () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a, b]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      resolver.down.add(b.uri);
      await controller.skipToNext();
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.currentTrack, b);
      expect(controller.state.failure, isNotNull);
      expect(engine.lastTransport, 'pause',
          reason: 'A must not go on playing under B\'s error');
    });

    test('the pause that silences it does not clear the failure', () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a, b]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      resolver.down.add(b.uri);
      await controller.skipToNext();
      engine.emitState(false, ProcessingState.ready);
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.failure, isNotNull);
    });

    test('the silenced song\'s position does not wipe the failure', () async {
      // just_audio publishes a playback event when it pauses, and its
      // position stream turns each one into a position: A's, arriving after
      // B's failure is already showing. Later ticks are A's too.
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a, b]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      resolver.down.add(b.uri);
      await controller.skipToNext();
      engine.emitPosition(const Duration(minutes: 1, seconds: 23));
      engine.emitDuration(const Duration(minutes: 4));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.failure, isNotNull,
          reason: 'the reason and its recoveries must stay on screen');
      expect(controller.state.position, Duration.zero);
      expect(controller.state.duration, isNot(const Duration(minutes: 4)));

      // Retry starts B from its own start, not from where A was.
      resolver.down.remove(b.uri);
      await controller.retryCurrentTrack();
      await _settle();
      expect(engine.loadedUrls.last, _url(b));
      expect(engine.calls, isNot(contains('seek:83000')));
    });

    test('play after a stop reloads the failed track, not the silenced one',
        () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a, b]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      resolver.down.add(b.uri);
      await controller.skipToNext();
      await _settle();
      await controller.stop();
      resolver.down.remove(b.uri);
      engine.calls.clear();

      await controller.play();
      await _settle();

      expect(engine.loadedUrls, <String>[_url(b)],
          reason: 'the engine still holds A; a bare play would resume it '
              'under B\'s title');
      expect(controller.state.currentTrack, b);
    });

    test('a load that failed in the engine has nothing earlier to silence',
        () async {
      // B's source was handed over and the engine couldn't open it: A is
      // already gone, so there is no reason to touch the transport.
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a, b]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      engine.failingUrls.add(_url(b));
      await controller.skipToNext();
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(engine.calls, isNot(contains('pause')));
    });
  });

  group('play after a stop opens the current track afresh', () {
    test('a stop that cut a load short leaves the song before it unplayed',
        () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a, b, c]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      // Next, then Stop (the notification, a media key, a remote) while B
      // still resolves. As it stops, just_audio publishes where A was.
      resolver.gate(b);
      final Future<void> skip = controller.skipToNext();
      await _settle();
      await controller.stop();
      engine.emitPosition(const Duration(minutes: 2, seconds: 13));
      resolver.release(b);
      await skip;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      engine.calls.clear();

      await controller.play();
      await _settle();

      expect(engine.loadedUrls, <String>[_url(b)],
          reason: 'the engine still holds A; resuming it would play A under '
              'B\'s title, and A\'s end would be recorded as B');
      expect(engine.calls, isNot(contains('seek:133000')),
          reason: 'nor does B start where A was');
      expect(controller.state.currentTrack, b);
    });

    test('a source that no longer opens fails rather than loading for good',
        () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a]);
      engine.emitState(true, ProcessingState.ready);
      // The queue plays out, and the listener stops.
      engine.emitState(true, ProcessingState.completed);
      await _settle();
      await controller.stop();

      // By the time they press Play the server is out of reach, so the URL
      // the engine kept no longer opens either.
      resolver.down.add(a.uri);
      engine.failingUrls.add(_url(a));
      await controller.play();
      await _settle();

      expect(controller.state.status, PlaybackStatus.error,
          reason: 'reopening what the engine kept fails where nothing hears '
              'it, and Loading would never end');
    });
  });

  group('a source ends once', () {
    test('pausing after the queue ran out does not record the track again',
        () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a]);
      engine.emitState(true, ProcessingState.ready);
      engine.emitState(true, ProcessingState.completed);
      await _settle();
      expect(controller.state.status, PlaybackStatus.completed);
      expect(completed, <Track>[a]);

      // An unplug or a focus loss pauses the finished engine.
      engine.emitState(false, ProcessingState.completed);
      engine.emitState(true, ProcessingState.completed);
      await _settle();

      expect(completed, <Track>[a]);
    });

    test('repeat-one still replays every time the track ends', () async {
      final JustAudioPlaybackController controller = build();
      controller.setRepeatMode(RepeatMode.one);
      await controller.playTracks(<Track>[a]);
      engine.emitState(true, ProcessingState.ready);

      for (int loop = 0; loop < 3; loop++) {
        // An engine that goes straight from one end to the next, with nothing
        // reported between the seek back and the end.
        engine.emitState(true, ProcessingState.completed);
        await _settle();
      }

      expect(completed, <Track>[a, a, a]);
      expect(
        engine.calls.where((String call) => call == 'seek:0').length,
        3,
      );
    });

    test(
        'a seek back after the end counts the next end, even with nothing '
        'reported in between', () async {
      // An engine that stays on completed across the seek (media_kit can),
      // as in the repeat-one replay above.
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a]);
      engine.emitState(true, ProcessingState.ready);
      engine.emitState(true, ProcessingState.completed);
      await _settle();

      await controller.seek(const Duration(minutes: 2));
      engine.emitState(true, ProcessingState.completed);
      await _settle();

      expect(completed, <Track>[a, a]);
    });

    test(
        'a repeat-one replay on an engine that stays on completed reads as '
        'playing, not as a stalled stream', () async {
      final JustAudioPlaybackController controller = build()
        // A watchdog left armed would fire within the settle below.
        ..midStreamBufferingTimeout = Duration.zero
        ..streamRetryBackoff = Duration.zero;
      controller.setRepeatMode(RepeatMode.one);
      await controller.playTracks(<Track>[a]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      // How the Linux engine ends a source (observed with libmpv 2.2):
      // libmpv goes idle at the end of the file, which media_kit reports as
      // buffering, then the end. It stays on completed across the rewind, so
      // nothing more is reported while the replay plays.
      engine.emitState(true, ProcessingState.buffering);
      engine.emitState(true, ProcessingState.completed);
      await _settle();

      expect(completed, <Track>[a]);
      expect(engine.calls.where((String call) => call == 'seek:0').length, 1);
      expect(engine.loadedUrls, <String>[_url(a)],
          reason: 'the end was not a stall to reconnect from');
      expect(controller.state.status, PlaybackStatus.playing,
          reason: 'the replay is playing, not buffering');
    });

    test('a pause during the repeat-one rewind does not end the track again',
        () async {
      final JustAudioPlaybackController controller = build();
      controller.setRepeatMode(RepeatMode.one);
      await controller.playTracks(<Track>[a]);
      engine.emitState(true, ProcessingState.ready);
      await _settle();

      // The end starts the rewind; a pause lands before it does, on an engine
      // still reporting completed.
      final Completer<void> rewind = engine.seekGate = Completer<void>();
      engine.emitState(true, ProcessingState.completed);
      await _settle();
      await controller.pause();
      engine.emitState(false, ProcessingState.completed);
      await _settle();
      rewind.complete();
      await _settle();

      expect(completed, <Track>[a]);
      expect(
        engine.calls.where((String call) => call == 'seek:0').length,
        1,
      );
    });

    test('a seek to where the track already ended does not end it again',
        () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a]);
      engine.emitState(true, ProcessingState.ready);
      engine.emitDuration(const Duration(minutes: 3));
      engine.emitState(true, ProcessingState.completed);
      await _settle();

      // The progress bar or MPRIS SetPosition at the end, on an engine that
      // re-sends its unchanged completed state.
      await controller.seek(const Duration(minutes: 3));
      engine.emitState(true, ProcessingState.completed);
      await _settle();

      expect(completed, <Track>[a]);
    });

    test(
        'a seek to the end that passes through ready does not end the track '
        'again', () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a]);
      engine.emitState(true, ProcessingState.ready);
      engine.emitDuration(const Duration(minutes: 3));
      engine.emitState(true, ProcessingState.completed);
      await _settle();

      await controller.seek(const Duration(minutes: 3));
      engine.emitState(true, ProcessingState.ready);
      engine.emitState(true, ProcessingState.completed);
      await _settle();

      expect(completed, <Track>[a]);
    });

    test(
        'a seek to the end while a finished track reopens sends it to its '
        'end', () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a]);
      engine.emitState(true, ProcessingState.ready);
      engine.emitDuration(const Duration(minutes: 3));
      engine.emitState(true, ProcessingState.completed);
      await _settle();

      // The seek back opens the finished track again, at its spot; the newer
      // seek to the end reaches that load before it starts.
      engine.seekGate = Completer<void>();
      final Completer<void> back = engine.seekGate!;
      final Future<void> seekBack = controller.seek(const Duration(minutes: 1));
      await _settle();
      await controller.seek(const Duration(minutes: 3));
      back.complete();
      await seekBack;
      await _settle();

      expect(
        engine.calls.where((String call) => call.startsWith('seek:')).last,
        'seek:180000',
        reason: 'the newer seek is where the reopened track goes',
      );
      // That fresh source then ends where it was sent, and the end is its own.
      engine.emitState(true, ProcessingState.completed);
      await _settle();
      expect(controller.state.status, PlaybackStatus.completed);
      expect(completed, <Track>[a, a]);
    });

    test('a seek back after the end lets the next end count', () async {
      final JustAudioPlaybackController controller = build();
      await controller.playTracks(<Track>[a]);
      engine.emitState(true, ProcessingState.ready);
      engine.emitState(true, ProcessingState.completed);
      await _settle();

      await controller.seek(const Duration(minutes: 2));
      engine.emitState(true, ProcessingState.ready);
      engine.emitState(true, ProcessingState.completed);
      await _settle();

      expect(completed, <Track>[a, a]);
    });
  });
}
