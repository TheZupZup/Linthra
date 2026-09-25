import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/stream_interruption.dart';

/// Guards the Android build pieces that keep #674 fixed: the vendored Media3
/// FLAC decoder, the libFLAC it builds from, and the patched just_audio player
/// that uses it only when the platform cannot decode FLAC.
///
/// None of these fail loudly when they drift. A mismatched Media3 version, a
/// dropped ABI, an extension mode that puts libFLAC first, or a shrunk-away
/// renderer all still build, and simply bring back silent playback or an extra
/// CPU cost on every device. So each is pinned here.
String _read(String path) => File(path).readAsStringSync();

void main() {
  const String module = 'third_party/media3_decoder_flac';
  const String player =
      'third_party/just_audio/android/src/main/java/com/ryanheise/just_audio/'
      'AudioPlayer.java';

  test('the FLAC module is built against the Media3 version just_audio uses',
      () {
    final RegExpMatch? justAudio = RegExp(r'def exoplayer_version = "([^"]+)"')
        .firstMatch(_read('third_party/just_audio/android/build.gradle'));
    final RegExpMatch? flac =
        RegExp(r"androidx\.media3:media3-exoplayer:([^']+)'")
            .firstMatch(_read('$module/build.gradle'));
    expect(justAudio, isNotNull);
    expect(flac, isNotNull);
    expect(flac!.group(1), justAudio!.group(1),
        reason:
            'Media3 does not support a decoder module from another release');
    expect(
        _read('$module/PATCHES.md'), contains('| Version | ${flac.group(1)},'));
  });

  test('the module is part of the Android build and packaged by the app', () {
    final String settings = _read('android/settings.gradle');
    expect(settings, contains('include ":media3_decoder_flac"'));
    expect(
      settings,
      contains('project(":media3_decoder_flac").projectDir = '
          'file("../third_party/media3_decoder_flac")'),
    );
    expect(
      _read('android/app/build.gradle'),
      contains('implementation project(":media3_decoder_flac")'),
    );
  });

  test('every ABI Linthra ships gets the native decoder', () {
    final String gradle = _read('$module/build.gradle');
    expect(gradle, contains("abiFilters 'armeabi-v7a', 'arm64-v8a', 'x86_64'"));
    // The per-ABI release builds are exactly these three.
    final String release = _read('.github/workflows/android-release-build.yml');
    expect(
      release,
      contains('for entry in "armeabi-v7a:android-arm" '
          '"arm64-v8a:android-arm64" "x86_64:android-x64"'),
    );
  });

  test('SDK levels and NDK follow the app, never a second pin', () {
    final String gradle = _read('$module/build.gradle');
    expect(gradle, contains("def appAndroid = project(':app').android"));
    expect(gradle, contains('compileSdk appAndroid.compileSdk'));
    expect(gradle, contains('ndkVersion appAndroid.ndkVersion'));
    expect(gradle, contains('minSdk appAndroid.defaultConfig.minSdk'));
    expect(gradle, isNot(contains(RegExp(r'minSdk\s+\d'))));
  });

  test('the platform decoder stays first; libFLAC is only a fallback', () {
    final String java = _read(player);
    expect(java, contains('EXTENSION_RENDERER_MODE_ON'));
    expect(java, isNot(contains('EXTENSION_RENDERER_MODE_PREFER')));
    expect(java,
        contains('new ExoPlayer.Builder(context, buildRenderersFactory())'));
    // Media3's extension FlacExtractor would decode in the extractor on every
    // device, bypassing platform decoders. It must stay out of the build.
    final List<String> classes = Directory(
      '$module/src/main/java/androidx/media3/decoder/flac',
    ).listSync().map((FileSystemEntity e) => e.uri.pathSegments.last).toList();
    expect(classes, isNot(contains('FlacExtractor.java')));
    expect(classes, contains('LibflacAudioRenderer.java'));
  });

  test('undecodable audio is reported with the code Linthra classifies', () {
    final String java = _read(player);
    expect(java, contains('tracks.containsType(C.TRACK_TYPE_AUDIO)'));
    expect(java, contains('tracks.isTypeSelected(C.TRACK_TYPE_AUDIO)'));
    expect(java,
        contains('PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED'));
    expect(java, contains('player.stop();'));
    // Media3's ERROR_CODE_DECODING_FORMAT_UNSUPPORTED.
    expect(unsupportedAudioFormatErrorCode, 4005);
  });

  test('R8 cannot shrink the reflectively loaded renderer away', () {
    final String gradle = _read('$module/build.gradle');
    expect(
        gradle,
        contains(
            "consumerProguardFiles 'proguard-rules.txt', 'linthra-consumer-rules.pro'"));
    final String rules = _read('$module/linthra-consumer-rules.pro');
    expect(
        rules,
        contains(
            '-keep class androidx.media3.decoder.flac.LibflacAudioRenderer'));
    expect(rules,
        contains('-keep class androidx.media3.decoder.flac.FlacLibrary'));
  });

  group('native build', () {
    late String cmake;
    setUpAll(() => cmake = _read('$module/src/main/jni/CMakeLists.txt'));

    test('compiles exactly the vendored libFLAC decoder sources', () {
      final Set<String> listed =
          RegExp(r'\$\{LIBFLAC_ROOT\}/(src/libFLAC/[a-z0-9_]+\.c)')
              .allMatches(cmake)
              .map((RegExpMatch m) => m.group(1)!)
              .toSet();
      final Set<String> vendored = Directory('third_party/libflac/src/libFLAC')
          .listSync()
          .whereType<File>()
          .map((File f) => 'src/libFLAC/${f.uri.pathSegments.last}')
          .where((String p) => p.endsWith('.c'))
          .toSet();
      expect(listed, vendored);
      // Decoder only: no encoder or metadata-editing code is built.
      expect(listed.where((String p) => p.contains('encoder')), isEmpty);
      expect(listed.where((String p) => p.contains('metadata_')), isEmpty);
    });

    test('keeps its hardening flags', () {
      for (final String flag in <String>[
        '-fwrapv',
        '-fstack-protector-strong',
        '-fvisibility=hidden',
        '-ffile-prefix-map=',
        '-Wl,-z,relro',
        '-Wl,-z,now',
        '-Wl,--no-undefined',
        '-Wl,--exclude-libs,ALL',
        '-Wl,-z,max-page-size=16384',
        'FLAC__NO_ASM',
        'FLAC__HAS_OGG=0',
      ]) {
        expect(cmake, contains(flag), reason: flag);
      }
    });

    test('pins libFLAC to a reviewed release commit', () {
      final String patches = _read('third_party/libflac/PATCHES.md');
      expect(patches, contains('| Version | 1.5.0'));
      expect(patches, contains('`1507800de4b70e21be71f38caa0d9079d0bc6e45`'));
      expect(cmake, contains('PACKAGE_VERSION="1.5.0"'));
    });
  });
}
