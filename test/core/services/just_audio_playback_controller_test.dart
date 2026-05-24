import 'package:flutter_test/flutter_test.dart';
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
}
