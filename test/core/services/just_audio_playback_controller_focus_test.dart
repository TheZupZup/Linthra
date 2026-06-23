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

/// A short transient-loss debounce so a scheduled pause fires quickly in tests.
const Duration _testDebounce = Duration(milliseconds: 10);

/// Waits past [_testDebounce] so a scheduled transient-loss pause has fired.
Future<void> _pastDebounce() =>
    Future<void>.delayed(const Duration(milliseconds: 40));

AudioInterruptionEvent _begin(AudioInterruptionType type) =>
    AudioInterruptionEvent(true, type);
AudioInterruptionEvent _end(AudioInterruptionType type) =>
    AudioInterruptionEvent(false, type);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The field bug: with music playing, any other app grabbing a duckable
  // transient focus left Linthra silent and never recovering.
  // These exercise the controller's focus handling end to end via a
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
    test('a sustained transient loss pauses, and the regain resumes', () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      // The loss outlasts the debounce window, so it really pauses.
      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce();
      expect(p.pauseCalls, 1, reason: 'a sustained transient loss pauses');

      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();
      expect(p.playCalls, 1,
          reason: 'the matching regain resumes a focus-loss pause');
    });

    test('a brief transient loss blip is absorbed (never pauses)', () async {
      // The screen-off / Doze churn case: a transient loss immediately followed
      // by a regain must NOT pause — pausing would demote the foreground media
      // service and risk the OS freezing background playback with the screen off.
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _pastDebounce();

      expect(p.pauseCalls, 0,
          reason: 'a loss cancelled by a quick regain must never pause');
      expect(p.playCalls, 0, reason: 'never paused, so nothing to resume');
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

  group('voice session: repeated transient losses still resume on regain', () {
    // The remaining field bug: a single voice/mic session in another app emits
    // *several* transient losses back to back (may-duck focus on open, then
    // exclusive mic/voice focus — both surface as transient pauses with the
    // session set to pause-when-ducked). The 2nd loss must not disarm the resume
    // by observing the already-paused state, or the regain at the end never
    // restores sound.
    test('two sustained transient losses then one regain resume playback',
        () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      // First loss outlasts the debounce and pauses; simulate the engine going
      // paused.
      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce();
      controller.handleEngineState(PlayerState(false, ProcessingState.ready));

      // Second loss arrives while already paused — must keep the resume armed.
      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce();

      // Voice ends: a single regain must resume.
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();

      expect(p.playCalls, 1,
          reason: 'a repeated transient loss must not disarm the resume');
    });

    test('a manual pause then a transient loss still does not resume',
        () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      // The user paused first (engine paused, never armed by a focus loss).
      controller.handleEngineState(PlayerState(false, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _settle();
      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _settle();
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();

      expect(p.playCalls, 0,
          reason: 'a user pause before the interruption must not auto-resume');
    });
  });

  group('foreground safety restore (no clean focus gain)', () {
    test('foregrounding resumes a transient-loss pause when no gain arrives',
        () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      // The loss outlasts the debounce so it really pauses, then no regain is
      // ever delivered; returning to the foreground recovers.
      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce();
      controller.handleEngineState(PlayerState(false, ProcessingState.ready));

      controller.onAppForegrounded();
      await _settle();

      expect(p.playCalls, 1,
          reason:
              'a foreground return resumes a focus-loss pause with no gain');
    });

    test('foregrounding restores a lingering duck even with no gain', () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.duck));
      await _settle();
      expect(controller.isDuckedForTesting, isTrue);

      controller.onAppForegrounded();
      await _settle();

      expect(controller.isDuckedForTesting, isFalse);
      expect(p.volumes.last, 1.0,
          reason: 'a foreground return must lift a lingering duck');
    });

    test('foregrounding does not resume a user pause', () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      // Plain user pause: no focus loss ever armed a resume.
      controller.handleEngineState(PlayerState(false, ProcessingState.ready));

      controller.onAppForegrounded();
      await _settle();

      expect(p.playCalls, 0,
          reason: 'foregrounding must never resume a track the user paused');
    });

    test('foregrounding while playing normally changes nothing', () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAppForegrounded();
      await _settle();

      expect(p.playCalls, 0);
      expect(p.volumes, isEmpty);
    });
  });
}
