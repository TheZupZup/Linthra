import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';

/// An engine that keeps just_audio's rule the controller has to live with:
/// `playing` stays true after the source reaches its end, and `play()` does
/// nothing while it is true. So at the end of a queue, pressing Play on the
/// engine alone changes nothing at all.
class _JustAudioLikeEngine extends Fake implements AudioPlayer {
  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast();
  final StreamController<Duration?> _durations =
      StreamController<Duration?>.broadcast();
  final List<String> loaded = <String>[];
  final List<Duration?> seeks = <Duration?>[];

  /// When set, the next seek waits on it before it lands.
  Completer<void>? seekGate;
  bool _playing = false;
  ProcessingState _processing = ProcessingState.idle;

  /// The loaded source reaching its end.
  void finish() {
    _processing = ProcessingState.completed;
    _states.add(PlayerState(_playing, _processing));
  }

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;
  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();
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
    loaded.add(url);
    _durations.add(const Duration(minutes: 3));
    _processing = ProcessingState.ready;
    _states.add(PlayerState(_playing, _processing));
    return const Duration(minutes: 3);
  }

  @override
  Future<void> play() async {
    if (_playing) return;
    _playing = true;
    _states.add(PlayerState(_playing, _processing));
  }

  @override
  Future<void> pause() async {
    _playing = false;
    _states.add(PlayerState(_playing, _processing));
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> seek(Duration? position, {int? index}) async {
    seeks.add(position);
    final Completer<void>? gate = seekGate;
    seekGate = null;
    if (gate != null) await gate.future;
    // Like media_kit, the engine can stay on completed across a seek back:
    // nothing is reported until the source ends again.
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {
    await _states.close();
    await _durations.close();
  }
}

class _Resolver implements PlayableUriResolver {
  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async => ResolvedPlayable(
        Uri.parse('file:///music/${track.id}'),
        PlaybackSource.localFile,
      );
}

Track _track(String id) => Track(id: id, title: id, uri: '/music/$id');

Future<void> _settle() async {
  for (int i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final Track a = _track('a');
  final Track b = _track('b');

  late _JustAudioLikeEngine engine;
  late JustAudioPlaybackController controller;

  /// Plays [a, b] through to the end of the queue.
  Future<void> playToTheEnd() async {
    await controller.playTracks(<Track>[a, b]);
    await _settle();
    engine.finish();
    await _settle();
    expect(controller.state.currentTrack, b);
    engine.finish();
    await _settle();
    expect(controller.state.status, PlaybackStatus.completed);
  }

  setUp(() {
    engine = _JustAudioLikeEngine();
    controller = JustAudioPlaybackController(
      player: engine,
      resolver: _Resolver(),
    );
    addTearDown(controller.dispose);
  });

  test('Play after the queue ran out starts it again from the top', () async {
    await playToTheEnd();

    await controller.play();
    await _settle();

    expect(engine.loaded.last, 'file:///music/a',
        reason: 'Play did nothing: the engine still reported playing');
    expect(controller.state.currentTrack, a);
    expect(controller.state.status, PlaybackStatus.playing);
    expect(controller.state.hasPrevious, isFalse);
    expect(controller.state.upNext, <Track>[b]);
  });

  test('Play after the end plays what was queued since, not the top', () async {
    final Track c = _track('c');
    await playToTheEnd();
    controller.playNext(c);
    await _settle();
    expect(controller.state.status, PlaybackStatus.completed);

    await controller.play();
    await _settle();

    expect(engine.loaded.last, 'file:///music/c');
    expect(controller.state.currentTrack, c);
    expect(controller.state.status, PlaybackStatus.playing);
    expect(controller.state.previous, <Track>[a, b]);
  });

  test('a track added to the queue after the end plays next too', () async {
    final Track c = _track('c');
    await playToTheEnd();
    controller.addToQueue(c);
    await _settle();

    await controller.play();
    await _settle();

    expect(engine.loaded.last, 'file:///music/c');
    expect(controller.state.currentTrack, c);
    expect(controller.state.status, PlaybackStatus.playing);
  });

  test('Play after a seek back into the finished track resumes it there',
      () async {
    await playToTheEnd();
    final int loads = engine.loaded.length;

    await controller.seek(const Duration(minutes: 1));
    await _settle();
    await controller.play();
    await _settle();

    expect(engine.loaded.length, loads,
        reason: 'the listener chose a spot in this track, not a restart');
    expect(controller.state.currentTrack, b);
    expect(engine.seeks, <Duration?>[const Duration(minutes: 1)]);
  });

  test('Play sent right behind a seek back waits for it, not the top',
      () async {
    // `playerctl position 0; playerctl play`, or any client sending the two
    // back to back: Play arrives before the seek has landed.
    await playToTheEnd();
    final int loads = engine.loaded.length;
    final Completer<void> landing = engine.seekGate = Completer<void>();

    final Future<void> seeking = controller.seek(Duration.zero);
    await controller.play();
    landing.complete();
    await seeking;
    await _settle();

    expect(engine.loaded.length, loads);
    expect(controller.state.currentTrack, b);
  });

  test('a track that ends again after a seek back is a finished queue again',
      () async {
    await playToTheEnd();
    await controller.seek(const Duration(minutes: 1));
    await _settle();
    engine.finish();
    await _settle();
    expect(controller.state.status, PlaybackStatus.completed);

    await controller.play();
    await _settle();

    expect(engine.loaded.last, 'file:///music/a',
        reason: 'Play did nothing: the old seek back was taken as current');
    expect(controller.state.currentTrack, a);
  });

  test('Play after a seek to the very end still starts the queue over',
      () async {
    await playToTheEnd();

    await controller.seek(const Duration(minutes: 3));
    await _settle();
    await controller.play();
    await _settle();

    expect(engine.loaded.last, 'file:///music/a');
    expect(controller.state.currentTrack, a);
  });

  test('the restarted queue keeps shuffle and repeat as they were', () async {
    controller.setShuffleEnabled(true);
    await playToTheEnd();
    final List<Track> order = <Track>[
      ...controller.state.previous,
      controller.state.currentTrack!,
    ];

    await controller.play();
    await _settle();

    expect(controller.state.shuffleEnabled, isTrue);
    expect(controller.state.currentTrack, order.first,
        reason: 'the same order again, not a reshuffle nobody asked for');
    expect(controller.state.repeatMode, RepeatMode.off);
  });

  test('Play while paused mid-track still just resumes', () async {
    await controller.playTracks(<Track>[a, b]);
    await _settle();
    await controller.pause();
    await _settle();
    final int loads = engine.loaded.length;

    await controller.play();
    await _settle();

    expect(engine.loaded.length, loads, reason: 'no reload for a resume');
    expect(controller.state.currentTrack, a);
    expect(controller.state.status, PlaybackStatus.playing);
  });
}
