import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';

/// Exercises the real `just_audio`-backed controller's shuffle/repeat *state
/// plumbing* without driving playback. Like the lifecycle test, this constructs
/// the real controller; on a non-mobile test host the engine is built but no
/// platform channel is touched, because shuffle/repeat are pure state mutations
/// that never call into the player.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('JustAudioPlaybackController shuffle/repeat state', () {
    test('defaults: shuffle off, repeat off', () {
      final controller = JustAudioPlaybackController();
      addTearDown(controller.dispose);

      expect(controller.state.shuffleEnabled, isFalse);
      expect(controller.state.repeatMode, RepeatMode.off);
    });

    test('setShuffleEnabled toggles and emits the new state', () async {
      final controller = JustAudioPlaybackController();
      addTearDown(controller.dispose);

      final emitted = <bool>[];
      final sub =
          controller.stateStream.listen((s) => emitted.add(s.shuffleEnabled));

      controller.setShuffleEnabled(true);
      expect(controller.state.shuffleEnabled, isTrue);

      controller.setShuffleEnabled(false);
      expect(controller.state.shuffleEnabled, isFalse);

      await Future<void>.delayed(Duration.zero);
      expect(emitted, containsAllInOrder(<bool>[true, false]));
      await sub.cancel();
    });

    test('a redundant setShuffleEnabled does not emit', () async {
      final controller = JustAudioPlaybackController();
      addTearDown(controller.dispose);

      var emissions = 0;
      final sub = controller.stateStream.listen((_) => emissions++);

      controller.setShuffleEnabled(false); // already false: no-op
      await Future<void>.delayed(Duration.zero);

      expect(emissions, 0);
      await sub.cancel();
    });

    test('setRepeatMode updates and emits the mode', () async {
      final controller = JustAudioPlaybackController();
      addTearDown(controller.dispose);

      final emitted = <RepeatMode>[];
      final sub =
          controller.stateStream.listen((s) => emitted.add(s.repeatMode));

      controller.setRepeatMode(RepeatMode.all);
      expect(controller.state.repeatMode, RepeatMode.all);

      controller.setRepeatMode(RepeatMode.one);
      expect(controller.state.repeatMode, RepeatMode.one);

      await Future<void>.delayed(Duration.zero);
      expect(
        emitted,
        containsAllInOrder(<RepeatMode>[RepeatMode.all, RepeatMode.one]),
      );
      await sub.cancel();
    });
  });

  group('JustAudioPlaybackController.statusFor', () {
    // Pure mapping from the engine's (playing, processingState) pair to the
    // app's PlaybackStatus — no platform channel, no playback.
    PlaybackStatus map(bool playing, ProcessingState state) =>
        JustAudioPlaybackController.statusFor(PlayerState(playing, state));

    test('an idle engine is idle', () {
      expect(map(false, ProcessingState.idle), PlaybackStatus.idle);
    });

    test('loading is the preparing state', () {
      expect(map(false, ProcessingState.loading), PlaybackStatus.loading);
      expect(map(true, ProcessingState.loading), PlaybackStatus.loading);
    });

    test('buffering while playing is the mid-stream buffering state', () {
      // The engine wants to play but is waiting for data: a calm "Buffering…",
      // not a frozen player.
      expect(map(true, ProcessingState.buffering), PlaybackStatus.buffering);
    });

    test('buffering before the first play is still preparing (loading)', () {
      expect(map(false, ProcessingState.buffering), PlaybackStatus.loading);
    });

    test('ready maps to playing or paused by the play flag', () {
      expect(map(true, ProcessingState.ready), PlaybackStatus.playing);
      expect(map(false, ProcessingState.ready), PlaybackStatus.paused);
    });

    test('completed maps to completed', () {
      expect(map(false, ProcessingState.completed), PlaybackStatus.completed);
    });
  });

  group('engine state forwarding (foreground-service safety)', () {
    // The screen-off cutout bug: just_audio emits a transient
    // ProcessingState.idle at the *start* of every setUrl/setAudioSource (it
    // pushes a fresh, default PlaybackEvent before loading) — so on every track
    // transition and every mid-stream retry reload, while `playing` is still
    // true. If that idle reached the media session, audio_service would report
    // `playing: false` + `idle` and demote the foreground media service
    // mid-transition, letting the OS freeze background playback until the app is
    // reopened. The controller must drop it.

    test('a transient engine idle during a reload is not forwarded', () async {
      final controller = JustAudioPlaybackController();
      addTearDown(controller.dispose);

      final statuses = <PlaybackStatus>[];
      final sub = controller.stateStream.listen((s) => statuses.add(s.status));
      addTearDown(sub.cancel);

      // Steady playback, then the exact sequence a setUrl reload produces: a
      // fresh (idle) PlaybackEvent while still "playing", then loading, then
      // ready again.
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));
      controller.handleEngineState(PlayerState(true, ProcessingState.idle));
      controller.handleEngineState(PlayerState(true, ProcessingState.loading));
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      await Future<void>.delayed(Duration.zero);

      expect(
        statuses,
        isNot(contains(PlaybackStatus.idle)),
        reason: 'a transient engine idle mid-reload would demote the '
            'foreground media service with the screen off',
      );
      expect(controller.state.status, PlaybackStatus.playing);
    });

    test('engine buffering and loading are still forwarded (kept playing)', () {
      final controller = JustAudioPlaybackController();
      addTearDown(controller.dispose);

      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      // A mid-stream re-buffer must reach the session (it maps to a still-
      // playing buffering state), so the service is never demoted on a stall.
      controller
          .handleEngineState(PlayerState(true, ProcessingState.buffering));
      expect(controller.state.status, PlaybackStatus.buffering);

      controller.handleEngineState(PlayerState(true, ProcessingState.loading));
      expect(controller.state.status, PlaybackStatus.loading);
    });

    test('a real engine pause is still forwarded (the filter is idle-only)',
        () {
      final controller = JustAudioPlaybackController();
      addTearDown(controller.dispose);

      controller.handleEngineState(PlayerState(true, ProcessingState.ready));
      expect(controller.state.status, PlaybackStatus.playing);

      // ready + not-playing is a genuine user pause: it must still report
      // not-playing so the service is released on a real pause (not suppressed
      // like the transient reload idle).
      controller.handleEngineState(PlayerState(false, ProcessingState.ready));
      expect(controller.state.status, PlaybackStatus.paused);
    });
  });

  group('audio focus never forces an unexpected resume', () {
    // The "music starts/resumes by itself when the screen turns on, or when I
    // switch apps" regression. just_audio's built-in interruption handler
    // (handleInterruptions: true) pauses on a focus loss but then calls play()
    // again on focus *regain* — so a transient interruption (a notification,
    // another app briefly taking focus, the focus churn some OEMs emit on screen
    // on/off and around battery-saver/Doze) resumes playback underneath the
    // controller. The controller disables that handler and owns focus itself:
    // it pauses on a real loss and NEVER auto-resumes. shouldPauseForInterruption
    // is the pure decision behind that, exercised here without any platform.
    bool shouldPause(bool begin, AudioInterruptionType type) =>
        JustAudioPlaybackController.shouldPauseForInterruption(
            AudioInterruptionEvent(begin, type));

    test('a focus loss (interruption begins) pauses', () {
      // Another app / a call grabbed focus: pause so we don't talk over it.
      expect(shouldPause(true, AudioInterruptionType.pause), isTrue);
      expect(shouldPause(true, AudioInterruptionType.unknown), isTrue);
    });

    test('a focus regain (interruption ends) never resumes', () {
      // This is the exact point just_audio used to call play(). For every event
      // type, returning to the foreground / regaining focus must NOT resume —
      // only an explicit user / media-session play does.
      expect(shouldPause(false, AudioInterruptionType.pause), isFalse);
      expect(shouldPause(false, AudioInterruptionType.unknown), isFalse);
      expect(shouldPause(false, AudioInterruptionType.duck), isFalse);
    });

    test('a transient duck does not pause (and so cannot trigger a resume)',
        () {
      // A brief duck is left to ride; we neither pause nor (therefore) resume.
      expect(shouldPause(true, AudioInterruptionType.duck), isFalse);
    });
  });
}
