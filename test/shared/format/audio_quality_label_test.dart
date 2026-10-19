import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audio_stream_quality.dart';
import 'package:linthra/shared/format/audio_quality_label.dart';

void main() {
  group('AudioQualityLabel.text', () {
    test('joins only what was reported', () {
      expect(
        AudioQualityLabel.text(
          const AudioStreamQuality(codec: 'flac', sampleRateHz: 44100),
        ),
        'FLAC · Lossless · 44.1 kHz',
      );
      expect(
        AudioQualityLabel.text(const AudioStreamQuality(
          codec: 'mp3',
          sampleRateHz: 48000,
          bitrateKbps: 320,
        )),
        'MP3 · 48 kHz · 320 kbps',
      );
      expect(
        AudioQualityLabel.text(const AudioStreamQuality(
          codec: 'pcm_s24le',
          sampleRateHz: 96000,
          bitDepth: 24,
        )),
        'PCM · Lossless · 96 kHz · 24-bit',
      );
    });

    test('without a codec there is no lossless claim', () {
      expect(
        AudioQualityLabel.text(const AudioStreamQuality(sampleRateHz: 44100)),
        '44.1 kHz',
      );
    });

    test('nothing known is no label at all', () {
      expect(AudioQualityLabel.text(const AudioStreamQuality()), isNull);
      expect(AudioQualityLabel.semantics(const AudioStreamQuality()), isNull);
    });

    test('formats sample rates without trailing zeros', () {
      String rate(int hz) =>
          AudioQualityLabel.text(AudioStreamQuality(sampleRateHz: hz))!;
      expect(rate(44100), '44.1 kHz');
      expect(rate(48000), '48 kHz');
      expect(rate(22050), '22.05 kHz');
      expect(rate(11025), '11.025 kHz');
      expect(rate(88200), '88.2 kHz');
      expect(rate(192000), '192 kHz');
    });
  });

  test('semantics spell the units out', () {
    expect(
      AudioQualityLabel.semantics(const AudioStreamQuality(
        codec: 'flac',
        sampleRateHz: 44100,
        bitrateKbps: 900,
      )),
      'Audio quality: FLAC, lossless, 44.1 kilohertz, '
      '900 kilobits per second',
    );
  });

  test('an unknown codec id is shown as the engine wrote it', () {
    expect(AudioQualityLabel.codecName('speex'), 'SPEEX');
    expect(AudioQualityLabel.codecName('opus'), 'Opus');
    expect(AudioQualityLabel.codecName('pcm_f32le'), 'PCM');
  });
}
