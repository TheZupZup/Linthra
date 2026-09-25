import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Which FLAC decoding path this device prefers with Linthra's Android player.
///
/// Linthra's player tries the platform decoder first and uses the bundled
/// libFLAC for any FLAC track the platform decoder does not handle (see
/// third_party/just_audio/PATCHES.md). This is the preferred path from what is
/// registered on the device, not the decoder a particular track used: a
/// platform decoder can still turn down one track's sample rate, channels or
/// bit depth, and that track then plays through libFLAC. The decoder a track
/// actually used is logged (`Audio decoder: <name>` in logcat).
enum FlacDecodingPath {
  /// A platform `MediaCodec` FLAC decoder is registered and is tried first.
  /// Guaranteed from API 27; present on many older devices too.
  platform,

  /// No platform FLAC decoder. The bundled libFLAC decoder is used instead
  /// (API 24–26 devices without a vendor decoder, #674).
  bundledFallback,

  /// Neither. A FLAC track fails with an unsupported-format error rather than
  /// playing. Only a broken build (the fallback library missing for this ABI)
  /// should ever land here.
  unavailable,
}

/// What the Android audio stack on this device can decode, for the diagnostics
/// report (#674).
///
/// Everything here is a platform fact, not user data: the SDK level, ABI names,
/// codec names and MIME types. Nothing about the library, servers or tracks.
/// [AudioDecoderCapabilities.fromPlatform] keeps only values of those shapes,
/// so even an unexpected payload cannot carry free text into a report.
@immutable
class AudioDecoderCapabilities {
  const AudioDecoderCapabilities({
    required this.sdkInt,
    required this.supportedAbis,
    required this.flacPlatformDecoders,
    required this.flacFallbackAvailable,
    required this.platformDecoderMimeTypes,
  });

  /// `Build.VERSION.SDK_INT`. Fire OS reports a build id rather than a version
  /// string, so this is the only reliable API level in a report.
  final int sdkInt;

  /// `Build.SUPPORTED_ABIS`, most preferred first.
  final List<String> supportedAbis;

  /// Names of the platform decoders registered for `audio/flac`.
  final List<String> flacPlatformDecoders;

  /// Whether the bundled libFLAC fallback (`libflacJNI.so`) loads.
  final bool flacFallbackAvailable;

  /// The reported MIME types (FLAC, MP3, AAC, Opus, Vorbis, ALAC, PCM) the
  /// platform has at least one decoder for.
  final List<String> platformDecoderMimeTypes;

  /// The FLAC path this device prefers (see [FlacDecodingPath]).
  FlacDecodingPath get flacDecodingPath {
    if (flacPlatformDecoders.isNotEmpty) return FlacDecodingPath.platform;
    if (flacFallbackAvailable) return FlacDecodingPath.bundledFallback;
    return FlacDecodingPath.unavailable;
  }

  /// The report line for FLAC. With a platform decoder registered it states
  /// both paths' availability rather than claiming which one a track used:
  /// the platform decoder can turn down a track that libFLAC then plays.
  String get flacSummary {
    switch (flacDecodingPath) {
      case FlacDecodingPath.platform:
        final String fallback = flacFallbackAvailable
            ? 'built-in libFLAC fallback available'
            : 'built-in libFLAC fallback not loaded';
        return 'platform decoder first (${flacPlatformDecoders.join(', ')}), '
            '$fallback';
      case FlacDecodingPath.bundledFallback:
        return 'built-in fallback (libFLAC), no platform decoder';
      case FlacDecodingPath.unavailable:
        return 'unavailable (no platform decoder, fallback not loaded)';
    }
  }

  /// The short names of the formats the platform decodes, in a stable order.
  List<String> get platformFormatNames => <String>[
        for (final MapEntry<String, String> entry in _formatNames.entries)
          if (platformDecoderMimeTypes.contains(entry.key)) entry.value,
      ];

  static const Map<String, String> _formatNames = <String, String>{
    'audio/flac': 'flac',
    'audio/mpeg': 'mp3',
    'audio/mp4a-latm': 'aac',
    'audio/opus': 'opus',
    'audio/vorbis': 'vorbis',
    'audio/alac': 'alac',
    'audio/raw': 'pcm',
  };

  /// Parses the platform channel's reply, keeping only well-formed values.
  /// Returns null when the reply is not usable at all.
  static AudioDecoderCapabilities? fromPlatform(Map<Object?, Object?>? raw) {
    if (raw == null) return null;
    final Object? sdk = raw['sdkInt'];
    if (sdk is! int || sdk < 1 || sdk > 1000) return null;
    return AudioDecoderCapabilities(
      sdkInt: sdk,
      supportedAbis: _names(raw['supportedAbis'], _abiPattern),
      flacPlatformDecoders: _names(raw['flacPlatformDecoders'], _codecPattern),
      flacFallbackAvailable: raw['flacFallbackAvailable'] == true,
      platformDecoderMimeTypes: _names(raw['platformDecoderMimeTypes'], null)
          .where(_formatNames.containsKey)
          .toList(growable: false),
    );
  }

  // ABI names are short identifiers (armeabi-v7a, arm64-v8a, x86_64).
  static final RegExp _abiPattern = RegExp(r'^[a-z0-9_-]{1,24}$');

  // Codec names: vendor dotted identifiers (OMX.google.flac.decoder,
  // c2.android.flac.decoder, OMX.MTK.AUDIO.DECODER.FLAC).
  static final RegExp _codecPattern = RegExp(r'^[A-Za-z0-9._-]{1,80}$');

  static List<String> _names(Object? value, RegExp? pattern) {
    if (value is! List) return const <String>[];
    return <String>[
      for (final Object? item in value.take(16))
        if (item is String && (pattern == null || pattern.hasMatch(item))) item,
    ];
  }
}

const MethodChannel _channel =
    MethodChannel('io.github.thezupzup.linthra/audio_capabilities');

/// Reads the device's audio decoder capabilities. Android only; null elsewhere
/// and on any platform error, so a diagnostics report never fails because of it.
Future<AudioDecoderCapabilities?> readPlatformAudioDecoderCapabilities() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    return AudioDecoderCapabilities.fromPlatform(
      await _channel.invokeMapMethod<Object?, Object?>('getAudioCapabilities'),
    );
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
