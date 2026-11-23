import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Guardrails for the automatic Flutter SDK updater (issue #362).
///
/// The updater is allowed to do exactly one thing: notice that the official
/// stable channel has moved past `.flutter-version` and propose the new number.
/// Everything else about it is a safety boundary —
///
///   * it follows the *stable* channel only, and only bare `MAJOR.MINOR.PATCH`
///     releases published under a `stable/` archive;
///   * it classifies the gap as patch, minor or major, and fails loudly on data
///     it cannot trust rather than guessing a target;
///   * it never proposes a downgrade;
///   * a patch or minor opens one reusable draft PR that changes
///     `.flutter-version` and nothing else — not application code, not tests,
///     not `pubspec.lock`, not the release surface;
///   * a major changes nothing at all and files an issue instead;
///   * it never merges, and the PR it opens runs the normal CI;
///   * the Flutter CI fixer leaves its branch alone, so an SDK bump that needs
///     an API migration stays red for a human.
///
/// Those boundaries are the whole value of the updater, so they are tests
/// rather than review notes. Every case here is offline: the classification
/// tests feed fixture release manifests to the checker instead of touching the
/// network, and nothing in this suite changes Linthra's actual Flutter pin.
///
/// Sibling coverage: test/tooling/dependency_update_guardrails_test.dart does
/// the same for the Dart package updater (and holds the line that *its*
/// allowlist stays `pubspec.lock`-only), and
/// test/tooling/toolchain_pins_test.dart pins the toolchain versions.
void main() {
  final String root = _repoRoot();

  final String checker = p.join(root, 'scripts', 'check_flutter_sdk_update.py');
  final String guardScript =
      p.join(root, 'scripts', 'check_dependency_update_files.sh');
  late final String workflow =
      _read(root, p.join('.github', 'workflows', 'flutter-sdk-updates.yml'));
  late final String ci = _read(root, p.join('.github', 'workflows', 'ci.yml'));
  late final String fixer =
      _read(root, p.join('.github', 'workflows', 'flutter-ci-fixer.yml'));
  late final String docs =
      _read(root, p.join('docs', 'development', 'dependency-updates.md'));

  setUpAll(() {
    expect(File(checker).existsSync(), isTrue,
        reason: 'The update checker is missing: $checker');
    final ProcessResult python =
        Process.runSync('python3', <String>['--version']);
    expect(python.exitCode, 0,
        reason: 'python3 is not on PATH; the SDK update checker requires it.');
  });

  // ---------------------------------------------------------------------------
  // Classification. CURRENT comes from .flutter-version (or --current); LATEST
  // is the newest usable stable release in the manifest.
  // ---------------------------------------------------------------------------
  group('classifying the gap between the pin and stable', () {
    test('the same version is no update', () {
      final _Result r = _check(checker, current: '1.2.3', stable: <String>[
        '1.2.3',
        '1.2.2',
        '1.1.9',
      ]);
      expect(r.exitCode, 0, reason: r.describe());
      expect(r.status, 'up-to-date');
      expect(r.value('latest'), '1.2.3');
    });

    test('a newer patch on the same minor is a patch update', () {
      final _Result r = _check(checker, current: '1.2.3', stable: <String>[
        '1.2.4',
        '1.2.3',
      ]);
      expect(r.exitCode, 0, reason: r.describe());
      expect(r.status, 'patch');
      expect(r.value('latest'), '1.2.4');
    });

    test('a newer minor on the same major is a minor update', () {
      final _Result r = _check(checker, current: '1.2.3', stable: <String>[
        '1.3.0',
        '1.2.9',
      ]);
      expect(r.exitCode, 0, reason: r.describe());
      expect(r.status, 'minor');
      expect(r.value('latest'), '1.3.0');
    });

    test('a minor jump of several lines is still a minor update', () {
      // The real case this updater was written for: the pin sits on one stable
      // line and the channel has already moved two lines past it.
      final _Result r = _check(checker, current: '1.2.3', stable: <String>[
        '1.5.0',
        '1.2.9',
        '1.2.3',
      ]);
      expect(r.exitCode, 0, reason: r.describe());
      expect(r.status, 'minor');
      expect(r.value('latest'), '1.5.0');
    });

    test('a newer major is a major update', () {
      final _Result r = _check(checker, current: '1.2.3', stable: <String>[
        '2.0.0',
        '1.2.9',
      ]);
      expect(r.exitCode, 0, reason: r.describe());
      expect(r.status, 'major');
      expect(r.value('latest'), '2.0.0');
    });

    test('a major update still reports the newest release on the old major',
        () {
      // The workflow files an issue and changes nothing for a major, so the
      // maintainer should still be able to see what the current line is on.
      final _Result r = _check(checker, current: '1.2.3', stable: <String>[
        '2.0.0',
        '1.2.9',
      ]);
      expect(r.status, 'major');
      expect(r.value('latest_in_current_major'), '1.2.9');
    });

    test('the highest version wins regardless of manifest order', () {
      // A hotfix on an older line can be published after a newer line exists,
      // so "first entry in the array" is not a safe answer.
      for (final List<String> order in <List<String>>[
        <String>['1.2.9', '1.5.0', '1.4.0'],
        <String>['1.4.0', '1.2.9', '1.5.0'],
        <String>['1.5.0', '1.4.0', '1.2.9'],
      ]) {
        final _Result r = _check(checker, current: '1.2.3', stable: order);
        expect(r.exitCode, 0, reason: r.describe());
        expect(r.value('latest'), '1.5.0',
            reason: 'Order ${order.join(', ')} chose ${r.value('latest')}.');
      }
    });

    test('--latest classifies two versions with no manifest at all', () {
      // The workflow uses this to compare the version already on its update
      // branch against the version it is about to propose.
      const Map<String, String> expected = <String, String>{
        '1.2.3': 'up-to-date',
        '1.2.4': 'patch',
        '1.3.0': 'minor',
        '2.0.0': 'major',
      };
      expected.forEach((String latest, String status) {
        final _Result r = _run(checker, <String>[
          '--current',
          '1.2.3',
          '--latest',
          latest,
          '--json',
        ]);
        expect(r.exitCode, 0, reason: r.describe());
        expect(r.status, status);
        // Nothing was checked against the channel, and it must not claim it was.
        expect(r.value('stable_confirmed'), 'false');
      });
    });

    test('the pin file is what is read when --current is omitted', () {
      final String pin =
          File(p.join(root, '.flutter-version')).readAsStringSync().trim();
      final _Result r = _run(
          checker, <String>['--latest', pin, '--json', '--repo-root', root]);
      expect(r.exitCode, 0, reason: r.describe());
      expect(r.value('current'), pin,
          reason: 'The checker must read .flutter-version as CURRENT.');
      expect(r.status, 'up-to-date');
    });
  });

  // ---------------------------------------------------------------------------
  // Release selection: stable only, and only releases shaped like releases.
  // ---------------------------------------------------------------------------
  group('following the stable channel and nothing else', () {
    test('a higher beta release never becomes the target', () {
      final _Result r = _check(
        checker,
        current: '1.2.3',
        stable: <String>['1.2.4'],
        extra: <Map<String, dynamic>>[
          _release('9.9.9', channel: 'beta', archive: 'beta/linux/x.tar.xz'),
          _release('1.3.0', channel: 'beta', archive: 'beta/linux/x.tar.xz'),
        ],
      );
      expect(r.exitCode, 0, reason: r.describe());
      expect(r.value('latest'), '1.2.4',
          reason: 'A beta release must never be proposed as a stable update.');
      expect(r.status, 'patch');
    });

    test('dev and master releases are ignored too', () {
      final _Result r = _check(
        checker,
        current: '1.2.3',
        stable: <String>['1.2.4'],
        extra: <Map<String, dynamic>>[
          _release('8.0.0', channel: 'dev', archive: 'dev/linux/x.tar.xz'),
          _release('9.0.0',
              channel: 'master', archive: 'master/linux/x.tar.xz'),
        ],
      );
      expect(r.exitCode, 0, reason: r.describe());
      expect(r.value('latest'), '1.2.4');
    });

    test('a pre-release version on the stable channel is skipped', () {
      // `-0.N.pre` builds are how Flutter labels pre-releases; a stable row
      // carrying one is not a version this updater can pin to.
      final _Result r = _check(
        checker,
        current: '1.2.3',
        stable: <String>['1.2.4'],
        extra: <Map<String, dynamic>>[
          _release('1.9.0-0.1.pre'),
          _release('1.8.0-hotfix.2'),
        ],
      );
      expect(r.exitCode, 0, reason: r.describe());
      expect(r.value('latest'), '1.2.4');
    });

    test('legacy `v`-prefixed and `+hotfix` stable tags are skipped', () {
      // The official manifest still carries these from the 1.x era. They are
      // not comparable triples, and they are all far below any usable pin.
      final _Result r = _check(
        checker,
        current: '1.2.3',
        stable: <String>['1.2.4'],
        extra: <Map<String, dynamic>>[
          _release('v1.12.13+hotfix.9'),
          _release('v1.2.1'),
        ],
      );
      expect(r.exitCode, 0, reason: r.describe());
      expect(r.value('latest'), '1.2.4');
    });

    test('a stable row whose archive is not under stable/ is refused', () {
      final _Result r = _check(
        checker,
        current: '1.2.3',
        stable: <String>['1.2.4'],
        extra: <Map<String, dynamic>>[
          _release('7.0.0',
              archive: 'beta/linux/flutter_linux_7.0.0-beta.tar.xz'),
        ],
      );
      expect(r.exitCode, 0, reason: r.describe());
      expect(r.value('latest'), '1.2.4',
          reason: 'A row that claims stable but ships a non-stable archive '
              'contradicts itself and must not be selected.');
      expect(r.value('notes'), contains('archive is not under stable/'));
    });

    // A row that names no archive at all is no more installable than one
    // pointing outside stable/, so the three shapes below are refused for the
    // same reason. Each claims stable at a version far above the pin, so a
    // regression that lets one through surfaces immediately as `latest`.
    for (final MapEntry<String, Map<String, dynamic>> broken
        in <String, Map<String, dynamic>>{
      'a missing archive': _release('7.0.0')..remove('archive'),
      'a null archive': _release('7.0.1')..['archive'] = null,
      'an empty archive': _release('7.0.2')..['archive'] = '',
    }.entries) {
      test('a stable row with ${broken.key} is refused', () {
        final _Result r = _check(
          checker,
          current: '1.2.3',
          stable: <String>['1.2.4'],
          extra: <Map<String, dynamic>>[broken.value],
        );
        expect(r.exitCode, 0, reason: r.describe());
        expect(r.value('latest'), '1.2.4',
            reason: 'A stable row naming no archive under stable/ cannot be '
                'confirmed installable by the pinned setup path, so it must '
                'never be proposed.');
        expect(r.value('notes'), contains('archive is not under stable/'));
      });
    }

    test('a stable row under stable/ is still a candidate', () {
      // The other half of the rule: tightening it must not start rejecting
      // the ordinary rows the manifest is made of.
      final _Result r = _check(
        checker,
        current: '1.2.3',
        stable: <String>['1.2.4'],
        extra: <Map<String, dynamic>>[
          _release('7.0.0',
              archive: 'stable/linux/flutter_linux_7.0.0-stable.tar.xz'),
        ],
      );
      expect(r.exitCode, 0, reason: r.describe());
      expect(r.value('latest'), '7.0.0');
      expect(r.value('latest_archive'),
          'stable/linux/flutter_linux_7.0.0-stable.tar.xz');
    });

    test('a manifest whose only stable rows lack an archive is an error', () {
      // Fail-safe: no usable candidate is a hard error, not a silent
      // "up-to-date" that would hide a stalled updater.
      final _Result r = _runWithManifest(
        checker,
        const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
          'base_url':
              'https://storage.googleapis.com/flutter_infra_release/releases',
          'current_release': <String, String>{'stable': 'hash-stable-1.2.4'},
          'releases': <Map<String, dynamic>>[
            _release('1.2.4')..remove('archive'),
            _release('1.3.0')..['archive'] = null,
          ],
        }),
        <String>['--current', '1.2.3', '--json'],
      );
      expect(r.exitCode, isNot(0), reason: r.describe());
      expect(r.stderr, contains('no usable `stable` release'));
    });

    test('reaching a target at all is the stable-channel confirmation', () {
      final _Result r =
          _check(checker, current: '1.2.3', stable: <String>['1.3.0']);
      expect(r.value('stable_confirmed'), 'true');
      expect(r.value('latest_archive'), contains('stable/'));
      expect(r.value('latest_hash'), isNotEmpty);
    });

    test('the manifest stable pointer is cross-checked, not obeyed blindly',
        () {
      // If current_release.stable lags the highest published stable version,
      // the higher version still wins — and the disagreement is reported.
      final _Result r = _check(
        checker,
        current: '1.2.3',
        stable: <String>['1.5.0', '1.4.0'],
        stableHashFor: '1.4.0',
      );
      expect(r.exitCode, 0, reason: r.describe());
      expect(r.value('latest'), '1.5.0');
      expect(r.value('pointer_version'), '1.4.0');
      expect(r.value('notes'), contains('using the highest version'));
    });
  });

  // ---------------------------------------------------------------------------
  // Failing loudly. Every case here must exit non-zero — never "no update".
  // ---------------------------------------------------------------------------
  group('untrustworthy data fails loudly instead of guessing', () {
    test('the checker never proposes a downgrade', () {
      final _Result r = _check(checker, current: '2.0.0', stable: <String>[
        '1.9.9',
        '1.9.8',
      ]);
      expect(r.exitCode, isNot(0),
          reason: 'A stable channel behind our pin must fail, not silently '
              'report "up to date".\n${r.describe()}');
      expect(r.stderr, contains('downgrade'));
    });

    test('a downgrade is refused in --latest mode too', () {
      final _Result r = _run(checker,
          <String>['--current', '1.3.0', '--latest', '1.2.9', '--json']);
      expect(r.exitCode, isNot(0), reason: r.describe());
      expect(r.stderr, contains('downgrade'));
    });

    for (final String bad in <String>[
      '1.2',
      '1',
      '',
      'v1.2.3',
      '1.2.3-hotfix.1',
      '1.2.3.4',
      'stable',
      '1.2.x',
    ]) {
      test('a malformed pin (${bad.isEmpty ? '<empty>' : bad}) is rejected',
          () {
        final _Result r =
            _check(checker, current: bad, stable: <String>['9.9.9']);
        expect(r.exitCode, isNot(0),
            reason: 'A pin the checker cannot parse must stop the run.\n'
                '${r.describe()}');
        expect(r.stderr, contains('--current'));
      });
    }

    test('a malformed --latest is rejected', () {
      final _Result r =
          _run(checker, <String>['--current', '1.2.3', '--latest', '1.3']);
      expect(r.exitCode, isNot(0), reason: r.describe());
      expect(r.stderr, contains('--latest'));
    });

    test('a manifest that is not JSON is rejected', () {
      final _Result r = _runWithManifest(
          checker, 'not json at all', <String>['--current', '1.2.3', '--json']);
      expect(r.exitCode, isNot(0), reason: r.describe());
      expect(r.stderr, contains('not valid JSON'));
    });

    test('a manifest that is not an object is rejected', () {
      final _Result r = _runWithManifest(
          checker, '[]', <String>['--current', '1.2.3', '--json']);
      expect(r.exitCode, isNot(0), reason: r.describe());
      expect(r.stderr, contains('not a JSON object'));
    });

    test('a manifest with no releases array is rejected', () {
      final _Result r = _runWithManifest(checker, '{"current_release": {}}',
          <String>['--current', '1.2.3', '--json']);
      expect(r.exitCode, isNot(0), reason: r.describe());
      expect(r.stderr, contains('releases'));
    });

    test('an empty releases array is rejected', () {
      final _Result r = _runWithManifest(checker, '{"releases": []}',
          <String>['--current', '1.2.3', '--json']);
      expect(r.exitCode, isNot(0), reason: r.describe());
      expect(r.stderr, contains('no releases'));
    });

    test('a release entry that is not an object is rejected', () {
      final _Result r = _runWithManifest(checker, '{"releases": ["3.0.0"]}',
          <String>['--current', '1.2.3', '--json']);
      expect(r.exitCode, isNot(0), reason: r.describe());
      expect(r.stderr, contains('not an object'));
    });

    test('a manifest with no usable stable release is rejected', () {
      final _Result r = _check(
        checker,
        current: '1.2.3',
        stable: const <String>[],
        extra: <Map<String, dynamic>>[
          _release('1.9.0', channel: 'beta', archive: 'beta/linux/x.tar.xz'),
        ],
      );
      expect(r.exitCode, isNot(0),
          reason: 'No stable release means no answer, not "up to date".\n'
              '${r.describe()}');
      expect(r.stderr, contains('no usable'));
    });

    test('a missing manifest file is rejected', () {
      final _Result r = _run(checker, <String>[
        '--current',
        '1.2.3',
        '--releases-file',
        p.join(root, 'does-not-exist.json'),
      ]);
      expect(r.exitCode, isNot(0), reason: r.describe());
      expect(r.stderr, contains('not found'));
    });

    test('a non-https manifest URL is refused', () {
      final _Result r = _run(checker, <String>[
        '--current',
        '1.2.3',
        '--releases-url',
        'http://example.com/releases.json',
      ]);
      expect(r.exitCode, isNot(0),
          reason:
              'The release manifest must come over https.\n${r.describe()}');
      expect(r.stderr, contains('https'));
    });
  });

  group('the checker reports itself to the workflow', () {
    test('--github-output writes plain key=value lines', () {
      final Directory tmp = Directory.systemTemp.createTempSync('sdk-out');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final String out = p.join(tmp.path, 'out.txt');
      final _Result r = _run(checker, <String>[
        '--current',
        '1.2.3',
        '--latest',
        '1.3.0',
        '--github-output',
        out,
        '--quiet',
      ]);
      expect(r.exitCode, 0, reason: r.describe());
      final Map<String, String> parsed = <String, String>{
        for (final String line in File(out).readAsLinesSync())
          if (line.contains('=')) line.split('=').first: line.split('=').last,
      };
      expect(parsed['status'], 'minor');
      expect(parsed['current'], '1.2.3');
      expect(parsed['latest'], '1.3.0');
    });

    test('the checker never writes the pin file itself', () {
      // Detection and publication are separate on purpose: the script only
      // classifies, so nothing it does can move the repo's pin.
      final String source = File(checker).readAsStringSync();
      for (final String forbidden in <String>[
        'write_text',
        'git commit',
        'git push',
        'gh pr create',
        'gh issue create',
      ]) {
        expect(source.contains(forbidden), isFalse,
            reason: 'scripts/check_flutter_sdk_update.py contains '
                '`$forbidden`. It may only read and classify; publishing '
                'belongs to the workflow.');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // The file allowlist. A bot PR on the SDK branch may carry one file.
  // ---------------------------------------------------------------------------
  group('the allowlist guard admits only the Flutter pin', () {
    test('.flutter-version alone passes', () {
      final ProcessResult r =
          _runGuard(guardScript, 'flutter-sdk', <String>['.flutter-version']);
      expect(r.exitCode, 0, reason: 'stdout: ${r.stdout}\nstderr: ${r.stderr}');
    });

    test('an empty change set passes', () {
      final ProcessResult r =
          _runGuard(guardScript, 'flutter-sdk', const <String>[]);
      expect(r.exitCode, 0, reason: 'stdout: ${r.stdout}\nstderr: ${r.stderr}');
    });

    // One case per rule the issue spells out. If someone widens the allowlist,
    // the specific protection they removed is named in the failure.
    const Map<String, String> forbidden = <String, String>{
      'pubspec.lock': 'the resolved dependency set (a human re-resolves it)',
      'pubspec.yaml': 'dependency constraints and the Dart SDK constraint',
      'lib/main.dart': 'application code',
      'lib/core/app_info.dart': 'the in-app version',
      'test/core/app_info_version_test.dart': 'test code',
      'metadata/io.github.thezupzup.linthra.yml': 'F-Droid metadata',
      'fastlane/metadata/android/en-US/changelogs/201999.txt': 'Fastlane files',
      'docs/release-notes/v0.2.1.md': 'release notes',
      'android/key.properties': 'signing configuration',
      'android/app/linthra-release.jks': 'signing material',
      'LICENSE': 'the license',
      '.java-version': 'the JDK pin',
      'android/settings.gradle': 'the AGP and Kotlin pins',
      'android/gradle/wrapper/gradle-wrapper.properties': 'the Gradle pin',
      '.github/workflows/ci.yml': 'CI configuration',
      'scripts/check_dependency_update_files.sh': 'the guard itself',
    };

    forbidden.forEach((String path, String why) {
      test('$path is rejected — $why', () {
        final ProcessResult r = _runGuard(
            guardScript, 'flutter-sdk', <String>['.flutter-version', path]);
        expect(r.exitCode, isNot(0),
            reason: 'An automatic Flutter SDK update must not change $why.\n'
                'stdout: ${r.stdout}');
        expect(r.stderr, contains(path),
            reason: 'The rejection should name the offending path.');
      });
    });

    test('the two update kinds cannot reach into each other', () {
      // The Dart updater owns pubspec.lock; the SDK updater owns
      // .flutter-version. Neither allowlist may grow the other's file.
      final ProcessResult sdkTouchingLock =
          _runGuard(guardScript, 'flutter-sdk', <String>['pubspec.lock']);
      expect(sdkTouchingLock.exitCode, isNot(0),
          reason: 'An SDK bump must not re-resolve the lockfile; that is a '
              'human decision, because the committed lockfile is what the '
              'reproducible F-Droid build resolves from.');

      final ProcessResult dartTouchingPin =
          _runGuard(guardScript, 'dart-packages', <String>['.flutter-version']);
      expect(dartTouchingPin.exitCode, isNot(0),
          reason: 'A package update must not move the toolchain pin.');
    });

    test('the Dart updater is still lockfile-only, by default and by name', () {
      // The --kind option must not have loosened the original guard: with no
      // --kind at all, and with --kind dart-packages, the answer is the same.
      for (final List<String> argv in <List<String>>[
        <String>['pubspec.lock'],
        <String>['--kind', 'dart-packages', 'pubspec.lock'],
      ]) {
        final ProcessResult ok = Process.runSync(
            'bash',
            <String>[
              guardScript,
              ...argv,
            ],
            stdoutEncoding: const SystemEncoding(),
            stderrEncoding: const SystemEncoding());
        expect(ok.exitCode, 0, reason: 'stderr: ${ok.stderr}');
      }
      for (final String path in <String>[
        '.flutter-version',
        'lib/main.dart',
        'pubspec.yaml',
      ]) {
        final ProcessResult bad = Process.runSync(
            'bash', <String>[guardScript, 'pubspec.lock', path],
            stdoutEncoding: const SystemEncoding(),
            stderrEncoding: const SystemEncoding());
        expect(bad.exitCode, isNot(0),
            reason: 'The default (dart-packages) allowlist must still reject '
                '$path.');
      }
    });

    test('an unknown kind fails instead of allowing everything', () {
      final ProcessResult r =
          _runGuard(guardScript, 'anything-goes', <String>['lib/main.dart']);
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('unknown --kind'));
    });
  });

  // ---------------------------------------------------------------------------
  // The workflow.
  // ---------------------------------------------------------------------------
  group('the update workflow stays inside its boundaries', () {
    test('it runs weekly and can be dispatched by hand', () {
      expect(workflow, contains('schedule:'));
      expect(workflow, contains('cron:'));
      expect(workflow, contains('workflow_dispatch:'),
          reason: 'A manual run must be possible, using the same logic.');
    });

    test('detection is delegated to the testable script', () {
      expect(workflow, contains('scripts/check_flutter_sdk_update.py'),
          reason: 'The version comparison must not live in YAML, where it '
              'cannot be tested offline.');
    });

    test('it uses a toolchain branch, not the Dart package namespace', () {
      expect(workflow, contains('UPDATE_BRANCH: toolchain/flutter-sdk'),
          reason: 'A `deps/` branch would inherit the Dart updater\'s '
              'lockfile-only allowlist, which is the wrong rule for an SDK '
              'bump.');
      expect(workflow.contains('UPDATE_BRANCH: deps/'), isFalse);
    });

    test('its own GITHUB_TOKEN is read-only at the top level', () {
      expect(workflow, contains('permissions:\n  contents: read'),
          reason: 'Writes must be opted into per job, not granted globally.');
    });

    test('it never merges anything', () {
      for (final String forbidden in <String>[
        'gh pr merge',
        '--auto',
        '--admin',
        '--squash',
        '--rebase',
        'enable_pr_auto_merge',
      ]) {
        expect(workflow.contains(forbidden), isFalse,
            reason: 'The update workflow contains `$forbidden`. Nothing may '
                'ever merge into main automatically (#362).');
      }
    });

    test('it never migrates application code', () {
      // No SDK, no analyzer, no formatter, no test run, no code generation:
      // this workflow has no way to "fix" the repo even if it wanted to.
      for (final String forbidden in <String>[
        'setup-flutter',
        'dart format',
        'codex',
        'build_runner',
      ]) {
        expect(workflow.contains(forbidden), isFalse,
            reason: 'The SDK updater must not run `$forbidden`. A bump that '
                'breaks application code stays red for a human.');
      }
    });
  });

  group('the patch/minor PR job', () {
    late final String job = _jobSection(workflow, 'sdk-pr');

    test('it runs only for patch and minor updates', () {
      expect(job, contains("needs.check.outputs.status == 'patch'"));
      expect(job, contains("needs.check.outputs.status == 'minor'"));
      expect(job.contains("status == 'major'"), isFalse,
          reason: 'A major must not reach the PR path.');
    });

    test('it publishes with the dedicated token so the PR runs normal CI', () {
      // A push or PR made with GITHUB_TOKEN does not trigger workflows, and an
      // update PR that runs no checks is a broken updater (#362).
      expect(job, contains(r'secrets.DEPENDENCY_UPDATE_TOKEN'),
          reason: 'Reuse the existing publication secret rather than opening '
              'a PR that no CI would look at.');
      expect(job.contains(r'GH_TOKEN: ${{ github.token }}'), isFalse,
          reason: 'github.token cannot retrigger CI on the PR it opens.');
    });

    test('a missing token fails the run instead of opening an unchecked PR',
        () {
      expect(job, contains('DEPENDENCY_UPDATE_TOKEN is required'));
      expect(job, contains('exit 1'));
    });

    test('a run with no update never reaches the token check', () {
      // The requirement is a pair: fail loudly when publishing is needed, and
      // never fail a quiet week for want of a secret. Gating the whole job on
      // the classification is what delivers the second half.
      final String check = _jobSection(workflow, 'check');
      expect(check.contains('DEPENDENCY_UPDATE_TOKEN'), isFalse,
          reason: 'The detection job must not require the publication token; '
              'a week with no update must not fail.');
    });

    test('the PR is a draft against main', () {
      expect(job, contains('gh pr create'));
      expect(job, contains('--draft'),
          reason: 'SDK update PRs open as drafts for review.');
      expect(job, contains('--base main'));
    });

    test('it reuses one PR instead of opening duplicates every week', () {
      expect(job, contains('--state open --json number'),
          reason: 'The workflow must look for an existing open PR on the '
              'update branch and edit it rather than open another.');
      expect(job, contains('gh pr edit'));
    });

    test('it refuses to force-push over commits it did not write', () {
      expect(job, contains('--force-with-lease'),
          reason: 'A plain force push could drop a concurrent update.');
      expect(job, contains('foreign'),
          reason: 'The workflow must detect commits on the update branch that '
              'it did not author and stop instead of overwriting them.');
      expect(job, contains(r'"$author" == "github-actions[bot]"'),
          reason: 'Ownership is decided by author *and* subject, so a human '
              'commit on the branch is always foreign.');
    });

    test('it will not rewind its own branch to an older version', () {
      expect(job, contains('Refusing to rewind the open PR'),
          reason: 'If the branch already proposes something newer than the '
              'manifest just offered, the data is wrong — stop.');
    });

    test('it re-checks its own blast radius before committing', () {
      expect(
          job, contains('check_dependency_update_files.sh --kind flutter-sdk'),
          reason: 'The updater must verify the changed files before a commit '
              'exists, exactly as the Dart updater does.');
    });

    test('it writes the pin and nothing else', () {
      expect(job, contains('> .flutter-version'),
          reason: 'The whole change is one version string in one file.');
      expect(job, contains('git add .flutter-version'));
      expect(job.contains('git add -A'), isFalse);
      expect(job.contains('git add .\n'), isFalse);
      expect(job.contains('git add pubspec'), isFalse);
    });

    test('the PR body carries everything a reviewer needs', () {
      for (final String required in <String>[
        'Currently pinned',
        'Proposed',
        'Stable channel',
        'confirmed',
        'may be red',
        'F-Droid',
        'reproducib',
        'auto-merge',
        '#362',
      ]) {
        expect(job, contains(required),
            reason: 'The PR body must mention "$required".');
      }
    });
  });

  group('the major update job', () {
    late final String job = _jobSection(workflow, 'major-issue');

    test('it runs only for a major update', () {
      expect(job, contains("needs.check.outputs.status == 'major'"));
    });

    test('it files an issue and opens no PR', () {
      expect(job, contains('gh issue create'));
      expect(job, contains('gh issue edit'));
      expect(job.contains('gh pr create'), isFalse,
          reason: 'A major Flutter release must never produce an SDK bump PR.');
    });

    test('it makes no commit and does not touch the pin', () {
      for (final String forbidden in <String>[
        'git commit',
        'git push',
        'git checkout -B',
        '> .flutter-version',
      ]) {
        expect(job.contains(forbidden), isFalse,
            reason: 'The major path runs `$forbidden`. A major update must '
                'change nothing in the repository (#362).');
      }
    });

    test('it needs no publication token, only permission to file an issue', () {
      expect(job, contains('issues: write'));
      expect(job.contains('DEPENDENCY_UPDATE_TOKEN'), isFalse,
          reason: 'An issue needs no CI, so it needs none of the publication '
              'token\'s reach.');
    });

    test('it updates the open issue instead of refiling every week', () {
      expect(job, contains('select(.title == env.TITLE)'),
          reason: 'The weekly run must find its own issue by title and edit '
              'it, or the maintainer gets a duplicate every Monday.');
    });

    test('the issue body explains why this stays manual', () {
      for (final String required in <String>[
        'Currently pinned',
        'New stable major',
        'manual',
        'F-Droid',
        'reproduc',
        '#362',
      ]) {
        expect(job, contains(required),
            reason: 'The issue body must mention "$required".');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // The boundary is re-checked on the PR itself, and the fixer stays away.
  // ---------------------------------------------------------------------------
  group('the boundary is re-checked on the PR itself', () {
    test('ci.yml guards the SDK update branch with the same script', () {
      expect(ci, contains("github.head_ref == 'toolchain/flutter-sdk'"),
          reason: 'CI must run the pin-only guard on SDK update PRs — against '
              'the real PR diff, not just the files the updater thinks it '
              'changed.');
      expect(ci.contains("startsWith(github.head_ref, 'toolchain/')"), isFalse,
          reason: 'The guard must match the updater\'s branch exactly. A '
              'prefix match would force every future human toolchain/* PR to '
              'touch nothing but .flutter-version.');
      expect(
          ci,
          contains(
              './scripts/check_dependency_update_files.sh --kind flutter-sdk'),
          reason:
              'The PR-side guard must be the same script the updater uses.');
    });

    test('ci.yml still guards deps/ PRs as lockfile-only', () {
      expect(ci, contains("startsWith(github.head_ref, 'deps/')"));
      expect(
          ci,
          contains(
              './scripts/check_dependency_update_files.sh --kind dart-packages'),
          reason: 'Adding the toolchain guard must not weaken the Dart one.');
    });

    test('CI runs on every PR, so an SDK PR is never unchecked', () {
      expect(ci, contains('pull_request:'));
      expect(ci.contains('pull_request:\n    branches'), isFalse,
          reason: 'A branch filter on pull_request would let an update PR '
              'merge without the normal checks.');
    });
  });

  group('the CI fixer leaves the toolchain branch alone', () {
    test('the fix job skips toolchain/ alongside dependabot/ and deps/', () {
      for (final String prefix in <String>[
        'dependabot/',
        'deps/',
        'toolchain/',
      ]) {
        expect(
          fixer,
          contains('"\$head_branch" == $prefix*'),
          reason: 'An SDK update that breaks CI must stay broken — the red is '
              'the signal, and "repair the code until it passes" is the '
              'migration itself. The skip has to happen while resolving the '
              'run, before any repair is generated. Missing: $prefix',
        );
      }
    });

    test('the publish job restates the skip where the push happens', () {
      for (final String prefix in <String>[
        'dependabot/',
        'deps/',
        'toolchain/',
      ]) {
        expect(
          fixer,
          contains("!startsWith(needs.fix.outputs.target_branch, '$prefix')"),
          reason: 'The last gate before a commit is pushed must also refuse '
              '$prefix branches.',
        );
      }
    });

    test('the fixer still refuses to touch the pin in any PR', () {
      expect(fixer, contains(r'\.flutter-version$'),
          reason: 'The protected-path guard must keep .flutter-version out of '
              'every agent patch, not just the ones on toolchain/ branches.');
    });
  });

  group('the documentation describes what actually happens', () {
    test('it no longer claims Flutter SDK updates are unautomated', () {
      expect(
          docs.contains('the Flutter SDK itself, Gradle, AGP, Kotlin'), isFalse,
          reason:
              'docs/development/dependency-updates.md still groups the Flutter SDK '
              'with the toolchains that are not automated yet.');
    });

    test('it documents the pieces a maintainer needs', () {
      for (final String required in <String>[
        '.flutter-version',
        'flutter-sdk-updates.yml',
        'toolchain/flutter-sdk',
        'check_flutter_sdk_update.py',
        'flutter_infra_release',
        'DEPENDENCY_UPDATE_TOKEN',
        'F-Droid',
      ]) {
        expect(docs, contains(required),
            reason:
                'docs/development/dependency-updates.md must mention "$required".');
      }
    });
  });
}

// -----------------------------------------------------------------------------
// Fixtures and helpers.
// -----------------------------------------------------------------------------

/// A release entry shaped like the official manifest's.
Map<String, dynamic> _release(
  String version, {
  String channel = 'stable',
  String? archive,
}) =>
    <String, dynamic>{
      'hash': 'hash-$channel-$version',
      'channel': channel,
      'version': version,
      'dart_sdk_version': '3.0.0',
      'dart_sdk_arch': 'x64',
      'release_date': '2026-01-01T00:00:00.000000Z',
      'archive':
          archive ?? '$channel/linux/flutter_linux_$version-$channel.tar.xz',
      'sha256': 'sha-$version',
    };

/// Runs the checker against a synthesised manifest. No network is involved.
_Result _check(
  String checker, {
  required String current,
  required List<String> stable,
  List<Map<String, dynamic>> extra = const <Map<String, dynamic>>[],
  String? stableHashFor,
}) {
  final List<Map<String, dynamic>> releases = <Map<String, dynamic>>[
    for (final String version in stable) _release(version),
    ...extra,
  ];
  final String pointer =
      stableHashFor ?? (stable.isNotEmpty ? stable.first : '');
  final Map<String, dynamic> manifest = <String, dynamic>{
    'base_url': 'https://storage.googleapis.com/flutter_infra_release/releases',
    'current_release': <String, String>{
      'stable': pointer.isEmpty ? '' : 'hash-stable-$pointer',
      'beta': 'hash-beta-unused',
      'dev': 'hash-dev-unused',
    },
    'releases': releases,
  };
  return _runWithManifest(
    checker,
    const JsonEncoder.withIndent('  ').convert(manifest),
    <String>['--current', current, '--json'],
  );
}

_Result _runWithManifest(String checker, String manifest, List<String> args) {
  final Directory tmp = Directory.systemTemp.createTempSync('flutter-releases');
  try {
    final File file = File(p.join(tmp.path, 'releases_linux.json'))
      ..writeAsStringSync(manifest);
    return _run(checker, <String>[...args, '--releases-file', file.path]);
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

_Result _run(String checker, List<String> args) {
  final ProcessResult r = Process.runSync(
    'python3',
    <String>[checker, ...args],
    stdoutEncoding: const SystemEncoding(),
    stderrEncoding: const SystemEncoding(),
  );
  return _Result(r.exitCode, r.stdout.toString(), r.stderr.toString());
}

ProcessResult _runGuard(String script, String kind, List<String> paths) =>
    Process.runSync(
      'bash',
      <String>[script, '--kind', kind, ...paths],
      stdoutEncoding: const SystemEncoding(),
      stderrEncoding: const SystemEncoding(),
    );

class _Result {
  _Result(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;

  Map<String, dynamic> get json => jsonDecode(stdout) as Map<String, dynamic>;

  String get status => value('status');

  String value(String key) => (json[key] ?? '').toString();

  String describe() => 'exit: $exitCode\nstdout:\n$stdout\nstderr:\n$stderr';
}

/// The text of one top-level job in a workflow file.
///
/// Job-scoped assertions matter here: "the workflow mentions the publication
/// token somewhere" would pass even if the wrong job used it.
String _jobSection(String workflow, String job) {
  final RegExp header = RegExp('^  $job:\$', multiLine: true);
  final RegExpMatch? start = header.firstMatch(workflow);
  if (start == null) fail('Workflow has no job named "$job".');
  final RegExp nextJob = RegExp(r'^  [a-z][\w-]*:$', multiLine: true);
  for (final RegExpMatch m in nextJob.allMatches(workflow)) {
    if (m.start > start.start) {
      return workflow.substring(start.start, m.start);
    }
  }
  return workflow.substring(start.start);
}

String _read(String root, String relativePath) {
  final File f = File(p.join(root, relativePath));
  expect(f.existsSync(), isTrue,
      reason: 'Expected file is missing: $relativePath');
  return f.readAsStringSync();
}

String _repoRoot() {
  Directory d = Directory.current;
  while (true) {
    if (File(p.join(d.path, 'pubspec.yaml')).existsSync() &&
        Directory(p.join(d.path, '.github')).existsSync()) {
      return d.path;
    }
    final Directory parent = d.parent;
    if (parent.path == d.path) {
      fail('Could not find repo root from ${Directory.current.path}');
    }
    d = parent;
  }
}
