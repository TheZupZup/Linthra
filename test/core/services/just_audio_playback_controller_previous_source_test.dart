import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';

/// An engine whose state, position and duration streams the test drives by
/// hand, recording every transport call in order. Like just_audio, it goes on
/// holding (and reporting) the previous source until a new one is opened.
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
    if (failingUrls.contains(url)) throw Exception('could not open source');
    return const Duration(minutes: 3);
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> seek(Duration? position, {int? index}) async =>
      calls.add('seek:${position?.inMilliseconds}');
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
