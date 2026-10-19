import '../../core/models/audio_stream_quality.dart';

/// Display text for an [AudioStreamQuality]: only the parts the engine
/// reported, in a fixed order (codec, lossless, sample rate, bit depth,
/// bitrate).
abstract final class AudioQualityLabel {
  static const String _separator = ' · ';

  /// "FLAC · Lossless · 44.1 kHz", or `null` when nothing is known.
  static String? text(AudioStreamQuality quality) {
    final List<String> parts = <String>[
      if (quality.codec != null) codecName(quality.codec!),
      if (quality.isLossless) 'Lossless',
      if (quality.sampleRateHz != null)
        '${_kilohertz(quality.sampleRateHz!)} kHz',
      if (quality.bitDepth != null) '${quality.bitDepth}-bit',
      if (quality.bitrateKbps != null) '${quality.bitrateKbps} kbps',
    ];
    return parts.isEmpty ? null : parts.join(_separator);
  }

  /// The same facts with the units spelled out, for screen readers.
  static String? semantics(AudioStreamQuality quality) {
    final List<String> parts = <String>[
      if (quality.codec != null) codecName(quality.codec!),
      if (quality.isLossless) 'lossless',
      if (quality.sampleRateHz != null)
        '${_kilohertz(quality.sampleRateHz!)} kilohertz',
      if (quality.bitDepth != null) '${quality.bitDepth}-bit',
      if (quality.bitrateKbps != null)
        '${quality.bitrateKbps} kilobits per second',
    ];
    return parts.isEmpty ? null : 'Audio quality: ${parts.join(', ')}';
  }

  /// The familiar name for an engine codec id. An id this does not know is
  /// shown as the engine wrote it, upper-cased, rather than guessed at.
  static String codecName(String codec) {
    if (codec.startsWith('pcm_')) return 'PCM';
    return switch (codec) {
      'flac' => 'FLAC',
      'alac' => 'ALAC',
      'mp3' || 'mp3float' => 'MP3',
      'mp2' => 'MP2',
      'aac' || 'aac_latm' => 'AAC',
      'opus' => 'Opus',
      'vorbis' => 'Vorbis',
      'ape' => 'APE',
      'wavpack' => 'WavPack',
      'tta' => 'TTA',
      'wmav1' || 'wmav2' => 'WMA',
      'wmapro' => 'WMA Pro',
      'wmalossless' => 'WMA Lossless',
      'ac3' => 'AC-3',
      'eac3' => 'E-AC-3',
      'dts' => 'DTS',
      'truehd' => 'TrueHD',
      _ => codec.toUpperCase(),
    };
  }

  /// 44100 -> "44.1", 48000 -> "48", 22050 -> "22.05".
  static String _kilohertz(int hz) =>
      (hz / 1000).toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
}
