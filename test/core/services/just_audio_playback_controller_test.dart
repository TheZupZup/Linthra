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
}
