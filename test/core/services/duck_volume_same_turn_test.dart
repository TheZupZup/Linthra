// A volume change in the same turn as a duck or its end sticks.
//
// The focus chain captured its target volume when a duck or an unduck was
// queued (JustAudioPlaybackController._enqueueFocusVolume), while setVolume
// pushes its level to the engine straight away. A listener level change in
// the same turn reached the engine first and was then written over by the
// stale target, so the engine ended at a level that disagreed with
// PlaybackState.volume. Dormant on today's platforms (Android turns ducks into
// pauses, Linux has no audio focus), so this keeps it from coming back.
import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';

/// Records every volume pushed to the engine, in order.
class _RecordingPlayer extends Fake implements AudioPlayer {
  final List<double> volumes = <double>[];

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
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an unduck and a volume change in the same turn end at the new level',
      () async {
    final _RecordingPlayer player = _RecordingPlayer();
    final JustAudioPlaybackController controller =
        JustAudioPlaybackController(player: player);
    addTearDown(controller.dispose);
    controller.handleEngineState(PlayerState(true, ProcessingState.ready));
    controller.onAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.duck));
    await _settle();

    // The duck ends just as the listener drags the slider to half.
    controller.onAudioInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.duck));
    controller.setVolume(0.5);
    await _settle();

    expect(controller.state.volume, 0.5);
    expect(player.volumes.last, 0.5,
        reason: 'engine pushed ${player.volumes}: the unduck queued 1.0 '
            'before the slider moved and applied it after');
  });

  test(
      'a duck and a volume change in the same turn end ducked at the new '
      'level', () async {
    final _RecordingPlayer player = _RecordingPlayer();
    final JustAudioPlaybackController controller =
        JustAudioPlaybackController(player: player);
    addTearDown(controller.dispose);
    controller.handleEngineState(PlayerState(true, ProcessingState.ready));

    controller.onAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.duck));
    controller.setVolume(0.5);
    await _settle();

    final double expected = JustAudioPlaybackController.engineVolumeFor(
      null,
      normalizeVolume: false,
      volume: 0.5,
      muted: false,
      ducked: true,
    );
    expect(controller.isDuckedForTesting, isTrue);
    expect(player.volumes.last, closeTo(expected, 1e-9),
        reason: 'engine pushed ${player.volumes}: the duck queued the ducked '
            'full level and applied it after the slider moved');
  });
}
