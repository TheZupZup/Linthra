import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardrails for the Flatpak local-library sandbox smoke (#447).
///
/// The smoke needs a 90-minute flatpak-builder run, so the properties that make
/// it mean anything are held here as text instead: that the grant stays narrow,
/// that the isolation probes are real, that losing access is proven recoverable
/// rather than destructive, and that none of it leaks a music path.
void main() {
  late String harness;

  /// The harness with its comments stripped.
  ///
  /// Its header explains at length which grants it deliberately does *not*
  /// use, so a check for `--filesystem=home` has to read the commands rather
  /// than the prose about them.
  late String harnessCommands;
  late String smoke;
  late String workflow;
  late String manifest;

  setUpAll(() {
    harness = File('scripts/flatpak_local_library_smoke.sh').readAsStringSync();
    harnessCommands = harness
        .split('\n')
        .where((String line) => !line.trimLeft().startsWith('#'))
        .join('\n');
    smoke = File('tool/linux_local_library_smoke.dart').readAsStringSync();
    workflow = File('.github/workflows/flatpak-build.yml').readAsStringSync();
    manifest =
        File('flatpak/io.github.thezupzup.linthra.yml').readAsStringSync();
  });

  group('the package stays free of filesystem permissions', () {
    // The entire point of #447 is proving the narrow path works, so nothing
    // here may quietly widen the package while making the smoke pass.
    test('the submission manifest grants no filesystem access', () {
      expect(manifest, isNot(contains('--filesystem=')));
      expect(manifest, isNot(contains('--persist=')));
    });

    test('the harness grants one folder, per run, and never an override', () {
      expect(harness, contains(r'grant_args=("--filesystem=$MUSIC_DIR")'));
      expect(
        harnessCommands,
        isNot(contains('flatpak override --filesystem')),
        reason: 'an override would test the override, not the package',
      );
      expect(harnessCommands, isNot(contains('--filesystem=home')));
      expect(harnessCommands, isNot(contains('--filesystem=host')));
    });

    // A machine that already has a filesystem override would report a pass
    // that belongs to the override.
    test('the harness refuses to run under an existing override', () {
      expect(harness, contains(r'flatpak override $scope $target --show'));
      expect(harness, contains('already grants filesystem access'));
    });
  });

  group('the granted folder is really exercised', () {
    test('the scan is the production wiring, not a stub', () {
      expect(smoke, contains('LocalLibraryScanner('));
      expect(smoke, contains('LocalMusicSource('));
      expect(smoke, contains('const PlatformAudioFileScanner()'));
      expect(smoke, contains('FilesystemLocalMetadataReader()'));
    });

    test('metadata is asserted against the tags the fixture wrote', () {
      expect(smoke, contains("_expect(wav.title, _wavTitle, 'the WAV title')"));
      expect(smoke, contains("_expect(wav.artistName, _artist,"));
      expect(smoke, contains("_expect(wav.albumName, _album,"));
      expect(smoke, contains("_expect(wav.trackNumber, 1,"));
    });

    test('artwork is decoded, and never written into the music folder', () {
      expect(smoke, contains('_decodedSize(cover)'));
      expect(smoke, contains('cover.path.startsWith(config.root)'));
      expect(
        smoke,
        contains('the cover was cached inside the user\\\'s music folder'),
      );
    });

    test('playback is asserted on the clock, not on a status flag', () {
      expect(smoke, contains('state.position > Duration.zero'));
      expect(smoke, contains('never started playing'));
    });

    test('a non-audio file has to be skipped, not merely absent', () {
      expect(smoke, contains('_textRelativePath'));
      expect(smoke, contains('scan.report.skippedUnsupported < 1'));
    });
  });

  group('isolation', () {
    test('the smoke refuses to pass without a host probe', () {
      expect(smoke, contains('no host probe was configured'));
    });

    test('both probes sit beside the music folder in the host home', () {
      expect(
          harness, contains(r'mktemp -d "$HOME/linthra-local-library-smoke'));
      expect(
        harness,
        contains(r'mktemp -d "$HOME/linthra-local-library-sibling'),
      );
      expect(
          harness, contains(r'mktemp "$HOME/.linthra-local-library-sentinel'));
    });

    // "Invisible" would prove nothing if the smoke had deleted them.
    test('the probes are re-checked on the host afterwards', () {
      expect(harness, contains(r'[[ -r "$SENTINEL_FILE" ]]'));
      expect(harness, contains('the isolation result would be meaningless'));
    });
  });

  group('losing access is recoverable, not destructive', () {
    test('the revoked run gets no grant at all', () {
      expect(harness, contains('run_mode revoked revoked'));
    });

    test('the failure is classified, explained and non-destructive', () {
      expect(smoke, contains('LocalScanError.folderUnavailable'));
      expect(smoke, contains('carries no message for the user'));
      expect(smoke, contains('retained.isWritable'));
      expect(
        smoke,
        contains('the previously indexed track was dropped rather than kept'),
      );
      expect(smoke, contains('bare.retentionUnavailable'));
    });

    test('the library is re-scanned after a restart', () {
      expect(harness, contains('Re-scanning after a restart'));
      expect(harness, contains('survived a restart'));
    });
  });

  group('hygiene', () {
    test('no credentials, no network, no committed media', () {
      expect(harnessCommands, isNot(contains('https://')));
      expect(harnessCommands, isNot(contains('curl ')));
      expect(harnessCommands, isNot(contains('wget ')));
      expect(smoke, isNot(contains('http://')));
      expect(smoke, isNot(contains('https://')));
    });

    test('music paths are sanitized out of failure output', () {
      expect(harness, contains('sanitize()'));
      expect(smoke, contains("'<music-folder>'"));
      expect(smoke, contains(r"'/home/<user>'"));
      expect(smoke, contains('sanitizer.clean(error.toString())'));
    });

    // A hung job serves no log until it ends, so an unbounded run costs the
    // whole job timeout and reports nothing.
    test('bounds every sandbox run and fails when one hits the bound', () {
      expect(harness, contains('RUN_TIMEOUT_SECONDS'));
      expect(harness, contains('timeout --signal=TERM --kill-after=30'));
      expect(
        harness,
        contains(r'fail "the $mode run hung and was killed after'),
      );
      // The install probe is a `flatpak run` too, and sandbox startup is
      // exactly where a stall would go unnoticed.
      expect(harness, contains(r'fail "checking for $SMOKE_COMMAND hung'));
    });

    test('the harness leaves nothing behind', () {
      expect(harness, contains('trap cleanup EXIT'));
      expect(harness, contains(r'rm -rf -- "$MUSIC_DIR"'));
      expect(harness, contains(r'rm -rf -- "$SIBLING_DIR"'));
      expect(harness, contains('--delete-data'));
    });

    test('CI runs it against the packaged app', () {
      expect(
        workflow,
        contains(
          'bash ../scripts/flatpak_local_library_smoke.sh repo-sandbox-smoke',
        ),
      );
    });
  });
}
