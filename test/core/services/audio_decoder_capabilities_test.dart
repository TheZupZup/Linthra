import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/app_diagnostics.dart';
import 'package:linthra/core/services/audio_decoder_capabilities.dart';

/// The facts AudioCapabilitiesChannel.kt reports for a device, as the channel
/// delivers them.
Map<Object?, Object?> _platform({
  int sdkInt = 25,
  List<Object?> abis = const <Object?>['armeabi-v7a', 'armeabi'],
  List<Object?> flac = const <Object?>[],
  bool fallback = true,
  List<Object?> mimeTypes = const <Object?>[
    'audio/mpeg',
    'audio/mp4a-latm',
    'audio/vorbis',
    'audio/raw',
  ],
}) =>
    <Object?, Object?>{
      'sdkInt': sdkInt,
      'supportedAbis': abis,
      'flacPlatformDecoders': flac,
      'flacFallbackAvailable': fallback,
      'platformDecoderMimeTypes': mimeTypes,
    };

void main() {
  group('FLAC decoding path by device', () {
    test('API 24–26 device without a platform decoder uses the fallback', () {
      // The #674 device: Fire OS on Android 7.1, 32-bit, no FLAC MediaCodec.
      for (final int sdk in <int>[24, 25, 26]) {
        final AudioDecoderCapabilities caps =
            AudioDecoderCapabilities.fromPlatform(_platform(sdkInt: sdk))!;
        expect(caps.flacDecodingPath, FlacDecodingPath.bundledFallback);
        expect(caps.flacSummary,
            'built-in fallback (libFLAC), no platform decoder');
      }
    });

    test('an old device whose vendor ships a FLAC decoder keeps using it', () {
      final AudioDecoderCapabilities caps =
          AudioDecoderCapabilities.fromPlatform(
        _platform(
          sdkInt: 24,
          flac: <Object?>['OMX.MTK.AUDIO.DECODER.FLAC'],
          mimeTypes: <Object?>['audio/flac', 'audio/mpeg'],
        ),
      )!;
      expect(caps.flacDecodingPath, FlacDecodingPath.platform);
      // Availability of both paths, not a claim about which decoder a track
      // used: the platform decoder can still turn a track down, and libFLAC
      // then plays it.
      expect(
        caps.flacSummary,
        'platform decoder first (OMX.MTK.AUDIO.DECODER.FLAC), '
        'built-in libFLAC fallback available',
      );
    });

    test('a platform decoder without the fallback says so', () {
      final AudioDecoderCapabilities caps =
          AudioDecoderCapabilities.fromPlatform(
        _platform(
          sdkInt: 30,
          flac: <Object?>['c2.android.flac.decoder'],
          fallback: false,
        ),
      )!;
      expect(caps.flacDecodingPath, FlacDecodingPath.platform);
      expect(
        caps.flacSummary,
        'platform decoder first (c2.android.flac.decoder), '
        'built-in libFLAC fallback not loaded',
      );
    });

    test('API 27+ uses the platform decoder even with the fallback bundled',
        () {
      for (final int sdk in <int>[27, 29, 34, 36]) {
        final AudioDecoderCapabilities caps =
            AudioDecoderCapabilities.fromPlatform(
          _platform(
            sdkInt: sdk,
            abis: <Object?>['arm64-v8a', 'armeabi-v7a', 'armeabi'],
            flac: <Object?>['c2.android.flac.decoder'],
            mimeTypes: <Object?>['audio/flac', 'audio/mpeg', 'audio/opus'],
          ),
        )!;
        expect(caps.flacDecodingPath, FlacDecodingPath.platform,
            reason: '$sdk');
      }
    });

    test('no platform decoder and no fallback is reported as unavailable', () {
      final AudioDecoderCapabilities caps =
          AudioDecoderCapabilities.fromPlatform(_platform(fallback: false))!;
      expect(caps.flacDecodingPath, FlacDecodingPath.unavailable);
      expect(caps.flacSummary, contains('unavailable'));
    });
  });

  group('fromPlatform keeps only well-formed platform facts', () {
    test('rejects a reply without a plausible SDK level', () {
      expect(AudioDecoderCapabilities.fromPlatform(null), isNull);
      expect(
        AudioDecoderCapabilities.fromPlatform(
            <Object?, Object?>{'sdkInt': 'x'}),
        isNull,
      );
      expect(
          AudioDecoderCapabilities.fromPlatform(_platform(sdkInt: 0)), isNull);
    });

    test('drops anything that is not a codec name, ABI or known MIME type', () {
      final AudioDecoderCapabilities caps =
          AudioDecoderCapabilities.fromPlatform(
        _platform(
          abis: <Object?>['armeabi-v7a', '/data/app/x', 7, 'arm64 v8a'],
          flac: <Object?>[
            'OMX.google.flac.decoder',
            'https://evil/decoder?token=SECRET',
            'decoder\nLast error: none',
            null,
          ],
          mimeTypes: <Object?>['audio/mpeg', 'text/html', 'audio/flac?x=1'],
        ),
      )!;
      expect(caps.supportedAbis, <String>['armeabi-v7a']);
      expect(caps.flacPlatformDecoders, <String>['OMX.google.flac.decoder']);
      expect(caps.platformDecoderMimeTypes, <String>['audio/mpeg']);
    });

    test('formats are named in a stable order', () {
      final AudioDecoderCapabilities caps =
          AudioDecoderCapabilities.fromPlatform(
        _platform(
          mimeTypes: <Object?>['audio/raw', 'audio/opus', 'audio/mpeg'],
        ),
      )!;
      expect(caps.platformFormatNames, <String>['mp3', 'opus', 'pcm']);
    });
  });

  group('diagnostics report', () {
    String reportFor(AudioDecoderCapabilities caps) => AppDiagnostics.report(
          AppDiagnosticsData(
            appVersion: '0.2.8',
            androidVersion: 'NS6574',
            androidSdkInt: caps.sdkInt,
            androidAbis: caps.supportedAbis,
            flacDecoding: caps.flacSummary,
            platformAudioFormats: caps.platformFormatNames,
          ),
        );

    test('a #674-style report shows SDK, ABI and the FLAC path', () {
      final String report = reportFor(
        AudioDecoderCapabilities.fromPlatform(_platform())!,
      );
      expect(report, contains('Android: NS6574'));
      expect(report, contains('Android SDK: 25'));
      expect(report, contains('ABI: armeabi-v7a, armeabi'));
      expect(
        report,
        contains('FLAC decoding: built-in fallback (libFLAC), no platform '
            'decoder'),
      );
      expect(
          report, contains('Platform audio decoders: mp3, aac, vorbis, pcm'));
    });

    test('carries no credential, URL or path', () {
      final String report = reportFor(
        AudioDecoderCapabilities.fromPlatform(
          _platform(
            flac: <Object?>['https://plex:32400/?X-Plex-Token=SECRET'],
            abis: <Object?>['/storage/emulated/0/Music'],
          ),
        )!,
      );
      expect(report, isNot(contains('SECRET')));
      expect(report, isNot(contains('http')));
      expect(report, isNot(contains('/storage')));
    });

    test('omits the lines entirely off Android', () {
      final String report =
          AppDiagnostics.report(const AppDiagnosticsData(appVersion: '0.2.8'));
      expect(report, isNot(contains('Android SDK')));
      expect(report, isNot(contains('FLAC decoding')));
      expect(report, isNot(contains('Platform audio decoders')));
    });
  });
}
