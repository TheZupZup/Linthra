import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_candidate_source.dart';

/// An engine with ExoPlayer's timing (#831): a load reports ready, already
/// playing if the listener wanted sound, before `setUrl` returns, and once a
/// source plays nothing more is reported but position ticks.
class _AndroidLikePlayer extends Fake implements AudioPlayer {
  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast(sync: true);
  final StreamController<Duration> _positions =
      StreamController<Duration>.broadcast(sync: true);
  final StreamController<PlaybackEvent> _events =
      StreamController<PlaybackEvent>.broadcast(sync: true);

  final List<String> opened = <String>[];
  bool _playing = false;

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;
  @override
  Stream<Duration> get positionStream => _positions.stream;
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
    _states.add(PlayerState(_playing, ProcessingState.loading));
    // READY lands while the load is still in flight.
    _states.add(PlayerState(_playing, ProcessingState.ready));
    await Future<void>.delayed(Duration.zero);
    return const Duration(minutes: 6);
  }

  @override
  Future<void> play() async {
    if (_playing) return;
    _playing = true;
    _states.add(PlayerState(true, ProcessingState.ready));
  }

  @override
  Future<void> pause() async {
    if (!_playing) return;
    _playing = false;
    _states.add(PlayerState(false, ProcessingState.ready));
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration? position, {int? index}) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() async {}

  /// Plays on from [from] for [length], ticking four times a second the way
  /// just_audio's position stream does.
  Duration playOn(Duration from, Duration length) {
    const Duration tick = Duration(milliseconds: 250);
    Duration position = from;
    final Duration end = from + length;
    while (position < end) {
      position += tick;
      _positions.add(position);
    }
    return position;
  }

  /// A seek, or a reload landing somewhere else: one jump in position.
  void jumpTo(Duration position) => _positions.add(position);

  /// The stream dies under ExoPlayer: a source error on the event stream.
  void dropStream() => _events.addError(
        PlayerException(0, 'Source error: connection reset', null),
        StackTrace.empty,
      );
}

class _CountingResolver implements PlayableUriResolver {
  int resolves = 0;

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    resolves++;
    return ResolvedPlayable(
      Uri.parse('https://server.example/stream/${track.id}?n=$resolves'),
      PlaybackSource.streamingDirect,
    );
  }
}

const Track _track = Track(id: '7', title: 'Long Song', uri: 'jellyfin:7');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _AndroidLikePlayer player;
  late _CountingResolver resolver;
  late JustAudioPlaybackController controller;

  setUp(() async {
    player = _AndroidLikePlayer();
    resolver = _CountingResolver();
    controller = JustAudioPlaybackController(
      player: player,
      resolver: resolver,
      candidates: const NoFallbackCandidateSource(),
    )
      ..streamRetryBackoff = Duration.zero
      // Long enough never to fire here: the drops are explicit.
      ..midStreamBufferingTimeout = const Duration(hours: 1);
    addTearDown(controller.dispose);
    await controller.playTracks(<Track>[_track]);
    await pumpEventQueue();
    expect(controller.state.status, PlaybackStatus.playing);
  });

  /// Drops the stream and lets the recovery settle.
  Future<void> drop() async {
    player.dropStream();
    await pumpEventQueue();
  }

  test('a drop straight after a reconnect gives up instead of looping',
      () async {
    final Duration at =
        player.playOn(Duration.zero, const Duration(minutes: 1));
    await drop();
    expect(resolver.resolves, 2, reason: 'the first drop reconnects');
    expect(controller.state.status, PlaybackStatus.playing);

    // The reloaded stream lands and dies again at once.
    player.jumpTo(at);
    await drop();

    expect(resolver.resolves, 2);
    expect(controller.state.status, PlaybackStatus.error);
  });

  test('a drop after a stretch of healthy playback reconnects quickly again',
      () async {
    Duration at = player.playOn(Duration.zero, const Duration(minutes: 1));
    await drop();
    expect(resolver.resolves, 2);

    // The reconnect worked: the track plays on for a good while, without
    // the engine reporting anything but position.
    player.jumpTo(at);
    at = player.playOn(at, const Duration(seconds: 45));
    await drop();

    expect(resolver.resolves, 3, reason: 'an independent drop reconnects');
    expect(controller.state.status, PlaybackStatus.playing);

    // That reconnect is spent in turn: dropping again at once gives up.
    player.jumpTo(at);
    await drop();
    expect(resolver.resolves, 3);
    expect(controller.state.status, PlaybackStatus.error);
  });

  test('a few seconds of sound after the reconnect are not enough', () async {
    Duration at = player.playOn(Duration.zero, const Duration(minutes: 1));
    await drop();

    player.jumpTo(at);
    at = player.playOn(at, const Duration(seconds: 10));
    await drop();

    expect(resolver.resolves, 2);
    expect(controller.state.status, PlaybackStatus.error);
  });

  test('a seek forward is not playback', () async {
    final Duration at =
        player.playOn(Duration.zero, const Duration(minutes: 1));
    await drop();

    // The listener skips three minutes ahead: one big jump, no playback.
    player.jumpTo(at);
    player.jumpTo(at + const Duration(minutes: 3));
    player.playOn(at + const Duration(minutes: 3), const Duration(seconds: 1));
    await drop();

    expect(resolver.resolves, 2);
    expect(controller.state.status, PlaybackStatus.error);
  });

  test('a seek back keeps counting from where it landed', () async {
    Duration at = player.playOn(Duration.zero, const Duration(minutes: 2));
    await drop();

    player.jumpTo(at);
    at = player.playOn(at, const Duration(seconds: 20));
    // Back to the start of the track, then on for another 20 seconds: 40
    // seconds of real playback in all.
    player.jumpTo(Duration.zero);
    player.playOn(Duration.zero, const Duration(seconds: 20));
    await drop();

    expect(resolver.resolves, 3);
    expect(controller.state.status, PlaybackStatus.playing);
  });

  test('time spent paused does not count', () async {
    final Duration at =
        player.playOn(Duration.zero, const Duration(minutes: 1));
    await drop();
    player.jumpTo(at);

    await controller.pause();
    await pumpEventQueue();
    // A paused engine can still repeat its position; none of it is playback.
    for (int i = 0; i < 200; i++) {
      player.jumpTo(at);
    }
    await controller.play();
    await pumpEventQueue();
    await drop();

    expect(resolver.resolves, 2);
    expect(controller.state.status, PlaybackStatus.error);
  });

  test('playback before the drop does not pay for the reconnect', () async {
    // Ten minutes of healthy playback, then a drop: the reconnect is spent
    // from here on, whatever came before.
    final Duration at =
        player.playOn(Duration.zero, const Duration(minutes: 10));
    await drop();
    player.jumpTo(at);
    await drop();

    expect(resolver.resolves, 2);
    expect(controller.state.status, PlaybackStatus.error);
  });
}
