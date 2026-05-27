import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/replay_gain.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';

void main() {
  Track track({ReplayGain gain = ReplayGain.none}) =>
      Track(id: 't', title: 'T', uri: 'file:///t.flac', replayGain: gain);

  group('JustAudioPlaybackController.volumeFor', () {
    test('full volume when normalization is off, whatever the gain', () {
      final loud = track(gain: const ReplayGain(trackGainDb: -12.0));
      expect(
        JustAudioPlaybackController.volumeFor(loud, normalizeVolume: false),
        1.0,
      );
    });

    test('full volume when there is no track', () {
      expect(
        JustAudioPlaybackController.volumeFor(null, normalizeVolume: true),
        1.0,
      );
    });

    test('full volume for a track with no ReplayGain even when on', () {
      expect(
        JustAudioPlaybackController.volumeFor(track(), normalizeVolume: true),
        1.0,
      );
    });

    test('attenuates a loud track when normalization is on', () {
      final loud = track(gain: const ReplayGain(trackGainDb: -6.0));
      final v =
          JustAudioPlaybackController.volumeFor(loud, normalizeVolume: true);
      expect(v, lessThan(1.0));
      expect(v, closeTo(0.501, 0.01));
    });

    test('never amplifies a quiet track (clamped to full)', () {
      final quiet = track(gain: const ReplayGain(trackGainDb: 6.0));
      expect(
        JustAudioPlaybackController.volumeFor(quiet, normalizeVolume: true),
        1.0,
      );
    });
  });
}
