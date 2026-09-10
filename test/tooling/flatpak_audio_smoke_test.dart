import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardrails for the Flatpak audio playback smoke (#446).
///
/// The smoke itself only runs on a runner with flatpak-builder, which is a
/// 90-minute job. These read the harness, the lifecycle tool and the workflow
/// as text so the properties that make that job *mean* something — the libmpv
/// identity check, the negative control, the absence of credentials — cannot be
/// dropped in a PR that never triggers the heavy build.
void main() {
  late String harness;
  late String lifecycle;
  late String workflow;

  setUpAll(() {
    harness = File('scripts/flatpak_audio_smoke.sh').readAsStringSync();
    lifecycle = File('tool/linux_audio_backend_smoke.dart').readAsStringSync();
    workflow = File('.github/workflows/flatpak-build.yml').readAsStringSync();
  });

  group('lifecycle tool', () {
    test('walks every transport step the issue asks for', () {
      for (final String step in <String>[
        'controller.playTrack(',
        'controller.play()',
        'controller.pause()',
        'controller.seek(',
        'controller.stop()',
        'controller.dispose()',
      ]) {
        expect(
          lifecycle,
          contains(step),
          reason: '$step is part of the lifecycle #446 asks the smoke to prove',
        );
      }
    });

    // A status flag flipping is not playback, and "paused" that keeps counting
    // is not a pause. Both assertions are about the clock, not the label.
    test('asserts the position moves, and then stops moving', () {
      expect(lifecycle, contains('state.position > Duration.zero'));
      expect(lifecycle, contains('the position never advanced past zero'));
      expect(lifecycle, contains('while paused'));
      expect(lifecycle, contains('_pauseDriftAllowance'));
    });

    test('proves a seek moved the decoder, not just the reported position', () {
      expect(lifecycle, contains('state.position > _seekTarget'));
      expect(
        lifecycle,
        contains('playback did not continue past'),
        reason: 'playing on from the seek point is what distinguishes a real '
            'seek from a position report',
      );
    });

    // The whole point of running inside the sandbox: if a host libmpv can
    // answer for the packaged one, a package that ships none still passes.
    test('reads back which libmpv the loader actually opened', () {
      expect(lifecycle, contains('/proc/self/maps'));
      expect(
        lifecycle,
        contains('LINTHRA_AUDIO_SMOKE_REQUIRE_LIBMPV_PREFIX'),
      );
      expect(lifecycle, contains('no libmpv is mapped into this process'));
    });

    test('needs no credential and no network', () {
      expect(lifecycle, isNot(contains('http://')));
      expect(lifecycle, isNot(contains('https://')));
      expect(lifecycle, contains('Directory.systemTemp.createTemp'));
    });

    test('sanitizes failure output before printing it', () {
      expect(lifecycle, contains('sanitizer.clean(error.toString())'));
      expect(lifecycle, contains('sanitizer.clean(stackTrace.toString())'));
      expect(lifecycle, contains(r"'/home/<user>'"));
      expect(lifecycle, contains(r"'/run/user/<uid>'"));
    });
  });

  group('sandbox harness', () {
    test('installs only from the local repository built in the same run', () {
      expect(harness, contains(r'REMOTE_NAME="linthra-audio-smoke-$$"'));
      expect(harness, contains('--no-gpg-verify'));
      expect(harness, contains(r'flatpak --user install -y "$REMOTE_NAME"'));
      expect(harness, isNot(contains('https://')));
      expect(harness, isNot(contains('curl ')));
      expect(harness, isNot(contains('wget ')));
    });

    test('never touches a Linthra installation it did not make', () {
      expect(harness, contains(r'flatpak --user info "$APP_ID"'));
      expect(harness, contains(r'flatpak --system info "$APP_ID"'));
      expect(harness, contains(r'$APP_ID is already installed'));
      expect(harness, contains('trap cleanup EXIT'));
      expect(harness, contains('--delete-data'));
    });

    test('requires the packaged libmpv', () {
      expect(
        harness,
        contains('--env=LINTHRA_AUDIO_SMOKE_REQUIRE_LIBMPV_PREFIX=/app/'),
      );
      expect(harness, contains("grep -q 'libmpv in use: /app/'"));
    });

    // A smoke that cannot fail proves nothing. Both ways this one is supposed
    // to catch a broken package are exercised deliberately, and a control that
    // passes has to fail the job.
    test('runs negative controls, and a passing one fails the job', () {
      expect(harness, contains('expect_failure()'));
      expect(
        harness,
        contains(
            r'fail "the smoke passed $what, so it cannot detect a broken package"'),
      );
      // A control that could not be set up is not a control that passed.
      expect(harness, contains('could not set up the negative control'));
      expect(harness, contains('never mentioned'));
    });

    // The first attempt used a zero-byte file and CI proved it wrong: the
    // loader skips a candidate with a bad ELF header and finds the packaged
    // library anyway. The donor has to be a library that really loads.
    test('shadows libmpv with a real library, not a broken file', () {
      expect(harness, contains(r'cp -L "$donor" "$shadow/libmpv.so.2"'));
      expect(harness, contains(r'LD_LIBRARY_PATH="$shadow'));
      expect(
        harness,
        isNot(contains(r': >"$shadow/libmpv.so.2"')),
        reason: 'a zero-byte shadow is skipped by the loader, not loaded',
      );
    });

    test('proves the libmpv identity check itself fires', () {
      expect(
        harness,
        contains(
          '--env=LINTHRA_AUDIO_SMOKE_REQUIRE_LIBMPV_PREFIX='
          '/nowhere-a-package-installs/',
        ),
        reason: 'a positive run only means something if the check can fail',
      );
    });

    test('sanitizes everything it prints', () {
      expect(harness, contains('sanitize()'));
      expect(harness, contains('/run/user/<uid>'));
      expect(harness, contains('/home/<user>'));
      expect(harness, contains(r'sanitize <"$LOG_FILE"'));
    });
  });

  group('workflow', () {
    test('builds the derived manifest and runs the smoke against it', () {
      expect(
        workflow,
        contains('python3 scripts/make_flatpak_smoke_manifest.py'),
      );
      expect(
        workflow,
        contains('io.github.thezupzup.linthra.sandbox-smoke.yml'),
      );
      expect(
        workflow,
        contains('bash ../scripts/flatpak_audio_smoke.sh repo-sandbox-smoke'),
      );
    });

    // The submission build stays a separate job on the untouched manifest, so
    // the package Flathub would get is still built and launched on every run.
    test('keeps the submission manifest building on its own', () {
      expect(workflow, contains('--repo=repo-ci'));
      expect(
        workflow,
        contains('bash ../scripts/flatpak_launch_smoke.sh repo-ci'),
      );
    });

    test('stays read-only and secret-free', () {
      expect(workflow, contains('permissions:\n  contents: read'));
      expect(workflow, isNot(contains(r'secrets.')));
    });
  });
}
