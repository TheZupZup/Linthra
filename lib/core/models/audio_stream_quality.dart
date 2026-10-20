/// What the audio engine reports about the stream it is decoding right now.
///
/// This is deliberately *not* catalog metadata. It describes the bytes the
/// engine actually opened: a Subsonic stream the server transcoded reads as the
/// transcode, an offline copy as the file on disk, and a fallback to another
/// provider as that provider's copy. That is also why it lives apart from
/// `PlaybackSourceCapability`, which is what Linthra knows about a candidate
/// *before* anything plays.
///
/// Every field is `null` unless the engine stated it. Nothing is derived from a
/// file name or an extension, and nothing is filled in from what a format
/// "usually" is.
class AudioStreamQuality {
  const AudioStreamQuality({
    this.codec,
    this.sampleRateHz,
    this.bitDepth,
    this.bitrateKbps,
  });

  /// The engine's codec id for the stream, lower case (`flac`, `mp3`, `aac`,
  /// `opus`, `pcm_s16le`, …).
  final String? codec;

  /// The sample rate the decoder outputs, in Hz.
  final int? sampleRateHz;

  /// Bits per sample, only when the codec itself states it (uncompressed PCM).
  final int? bitDepth;

  /// The stream's average bitrate as its container reports it, in kbps.
  final int? bitrateKbps;

  /// Codecs whose every stream is lossless. WavPack is missing on purpose: its
  /// hybrid mode is lossy and uses the same decoder.
  static const Set<String> _losslessCodecs = <String>{
    'flac',
    'alac',
    'ape',
    'tta',
    'wmalossless',
    'mlp',
    'truehd',
  };

  /// Linear PCM (`pcm_s16le`, `pcm_u8`, `pcm_f32be`, …). Companded PCM
  /// (`pcm_alaw`, `pcm_mulaw`) is not lossless and does not match.
  static final RegExp _linearPcm = RegExp(r'^pcm_[suf](8|16|24|32|64)');

  /// Whether the stream is losslessly coded, which only the codec can say.
  bool get isLossless {
    final String? id = codec;
    if (id == null) return false;
    return _losslessCodecs.contains(id) || _linearPcm.hasMatch(id);
  }

  /// Whether the engine reported nothing usable at all.
  bool get isEmpty =>
      codec == null &&
      sampleRateHz == null &&
      bitDepth == null &&
      bitrateKbps == null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AudioStreamQuality &&
          other.codec == codec &&
          other.sampleRateHz == sampleRateHz &&
          other.bitDepth == bitDepth &&
          other.bitrateKbps == bitrateKbps);

  @override
  int get hashCode => Object.hash(codec, sampleRateHz, bitDepth, bitrateKbps);

  @override
  String toString() => 'AudioStreamQuality('
      'codec: ${codec ?? 'unknown'}, '
      'sampleRateHz: ${sampleRateHz ?? 'unknown'}, '
      'bitDepth: ${bitDepth ?? 'unknown'}, '
      'bitrateKbps: ${bitrateKbps ?? 'unknown'})';
}
