import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';

/// A fake engine that records the volume/play/pause traffic the controller's
/// audio-focus handling drives, with no platform channel. An injected player
/// turns off the controller's own audio_session wiring, so the test pumps focus
/// events straight into [JustAudioPlaybackController.onAudioInterruption].
class _RecordingPlayer extends Fake implements AudioPlayer {
  final List<double> volumes = <double>[];
  int playCalls = 0;
  int pauseCalls = 0;

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
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<void> play() async => playCalls++;
  @override
  Future<void> pause() async => pauseCalls++;
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

/// Flushes the unawaited `setVolume`/`play`/`pause` continuations the handler
/// fires so the test can observe them.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

AudioInterruptionEvent _begin(AudioInterruptionType type) =>
    AudioInterruptionEvent(true, type);
AudioInterruptionEvent _end(AudioInterruptionType type) =>
    AudioInterruptionEvent(false, type);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The field bug: with music playing, opening another app (e.g. ChatGPT)
  // grabs a duckable transient focus and Linthra goes silent and never
  // recovers. These exercise the controller's focus handling end to end via a
  // recording fake engine: a duck lowers (but never silences) the volume, and
  // any regain/unduck always restores it — so Linthra can never be left
  // muted/ducked once focus returns.
  group('audio focus duck/restore lifecycle', () {
    _RecordingPlayer player() => _RecordingPlayer();

    test('a duckable transient lowers the volume but keeps playing', () async {
      final p = player();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.duck));
      await _settle();

      expect(controller.isDuckedForTesting, isTrue);
      expect(p.volumes.last, lessThan(1.0),
          reason: 'a duckable transient attenuates the engine volume');
      expect(p.volumes.last, greaterThan(0.0),
          reason: 'ducking must stay audible, never silence');
      expect(p.pauseCalls, 0, reason: 'a duck keeps playing, never pauses');
    });

    test('the duck ending restores full volume', () async {
      final p = player();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.duck));
      await _settle();
      controller.onAudioInterruption(_end(AudioInterruptionType.duck));
      await _settle();

      expect(controller.isDuckedForTesting, isFalse);
      expect(p.volumes.last, 1.0, reason: 'the unduck restores full volume');
    });

    test('a focus regain restores volume even after a duck (never stays muted)',
        () async {
      final p = player();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      // Duck, then a bare GAIN arrives (the duck-end was never delivered): the
      // regain itself must still lift the duck.
      controller.onAudioInterruption(_begin(AudioInterruptionType.duck));
      await _settle();
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();

      expect(controller.isDuckedForTesting, isFalse);
      expect(p.volumes.last, 1.0,
          reason: 'a regain must lift a lingering duck so we are never muted');
    });
  });

  group('audio focus pause/resume only on a transient loss', () {
    test('a transient loss pauses, and the matching regain resumes', () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _settle();
      expect(p.pauseCalls, 1, reason: 'a transient loss pauses');

      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();
      expect(p.playCalls, 1,
          reason: 'the matching regain resumes a focus-loss pause');
    });

    test('a permanent loss pauses and a later regain does NOT resume',
        () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.unknown));
      await _settle();
      expect(p.pauseCalls, 1, reason: 'a permanent loss pauses');

      controller.onAudioInterruption(_end(AudioInterruptionType.unknown));
      await _settle();
      expect(p.playCalls, 0,
          reason: 'a permanent loss must stay paused on return — no resume');
    });

    test('a bare regain with nothing armed does not start playback', () async {
      // The screen-wake / app-return case: focus comes back but no transient
      // loss armed a resume, so Linthra must not start playing by itself.
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);

      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();

      expect(p.playCalls, 0);
    });

    test('a transient loss while already paused does not resume on regain',
        () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      // Engine is paused (not playing) when the loss arrives.
      controller.handleEngineState(PlayerState(false, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _settle();
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();

      expect(p.playCalls, 0,
          reason: 'only a loss that interrupted active playback resumes');
    });
  });
}
