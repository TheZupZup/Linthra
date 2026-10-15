// A stall the listener resumes into is still bounded by the watchdog.
//
// The mid-stream buffering watchdog was armed only when buffering followed
// `playing` (JustAudioPlaybackController.handleEngineState). A stream that
// stalled after the listener resumed it from a pause, or after a paused seek,
// was never watched, so an engine that never raises an error left the player
// on "Buffering…" for good, with the media session still reporting playing.
// Driven on the real 30 s bound, in fake time.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';

/// An engine that reports nothing on its own: the test drives every state
/// through [JustAudioPlaybackController.handleEngineState], as a stalled
/// connection that never errors would leave it.
class _SilentPlayer extends Fake implements AudioPlayer {
  final List<String> setUrlCalls = <String>[];
  int playCalls = 0;

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
  Future<void> dispose() async {}
}

class _Resolver implements PlayableUriResolver {
  final List<String> calls = <String>[];

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    calls.add(track.uri);
    return ResolvedPlayable(
      Uri.parse('https://server.example/stream/${track.id}?n=${calls.length}'),
      PlaybackSource.streamingDirect,
    );
  }
}

/// Disposes [controller] inside the test body, so no timer of its outlives the
/// test. Awaiting dispose itself would wait on the fake clock for good.
Future<void> _dispose(
  WidgetTester tester,
  JustAudioPlaybackController controller,
) async {
  unawaited(controller.dispose());
  await tester.pump();
}

const Track _song = Track(
  id: 'j',
  title: 'Song',
  uri: 'jellyfin:j',
  duration: Duration(minutes: 3),
);

void main() {
  // The production watchdog bound (30 s), driven on virtual time.
  const Duration watchdog = Duration(seconds: 30);

  testWidgets(
      'path A: a stall resumed after a long pause is still bounded by the '
      'watchdog', (WidgetTester tester) async {
    final _SilentPlayer player = _SilentPlayer();
    final _Resolver resolver = _Resolver();
    final JustAudioPlaybackController controller = JustAudioPlaybackController(
      player: player,
      resolver: resolver,
    )..streamRetryBackoff = Duration.zero;
    await controller.playTracks(<Track>[_song]);
    controller.handleEngineState(PlayerState(true, ProcessingState.ready));
    expect(controller.state.status, PlaybackStatus.playing);

    // The connection stalls mid-song.
    controller.handleEngineState(PlayerState(true, ProcessingState.buffering));
    expect(controller.state.status, PlaybackStatus.buffering);

    // The listener pauses during the stall and stays paused past the bound.
    await controller.pause();
    controller.handleEngineState(PlayerState(false, ProcessingState.buffering));
    expect(controller.state.status, PlaybackStatus.loading);
    await tester.pump(watchdog * 2);

    // They press Play; the engine goes on buffering and never errors.
    await controller.play();
    controller.handleEngineState(PlayerState(true, ProcessingState.buffering));
    expect(controller.state.status, PlaybackStatus.buffering);
    await tester.pump(watchdog * 4);

    final PlaybackState stuck = controller.state;
    await _dispose(tester, controller);
    expect(resolver.calls, hasLength(greaterThan(1)),
        reason: 'the dead stream is never reconnected');
    expect(stuck.status, isNot(PlaybackStatus.buffering),
        reason: '"Buffering…" (reported as playing) for good');
  });

  testWidgets(
      'path B: a stall after a paused seek and Play is still bounded by the '
      'watchdog', (WidgetTester tester) async {
    final _SilentPlayer player = _SilentPlayer();
    final _Resolver resolver = _Resolver();
    final JustAudioPlaybackController controller = JustAudioPlaybackController(
      player: player,
      resolver: resolver,
    )..streamRetryBackoff = Duration.zero;
    await controller.playTracks(<Track>[_song]);
    controller.handleEngineState(PlayerState(true, ProcessingState.ready));

    // Paused, then a seek into a part of the stream that is not buffered.
    await controller.pause();
    controller.handleEngineState(PlayerState(false, ProcessingState.ready));
    expect(controller.state.status, PlaybackStatus.paused);
    await controller.seek(const Duration(minutes: 2));
    controller.handleEngineState(PlayerState(false, ProcessingState.buffering));
    expect(controller.state.status, PlaybackStatus.loading);

    // Play: the engine buffers and the server never answers or errors.
    await controller.play();
    controller.handleEngineState(PlayerState(true, ProcessingState.buffering));
    expect(controller.state.status, PlaybackStatus.buffering);
    await tester.pump(watchdog * 4);

    final PlaybackState stuck = controller.state;
    await _dispose(tester, controller);
    expect(resolver.calls, hasLength(greaterThan(1)),
        reason: 'the dead stream is never reconnected');
    expect(stuck.status, isNot(PlaybackStatus.buffering),
        reason: '"Buffering…" (reported as playing) for good');
  });

  testWidgets('the first load of a track is still left to its own timeout',
      (WidgetTester tester) async {
    // Buffering before the track has ever played is the load, not a stall:
    // the watchdog stays out of it.
    final _SilentPlayer player = _SilentPlayer();
    final _Resolver resolver = _Resolver();
    final JustAudioPlaybackController controller = JustAudioPlaybackController(
      player: player,
      resolver: resolver,
    )..streamRetryBackoff = Duration.zero;
    await controller.playTracks(<Track>[_song]);
    controller.handleEngineState(PlayerState(true, ProcessingState.buffering));
    await tester.pump(watchdog + const Duration(seconds: 1));

    final int resolves = resolver.calls.length;
    await _dispose(tester, controller);
    expect(resolves, 1);
  });

  testWidgets('control: the same stall straight from playing IS bounded',
      (WidgetTester tester) async {
    final _SilentPlayer player = _SilentPlayer();
    final _Resolver resolver = _Resolver();
    final JustAudioPlaybackController controller = JustAudioPlaybackController(
      player: player,
      resolver: resolver,
    )..streamRetryBackoff = Duration.zero;
    await controller.playTracks(<Track>[_song]);
    controller.handleEngineState(PlayerState(true, ProcessingState.ready));
    controller.handleEngineState(PlayerState(true, ProcessingState.buffering));
    await tester.pump(watchdog + const Duration(seconds: 1));

    final int resolves = resolver.calls.length;
    await _dispose(tester, controller);
    expect(resolves, 2, reason: 'the watchdog reconnects a playing stall');
  });
}
