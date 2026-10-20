import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audio_stream_quality.dart';

void main() {
  group('AudioStreamQuality.isLossless', () {
    test('is true for codecs that are always lossless', () {
      for (final String codec in <String>[
        'flac',
        'alac',
        'ape',
        'tta',
        'wmalossless',
        'pcm_s16le',
        'pcm_s24le',
        'pcm_s32be',
        'pcm_u8',
        'pcm_f32le',
      ]) {
        expect(AudioStreamQuality(codec: codec).isLossless, isTrue,
            reason: codec);
      }
    });

    test('is false for lossy codecs', () {
      for (final String codec in <String>['mp3', 'aac', 'opus', 'vorbis']) {
        expect(AudioStreamQuality(codec: codec).isLossless, isFalse,
            reason: codec);
      }
    });

    test('is false where the codec allows a lossy stream', () {
      // WavPack's hybrid mode is lossy behind the same decoder, and A-law /
      // mu-law are companded PCM.
      for (final String codec in <String>['wavpack', 'pcm_alaw', 'pcm_mulaw']) {
        expect(AudioStreamQuality(codec: codec).isLossless, isFalse,
            reason: codec);
      }
    });

    test('is never inferred without a codec', () {
      const AudioStreamQuality quality = AudioStreamQuality(
        sampleRateHz: 96000,
        bitDepth: 24,
        bitrateKbps: 4608,
      );
      expect(quality.isLossless, isFalse);
    });
  });

  test('isEmpty only when nothing was reported', () {
    expect(const AudioStreamQuality().isEmpty, isTrue);
    expect(const AudioStreamQuality(sampleRateHz: 44100).isEmpty, isFalse);
  });

  test('describes itself without anything but the reported values', () {
    expect(
      const AudioStreamQuality(codec: 'flac').toString(),
      'AudioStreamQuality(codec: flac, sampleRateHz: unknown, '
      'bitDepth: unknown, bitrateKbps: unknown)',
    );
  });
}
