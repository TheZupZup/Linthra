import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardrails for the Flatpak audio playback smoke (#446).
///
/// The smoke itself only runs on a runner with flatpak-builder, which is a
/// 90-minute job. These read the harness, the lifecycle tool and the workflow
/// as text so the properties that make that job *mean* something (the libmpv
/// identity check, the negative control, the absence of credentials) cannot be
/// dropped in a PR that never triggers the heavy build.
void main() {
  late String harness;

  /// The harness with its comments stripped.
  ///
  /// It explains at length which flag it deliberately does *not* use, so a
  /// check for `--delete-data` has to read the commands rather than the prose
  /// about them.
  late String harnessCommands;
  late String lifecycle;
  late String workflow;

  setUpAll(() {
    harness = File('scripts/flatpak_audio_smoke.sh').readAsStringSync();
    harnessCommands = harness
        .split('\n')
        .where((String line) => !line.trimLeft().startsWith('#'))
        .join('\n');
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

    // Measured from where the seek landed, not from the target: the tolerance
    // band accepts a position slightly past the target, so re-comparing with
    // the target would be true before playback resumed.
    test('proves a seek moved the decoder, not just the reported position', () {
      expect(lifecycle, contains('final Duration landedAt'));
      expect(lifecycle, contains('state.position > landedAt'));
      expect(lifecycle, contains('state.status == PlaybackStatus.playing &&'));
      expect(
        lifecycle,
        contains('where the seek '),
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
      expect(harness, contains(r'flatpak --user uninstall -y "$APP_ID"'));
    });

    // An installed build and an app-data tree are two different questions
    // (#629). The refusal above answers the first. `uninstall --delete-data`
    // reached past it: an ordinary uninstall leaves ~/.var/app/<app id>/ in
    // place, so a contributor who removed an older build still has their
    // library database, settings, offline audio and credentials there while
    // nothing is installed, and the flag also drops the app's Flatpak
    // permission-store entries, where the document-portal grants for their
    // music folders live.
    test('deletes app data only when this run created it', () {
      expect(
        harnessCommands,
        isNot(contains('--delete-data')),
        reason: 'a guard about the data tree cannot authorise an action that '
            'also clears the permission store',
      );
      expect(harness, contains(r'APP_DATA_DIR="$HOME/.var/app/$APP_ID"'));
      expect(
        harness,
        contains(r'[[ -e "$APP_DATA_DIR" ]] && APP_DATA_EXISTED=1'),
      );
      expect(harness, contains('(( ! APP_DATA_EXISTED ))'));
      expect(harness, contains(r'rm -rf -- "$APP_DATA_DIR"'));
      // Asked before installing, because after the install the answer is
      // always yes.
      expect(
        harness.indexOf('APP_DATA_EXISTED=1'),
        lessThan(harness.indexOf('flatpak --user install')),
      );
    });

    // The shadow library used to be cleaned up as a side effect of deleting
    // the whole tree. When the tree is somebody else's and stays, the one
    // directory this run put inside it has to go by name.
    test('removes the shadow directory even when the data tree stays', () {
      expect(
        harness,
        contains(r'SHADOW_HOST_DIR="$APP_DATA_DIR/cache/$SHADOW_DIR_NAME"'),
      );
      // One name, passed into the sandbox rather than written twice.
      expect(harness, contains(r'sh "$SMOKE_COMMAND" "$SHADOW_DIR_NAME"'));
      // The sandbox's own cache directory, which Flatpak maps to the `cache/`
      // subdirectory of the host tree the cleanup reads.
      expect(harness, contains(r'shadow="$XDG_CACHE_HOME/$2"'));
      expect(harness, contains(r'rm -rf -- "$SHADOW_HOST_DIR"'));
      // Marked before the control runs: a control that died halfway still
      // left a directory behind.
      expect(
        harness.indexOf('SHADOW_CREATED=1'),
        lessThan(harness.indexOf('expect_failure "a libmpv that carries')),
      );
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

    // The first attempt used a zero-byte file under one name, and CI proved
    // both halves wrong: an unreadable ELF header is skipped rather than
    // loaded, and media_kit tries "libmpv.so" before "libmpv.so.2", so the
    // real library was opened before the shadow was consulted at all.
    test('shadows every name media_kit will try, with a library that loads',
        () {
      expect(
          harness, contains('for soname in libmpv.so libmpv.so.2 libmpv.so.1'));
      expect(harness, contains(r'cp -L "$donor" "$shadow/$soname"'));
      expect(harness, contains(r'LD_LIBRARY_PATH="$shadow'));
      expect(
        harness,
        isNot(contains(r': >"$shadow/libmpv.so')),
        reason: 'a zero-byte shadow is skipped by the loader, not loaded',
      );
    });

    // The packaged app hangs on a library that loads under libmpv's name but
    // exports none of its symbols, so what this control proves is that such a
    // library cannot produce a *passing* smoke. The other control still has to
    // fail promptly and say why.
    test('the shadow control is bounded and the identity control is named', () {
      expect(
        harness,
        contains(
          "expect_failure \"a libmpv that carries none of mpv's symbols\" "
          "'libmpv' bounded",
        ),
      );
      expect(
        harness,
        contains(
          "expect_failure \"a libmpv loaded outside the required prefix\" "
          "'libmpv' named",
        ),
      );
      // `bounded` must never be a licence to hang: an exit-0 run still fails.
      expect(
        harness,
        contains(
            r'fail "the smoke passed $what, so it cannot detect a broken package"'),
      );
      expect(
        harness,
        contains(r'fail "the smoke hung $what and was killed after'),
        reason: 'a named control that hangs is still a failure',
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

    // A job that hangs reports nothing at all: GitHub does not serve a job's
    // log until it ends, so an unbounded run costs the full job timeout and
    // leaves nothing to read.
    test('bounds every sandbox run, and treats hitting the bound as failure',
        () {
      expect(harness, contains('bounded_run()'));
      expect(harness, contains('RUN_TIMEOUT_SECONDS'));
      expect(harness, contains('timeout --signal=TERM --kill-after=30'));
      expect(harness, contains('hung inside the sandbox and was killed'));
      // The install probe is a `flatpak run` too, and sandbox startup is
      // exactly where a stall would go unnoticed.
      expect(harness, contains('bounded_run flatpak run --command=sh'));
      expect(harness, contains(r'fail "checking for $SMOKE_COMMAND hung'));
      expect(
        harness,
        contains(r'fail "the smoke hung $what and was killed after'),
        reason: 'a control that hung is not a control that failed correctly',
      );
      expect(
        harness,
        isNot(contains("  xvfb-run --auto-servernum --server-args='-screen 0 "
            "1280x720x24' \\\n  dbus-run-session -- \\\n  flatpak run \\\n"
            "  --env=LINTHRA_AUDIO_SMOKE_AO")),
        reason: 'the positive run must go through bounded_run too',
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
    // A change to the Linux playback stack can break only inside the sandbox,
    // which is the regression this job exists to catch, so the smoke's own
    // imports have to be able to trigger it.
    test('triggers on the audio implementation the smoke imports', () {
      expect(
        workflow,
        contains("- 'lib/core/services/linux_playback_controller.dart'"),
      );
      expect(
        workflow,
        contains("- 'lib/core/services/just_audio_playback_controller.dart'"),
      );
    });

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
