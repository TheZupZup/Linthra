import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_failure.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/stream_interruption.dart';

/// An engine whose position and duration the test drives, recording seeks and
/// play calls.
class _Engine extends Fake implements AudioPlayer {
  final StreamController<Duration> _positions =
      StreamController<Duration>.broadcast();
  final StreamController<Duration?> _durations =
      StreamController<Duration?>.broadcast();

  final List<Duration?> seeks = <Duration?>[];
  int plays = 0;

  void emitPosition(Duration position) => _positions.add(position);
  void emitDuration(Duration duration) => _durations.add(duration);

  @override
  Stream<PlayerState> get playerStateStream =>
      const Stream<PlayerState>.empty();
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
  }) async =>
      const Duration(minutes: 3);

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> play() async => plays++;
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration? position, {int? index}) async =>
      seeks.add(position);
  @override
  Future<void> dispose() async {
    await _positions.close();
    await _durations.close();
  }
}

/// Resolves every track except the ones marked down.
class _Resolver implements PlayableUriResolver {
  final Set<String> down = <String>{};

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    if (down.contains(track.uri)) {
      throw const PlaybackResolutionException(
        "Couldn't reach your music server.",
        kind: PlaybackResolutionErrorKind.serverUnreachable,
      );
    }
    return ResolvedPlayable(
      Uri.parse('https://host/stream/${track.id}'),
      PlaybackSource.streamingDirect,
    );
  }
}

Track _track(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');

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

  /// A controller whose only track, [a], has failed to load.
  Future<JustAudioPlaybackController> failedOnA({
    List<Track> queue = const <Track>[],
  }) async {
    final JustAudioPlaybackController controller =
        JustAudioPlaybackController(player: engine, resolver: resolver);
    addTearDown(controller.dispose);
    resolver.down.add(a.uri);
    await controller.playTracks(<Track>[a, ...queue]);
    expect(controller.state.status, PlaybackStatus.error);
    expect(controller.state.failure, isNotNull);
    return controller;
  }

  setUp(() {
    engine = _Engine();
    resolver = _Resolver();
  });

  group('the error panel keeps its reason and recoveries', () {
    test('through queue edits and mode toggles', () async {
      final JustAudioPlaybackController controller =
          await failedOnA(queue: <Track>[b, c]);

      controller.setShuffleEnabled(true);
      expect(controller.state.failure, isNotNull, reason: 'shuffle');
      controller.setShuffleEnabled(false);
      controller.setRepeatMode(RepeatMode.all);
      expect(controller.state.failure, isNotNull, reason: 'repeat');
      controller.addToQueue(_track('d'));
      expect(controller.state.failure, isNotNull, reason: 'add to queue');
      controller.playNext(_track('e'));
      expect(controller.state.failure, isNotNull, reason: 'play next');
      controller.reorderQueue(0, 2);
      expect(controller.state.failure, isNotNull, reason: 'reorder');
      controller.removeFromQueue(0);
      expect(controller.state.failure, isNotNull, reason: 'remove');
      controller.clearQueue();
      expect(controller.state.failure, isNotNull, reason: 'clear queue');

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.currentTrack, a);
    });

    test('through a late position or duration report', () async {
      final JustAudioPlaybackController controller = await failedOnA();

      engine.emitDuration(const Duration(minutes: 4));
      engine.emitPosition(const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.failure, isNotNull);
    });

    test('Skip appears once there is something to skip to, and goes again',
        () async {
      final JustAudioPlaybackController controller = await failedOnA();
      expect(controller.state.failure!.canSkip, isFalse);

      controller.addToQueue(b);
      expect(controller.state.failure!.canSkip, isTrue);
      expect(
        controller.state.failure!.actions,
        contains(PlaybackRecoveryAction.skip),
      );

      controller.removeFromQueue(0);
      expect(controller.state.failure!.canSkip, isFalse);
    });

    test('and lets go of them once something plays', () async {
      final JustAudioPlaybackController controller = await failedOnA();
      resolver.down.clear();

      await controller.retryCurrentTrack();
      await _settle();

      expect(controller.state.status, isNot(PlaybackStatus.error));
      expect(controller.state.failure, isNull);
    });
  });

  group('a settled failure keeps where the track stopped', () {
    test('Retry resumes a mid-song failure from where it stopped', () async {
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(player: engine, resolver: resolver)
            ..streamRetryBackoff = Duration.zero;
      addTearDown(controller.dispose);
      await controller.playTracks(<Track>[a]);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));
      controller.setPositionForTesting(const Duration(seconds: 42));

      // The stream drops, and the server is gone for the quick reconnect too.
      resolver.down.add(a.uri);
      await controller.handleStreamFailureForTestingAsync(
        const StreamInterruption(
          StreamInterruptionKind.networkDropped,
          'The connection dropped while streaming.',
          retryable: true,
        ),
      );
      await _settle();
      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.position, const Duration(seconds: 42));

      resolver.down.clear();
      await controller.retryCurrentTrack();
      await _settle();

      expect(engine.seeks.last, const Duration(seconds: 42),
          reason: 'Retry picks the song up where it stopped, not at 0:00');
    });

    test('a track that failed before playing starts from the top', () async {
      final JustAudioPlaybackController controller = await failedOnA();
      expect(controller.state.position, Duration.zero);

      resolver.down.clear();
      await controller.retryCurrentTrack();
      await _settle();

      expect(engine.seeks, isEmpty);
    });
  });
}
