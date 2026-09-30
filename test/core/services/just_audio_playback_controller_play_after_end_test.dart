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
  final List<String> loaded = <String>[];
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
    loaded.add(url);
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
  Future<void> seek(Duration? position, {int? index}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async => _states.close();
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
