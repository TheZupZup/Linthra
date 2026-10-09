import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Guardrails for the automatic Gradle / AGP / Kotlin updater (issue #362, the
/// fifth and last phase).
///
/// The updater is allowed to do exactly one thing per tool: notice that a newer
/// stable release exists *on the major line this repository already ships* and
/// propose that one version number. Everything else about it is a safety
/// boundary —
///
///   * it reads official, machine-readable, first-party release indexes, and
///     only bare `MAJOR.MINOR.PATCH` releases from them — never a prerelease;
///   * it treats "newest on our major" and "newest overall" as two independent
///     answers, so a new major can never hide a later patch on the line we
///     ship, and a later patch can never smuggle in a major;
///   * it fails loudly on data it cannot trust rather than guessing a target,
///     and it never proposes a downgrade;
///   * each tool gets one reusable draft PR on its own exactly-named branch,
///     changing one version string and nothing else;
///   * a major changes nothing at all and files an issue instead;
///   * it never merges, and the PRs it opens run the normal CI;
///   * the Flutter CI fixer leaves its branches alone, so a toolchain bump that
///     needs a migration stays red for a human.
///
/// The sharp edge here, and the reason this suite exists separately from the
/// Flutter SDK one: **AGP and Kotlin are pinned in the same file.** A filename
/// allowlist cannot tell those two updaters apart, so the boundary between them
/// is enforced against the file's real before/after content, and that enforcement
/// is tested against this repository's actual `android/settings.gradle`.
///
/// Every case here is offline: the classification tests feed fixture release
/// indexes to the checker instead of touching the network, and nothing in this
/// suite changes Linthra's actual toolchain pins.
///
/// Sibling coverage: test/tooling/flutter_sdk_update_guardrails_test.dart and
/// test/tooling/dependency_update_guardrails_test.dart do the same for the
/// Flutter SDK and Dart package updaters, and
/// test/tooling/toolchain_pins_test.dart pins the versions themselves.
/// test/tooling/android_toolchain_update_test.py unit-tests the parsers this
/// suite drives end to end.
void main() {
  final String root = _repoRoot();

  final String checker =
      p.join(root, 'scripts', 'check_android_toolchain_update.py');
  final String diffGuard =
      p.join(root, 'scripts', 'check_toolchain_pin_diff.py');
  final String writer = p.join(root, 'scripts', 'set_android_toolchain_pin.py');
  final String fileGuard =
      p.join(root, 'scripts', 'check_dependency_update_files.sh');

  late final String workflow = _read(
      root, p.join('.github', 'workflows', 'android-toolchain-updates.yml'));
  late final String ci = _read(root, p.join('.github', 'workflows', 'ci.yml'));
  late final String fixer =
      _read(root, p.join('.github', 'workflows', 'flutter-ci-fixer.yml'));
  late final String docs = _read(root, p.join('docs', 'dependency-updates.md'));

  // The repository's real pin files. Using these rather than a synthetic
  // snippet means the content guard is tested against the thing it actually
  // guards, comments and all.
  late final String settingsGradle =
      _read(root, p.join('android', 'settings.gradle'));
  late final String wrapperProperties = _read(root,
      p.join('android', 'gradle', 'wrapper', 'gradle-wrapper.properties'));

  setUpAll(() {
    for (final String script in <String>[checker, diffGuard, writer]) {
      expect(File(script).existsSync(), isTrue,
          reason: 'Missing toolchain updater script: $script');
    }
    final ProcessResult python =
        Process.runSync('python3', <String>['--version']);
    expect(python.exitCode, 0,
        reason: 'python3 is not on PATH; the toolchain checker requires it.');
  });

  // ---------------------------------------------------------------------------
  // Classification. CURRENT comes from the pin file (or --current); the two
  // answers are the newest release on the pinned major and the newest overall.
  // ---------------------------------------------------------------------------
  group('classifying the gap between a pin and upstream', () {
    test('the same version is no update', () {
      for (final String tool in _tools) {
        final _Tool r =
            _check(checker, tool: tool, current: '8.2.3', versions: <String>[
          '8.2.3',
          '8.2.2',
          '8.1.9',
        ]);
        expect(r.exitCode, 0, reason: r.describe());
        expect(r.status, 'up-to-date', reason: 'tool: $tool');
        expect(r.value('latest_in_current_major'), '8.2.3');
        expect(r.value('major_status'), 'none');
      }
    });

    test('a newer patch on the same minor is a patch update', () {
      final _Tool r = _check(checker,
          tool: 'gradle',
          current: '8.2.3',
          versions: <String>['8.2.4', '8.2.3']);
      expect(r.exitCode, 0, reason: r.describe());
      expect(r.status, 'patch');
      expect(r.value('latest_in_current_major'), '8.2.4');
    });

    test('a newer minor on the same major is a minor update', () {
      final _Tool r = _check(checker,
          tool: 'agp', current: '8.2.3', versions: <String>['8.3.0', '8.2.9']);
      expect(r.exitCode, 0, reason: r.describe());
      expect(r.status, 'minor');
      expect(r.value('latest_in_current_major'), '8.3.0');
    });

    test('a minor jump of several lines is still a minor update', () {
      final _Tool r = _check(checker,
          tool: 'kotlin',
          current: '2.2.21',
          versions: <String>['2.5.0', '2.2.30', '2.2.21']);
      expect(r.exitCode, 0, reason: r.describe());
      expect(r.status, 'minor');
      expect(r.value('latest_in_current_major'), '2.5.0');
    });

    test('a newer major asks for an issue, never a pin change', () {
      for (final String tool in _tools) {
        final _Tool r =
            _check(checker, tool: tool, current: '8.2.3', versions: <String>[
          '9.0.0',
          '8.2.3',
        ]);
        expect(r.exitCode, 0, reason: r.describe());
        // The PR path is driven by `status`, which stays inside the pinned
        // major. Nothing about a major can reach it.
        expect(r.status, 'up-to-date', reason: 'tool: $tool');
        expect(r.value('major_status'), 'available');
        expect(r.value('major_latest'), '9.0.0');
        expect(r.value('latest_in_current_major'), '8.2.3');
      }
    });

    test('a patch on the current major and a newer major are reported together',
        () {
      // The requirement this updater exists for: being on 8.x with both 8.15.0
      // and 9.0.0 published must produce *both* a draft PR for 8.15.0 and a
      // major-upgrade issue for 9.0.0. Neither may swallow the other.
      final _Tool r =
          _check(checker, tool: 'gradle', current: '8.14.5', versions: <String>[
        '9.0.0',
        '8.15.0',
        '8.14.5',
      ]);
      expect(r.exitCode, 0, reason: r.describe());
      expect(r.status, 'minor',
          reason: 'The newer 8.x release must still be proposed.');
      expect(r.value('latest_in_current_major'), '8.15.0');
      expect(r.value('major_status'), 'available');
      expect(r.value('major_latest'), '9.0.0');
      expect(r.value('latest'), '9.0.0');
    });

    test('a newer major never becomes the proposed version', () {
      // The strongest form of the rule: whatever else happens, the version the
      // PR path would write is on the pinned major line.
      for (final List<String> versions in <List<String>>[
        <String>['9.0.0', '8.2.3'],
        <String>['9.9.9', '8.2.4', '8.2.3'],
        <String>['10.0.0', '9.0.0', '8.3.0'],
      ]) {
        final _Tool r =
            _check(checker, tool: 'agp', current: '8.2.3', versions: versions);
        expect(r.exitCode, 0, reason: r.describe());
        expect(r.value('latest_in_current_major').startsWith('8.'), isTrue,
            reason: 'Proposed ${r.value('latest_in_current_major')} from '
                '${versions.join(', ')}.');
      }
    });

    test('the workflow matrices route each answer to the right job', () {
      // pr_tools and issue_tools are what the workflow actually branches on,
      // so they are asserted directly rather than inferred from the statuses.
      final Directory tmp =
          Directory.systemTemp.createTempSync('toolchain-outputs');
      try {
        final File outputs = File(p.join(tmp.path, 'github-output'));
        final _Run run = _run(checker, <String>[
          '--tool',
          'gradle',
          '--current',
          '8.14.5',
          '--versions-file',
          _writeGradleIndex(tmp, <String>['9.0.0', '8.15.0', '8.14.5']),
          '--github-output',
          outputs.path,
          '--quiet',
        ]);
        expect(run.exitCode, 0, reason: run.describe());
        final String written = outputs.readAsStringSync();
        expect(written, contains('pr_tools=["gradle"]'),
            reason: 'A newer release on the pinned major must open a PR.');
        expect(written, contains('issue_tools=["gradle"]'),
            reason: 'A newer major must file an issue in the same run.');
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('nothing to do produces two empty matrices', () {
      final Directory tmp =
          Directory.systemTemp.createTempSync('toolchain-outputs');
      try {
        final File outputs = File(p.join(tmp.path, 'github-output'));
        final _Run run = _run(checker, <String>[
          '--tool',
          'gradle',
          '--current',
          '8.14.5',
          '--versions-file',
          _writeGradleIndex(tmp, <String>['8.14.5', '8.14.4']),
          '--github-output',
          outputs.path,
          '--quiet',
        ]);
        expect(run.exitCode, 0, reason: run.describe());
        expect(outputs.readAsStringSync(), contains('pr_tools=[]'));
        expect(outputs.readAsStringSync(), contains('issue_tools=[]'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('the highest version wins regardless of upstream ordering', () {
      // Gradle's own index really does list a hotfix on an older line after a
      // newer line, so "first entry" is not a safe answer for any of them.
      for (final List<String> order in <List<String>>[
        <String>['8.2.9', '8.5.0', '8.4.0'],
        <String>['8.4.0', '8.2.9', '8.5.0'],
        <String>['8.5.0', '8.4.0', '8.2.9'],
      ]) {
        for (final String tool in _tools) {
          final _Tool r =
              _check(checker, tool: tool, current: '8.2.3', versions: order);
          expect(r.exitCode, 0, reason: r.describe());
          expect(r.value('latest_in_current_major'), '8.5.0',
              reason: '$tool with order ${order.join(', ')} chose '
                  '${r.value('latest_in_current_major')}.');
        }
      }
    });

    test('the pin file is what is read when --current is omitted', () {
      for (final String tool in _tools) {
        final _Run run = _run(
            checker, <String>['--tool', tool, '--latest', '99.0.0', '--json']);
        expect(run.exitCode, 0, reason: run.describe());
        final Map<String, dynamic> result = (jsonDecode(run.stdout)
            as Map<String, dynamic>)[tool] as Map<String, dynamic>;
        expect(result['current'], matches(RegExp(r'^\d+\.\d+\.\d+$')),
            reason: '$tool must read its pin from ${result['pin_file']}.');
      }
    });

    test('--latest classifies two versions with no index at all', () {
      // The workflow uses this to compare the version already on an update
      // branch against the version it is about to propose.
      const Map<String, String> expected = <String, String>{
        '8.2.3': 'up-to-date',
        '8.2.4': 'patch',
        '8.3.0': 'minor',
        '9.0.0': 'major',
      };
      expected.forEach((String latest, String status) {
        final _Run run = _run(checker, <String>[
          '--tool',
          'gradle',
          '--current',
          '8.2.3',
          '--latest',
          latest,
          '--json',
        ]);
        expect(run.exitCode, 0, reason: run.describe());
        final Map<String, dynamic> result = (jsonDecode(run.stdout)
            as Map<String, dynamic>)['gradle'] as Map<String, dynamic>;
        expect(result['status'], status);
        expect(result['stable_confirmed'], 'false',
            reason: 'No index was consulted, so nothing may claim the target '
                'was confirmed published.');
      });
    });
  });

  // ---------------------------------------------------------------------------
  // Stable releases only.
  // ---------------------------------------------------------------------------
  group('following final releases and nothing else', () {
    test('Gradle release candidates and milestones never become the target',
        () {
      final _Run run = _runWithIndex(
        checker,
        'gradle',
        '8.2.3',
        _gradleIndex(<String>[
          '8.2.3'
        ], extra: <Map<String, dynamic>>[
          _gradleEntry('8.3.0-rc-1', isFinal: false, activeRc: true),
          _gradleEntry('8.4.0-milestone-1',
              isFinal: false, milestoneFor: '8.4.0'),
        ]),
      );
      expect(run.exitCode, 0, reason: run.describe());
      expect(run.tool('gradle').value('latest_in_current_major'), '8.2.3');
      expect(run.tool('gradle').value('prereleases_skipped'), '2');
    });

    test('Gradle snapshots and nightlies are ignored', () {
      final _Run run = _runWithIndex(
        checker,
        'gradle',
        '8.2.3',
        _gradleIndex(<String>[
          '8.2.3'
        ], extra: <Map<String, dynamic>>[
          _gradleEntry('8.9.0-20260101000000+0000',
              isFinal: false, snapshot: true),
          _gradleEntry('8.9.0-20260102000000+0000',
              isFinal: false, releaseNightly: true),
        ]),
      );
      expect(run.exitCode, 0, reason: run.describe());
      expect(run.tool('gradle').value('latest_in_current_major'), '8.2.3');
    });

    test('a Gradle entry that claims final but contradicts itself is refused',
        () {
      for (final Map<String, dynamic> contradiction in <Map<String, dynamic>>[
        <String, dynamic>{'broken': true},
        <String, dynamic>{'snapshot': true},
        <String, dynamic>{'nightly': true},
        <String, dynamic>{'activeRc': true},
        <String, dynamic>{'rcFor': '8.9.0'},
        <String, dynamic>{'milestoneFor': '8.9.0'},
      ]) {
        final Map<String, dynamic> entry = _gradleEntry('8.9.0');
        entry.addAll(contradiction);
        final _Run run = _runWithIndex(
            checker,
            'gradle',
            '8.2.3',
            _gradleIndex(<String>['8.2.3'],
                extra: <Map<String, dynamic>>[entry]));
        expect(run.exitCode, 0, reason: run.describe());
        expect(run.tool('gradle').value('latest_in_current_major'), '8.2.3',
            reason:
                'A final release contradicted by ${contradiction.keys.first} '
                'must not be proposed.');
        expect(run.tool('gradle').value('notes'), contains('claims final'));
      }
    });

    test('a Gradle release served from an unexpected host is refused', () {
      final _Run run = _runWithIndex(
        checker,
        'gradle',
        '8.2.3',
        _gradleIndex(<String>[
          '8.2.3'
        ], extra: <Map<String, dynamic>>[
          _gradleEntry('8.9.0',
              downloadUrl: 'https://example.invalid/gradle-8.9.0-bin.zip'),
        ]),
      );
      expect(run.exitCode, 0, reason: run.describe());
      expect(run.tool('gradle').value('latest_in_current_major'), '8.2.3',
          reason: 'A version this repository could not download from the '
              'wrapper distribution host is not a version to propose.');
      expect(run.tool('gradle').value('notes'), contains('downloadUrl'));
    });

    test("Gradle's historical two-component tags are not candidates", () {
      // `8.14` is a real Gradle release, but a pin file may only hold a bare
      // triple (test/tooling/toolchain_pins_test.dart), so it is not a version
      // an automatic update may write.
      final _Run run = _runWithIndex(
        checker,
        'gradle',
        '8.2.3',
        _gradleIndex(<String>['8.2.3'],
            extra: <Map<String, dynamic>>[_gradleEntry('8.14')]),
      );
      expect(run.exitCode, 0, reason: run.describe());
      expect(run.tool('gradle').value('latest_in_current_major'), '8.2.3');
      expect(run.tool('gradle').value('malformed_skipped'), '1');
    });

    test('Maven prereleases of every flavour are ignored', () {
      for (final String tool in <String>['agp', 'kotlin']) {
        final _Tool r =
            _check(checker, tool: tool, current: '8.2.3', versions: <String>[
          '8.2.3',
          '8.3.0-alpha01',
          '8.3.0-beta02',
          '8.3.0-rc01',
          '8.3.0-RC',
          '8.3.0-Beta1',
          '8.3.0-M1',
          '8.3.0-SNAPSHOT',
          '8.3.0-eap-1',
          '8.3.0-dev-123',
          '8.3.0-preview',
        ]);
        expect(r.exitCode, 0, reason: r.describe());
        expect(r.value('latest_in_current_major'), '8.2.3',
            reason: '$tool proposed a prerelease.');
        expect(int.parse(r.value('prereleases_skipped')), 10,
            reason: '$tool did not recognise every prerelease flavour.');
      }
    });

    test('Maven <latest> and <release> pointers are not obeyed', () {
      // Kotlin's own metadata routinely names an -RC build in <release>.
      final String metadata = _mavenMetadata(
        'org.jetbrains.kotlin',
        'kotlin-gradle-plugin',
        <String>['2.2.21', '2.3.0-RC'],
        latest: '2.3.0-RC',
        release: '2.3.0-RC',
      );
      final _Run run = _runWithIndex(checker, 'kotlin', '2.2.21', metadata);
      expect(run.exitCode, 0, reason: run.describe());
      expect(run.tool('kotlin').value('latest_in_current_major'), '2.2.21');
      expect(run.tool('kotlin').status, 'up-to-date');
    });

    test('reaching a target at all is the confirmation it is published', () {
      final _Tool r = _check(checker,
          tool: 'kotlin',
          current: '2.2.21',
          versions: <String>['2.2.30', '2.2.21']);
      expect(r.value('stable_confirmed'), 'true');
      expect(r.value('releases_considered'), '2');
    });
  });

  // ---------------------------------------------------------------------------
  // Untrustworthy data.
  // ---------------------------------------------------------------------------
  group('untrustworthy data fails loudly instead of guessing', () {
    test('the checker never proposes a downgrade', () {
      for (final String tool in _tools) {
        final _Tool r =
            _check(checker, tool: tool, current: '8.9.9', versions: <String>[
          '8.2.3',
          '8.1.0',
        ]);
        expect(r.exitCode, 2, reason: r.describe());
        expect(r.stderr, contains('downgrade'), reason: 'tool: $tool');
      }
    });

    test('a downgrade is refused in --latest mode too', () {
      final _Run run = _run(checker, <String>[
        '--tool',
        'agp',
        '--current',
        '8.2.3',
        '--latest',
        '8.2.2',
      ]);
      expect(run.exitCode, 2, reason: run.describe());
      expect(run.stderr, contains('downgrade'));
    });

    const List<String> badVersions = <String>[
      '',
      'latest',
      '8',
      '8.2',
      '8.2.3.4',
      'v8.2.3',
      '8.2.3-rc1',
      '../../etc/passwd',
    ];

    for (final String bad in badVersions) {
      test(
          'a malformed --current (${bad.isEmpty ? '<empty>' : bad}) is rejected',
          () {
        final _Run run = _run(checker, <String>[
          '--tool',
          'gradle',
          '--current',
          bad,
          '--latest',
          '9.9.9'
        ]);
        expect(run.exitCode, 2, reason: run.describe());
      });
    }

    test('a malformed --latest is rejected', () {
      final _Run run = _run(checker, <String>[
        '--tool',
        'gradle',
        '--current',
        '8.2.3',
        '--latest',
        'newest',
      ]);
      expect(run.exitCode, 2, reason: run.describe());
    });

    // Upstream payloads that are structurally wrong, rather than merely full of
    // versions we do not want.
    final Map<String, String> brokenGradle = <String, String>{
      'not JSON at all': '{{{',
      'a JSON object instead of an array': '{"versions": []}',
      'an empty array': '[]',
      'an array of strings': '["8.2.3"]',
      'an array with a null entry': '[null]',
    };
    brokenGradle.forEach((String why, String payload) {
      test('a Gradle index that is $why is rejected', () {
        final _Run run = _runWithIndex(checker, 'gradle', '8.2.3', payload);
        expect(run.exitCode, 2, reason: run.describe());
      });
    });

    final Map<String, String> brokenMaven = <String, String>{
      'not XML at all': 'this is not xml',
      'rooted somewhere else': '<html><body>nothing to see</body></html>',
      'missing the versions element':
          '<metadata><groupId>org.jetbrains.kotlin</groupId>'
              '<artifactId>kotlin-gradle-plugin</artifactId></metadata>',
      'empty of versions': '<metadata><groupId>org.jetbrains.kotlin</groupId>'
          '<artifactId>kotlin-gradle-plugin</artifactId>'
          '<versioning><versions></versions></versioning></metadata>',
    };
    brokenMaven.forEach((String why, String payload) {
      test('Maven metadata that is $why is rejected', () {
        final _Run run = _runWithIndex(checker, 'kotlin', '2.2.21', payload);
        expect(run.exitCode, 2, reason: run.describe());
      });
    });

    test('metadata for a different artifact is refused', () {
      // A redirect or a copy-paste error in the URL must not silently make the
      // updater track someone else's version numbers.
      final _Run run = _runWithIndex(
        checker,
        'kotlin',
        '2.2.21',
        _mavenMetadata('com.example', 'something-else', <String>['9.9.9']),
      );
      expect(run.exitCode, 2, reason: run.describe());
      expect(run.stderr, contains('wrong artifact'));
    });

    test('metadata declaring entities is refused before it is parsed', () {
      final _Run run = _runWithIndex(
        checker,
        'kotlin',
        '2.2.21',
        '<!DOCTYPE metadata [<!ENTITY a "b">]>\n'
            '${_mavenMetadata('org.jetbrains.kotlin', 'kotlin-gradle-plugin', <String>[
              '2.2.21'
            ])}',
      );
      expect(run.exitCode, 2, reason: run.describe());
      expect(run.stderr, contains('refusing to parse'));
    });

    test('an index with no usable release at all is rejected', () {
      final _Run run = _runWithIndex(
        checker,
        'agp',
        '8.2.3',
        _mavenMetadata('com.android.tools.build', 'gradle',
            <String>['8.3.0-alpha01', '8.3.0-rc01']),
      );
      expect(run.exitCode, 2, reason: run.describe());
      expect(run.stderr, contains('no usable stable release'));
    });

    test('an index that never mentions our own major line is rejected', () {
      // Not "the tool dropped a line" — an index that has no 8.x at all is not
      // describing the tool we think it is, and acting on it would be acting
      // on data we cannot read.
      final _Run run = _runWithIndex(
          checker,
          'agp',
          '8.2.3',
          _mavenMetadata(
              'com.android.tools.build', 'gradle', <String>['9.1.0']));
      expect(run.exitCode, 2, reason: run.describe());
      expect(run.stderr, contains('pinned major line'));
    });

    test('a missing index file is rejected', () {
      final _Run run = _run(checker, <String>[
        '--tool',
        'gradle',
        '--current',
        '8.2.3',
        '--versions-file',
        p.join(Directory.systemTemp.path, 'definitely-not-here.json'),
      ]);
      expect(run.exitCode, 2, reason: run.describe());
    });

    test('a pin that is unknown upstream is reported but still classified', () {
      // Advisory rather than fatal: the classification against the major line
      // is still sound, but a human should know the index has never heard of
      // the version we ship.
      final _Tool r = _check(checker,
          tool: 'kotlin',
          current: '2.2.21',
          versions: <String>['2.2.30', '2.2.20']);
      expect(r.exitCode, 0, reason: r.describe());
      expect(r.status, 'patch');
      expect(r.value('notes'), contains('not listed'));
    });

    test('the checker never writes anything itself', () {
      // Detection and publication are separate on purpose: the script only
      // classifies, so nothing it does can move a pin.
      final String source = File(checker).readAsStringSync();
      for (final String forbidden in <String>[
        'write_text',
        'git commit',
        'git push',
        'gh pr create',
        'gh issue create',
      ]) {
        expect(source.contains(forbidden), isFalse,
            reason: 'scripts/check_android_toolchain_update.py contains '
                '`$forbidden`. It may only read and classify; publishing '
                'belongs to the workflow.');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // The file allowlist. Which files an automatic update may move at all.
  // ---------------------------------------------------------------------------
  group('the allowlist guard admits only each tool\'s own pin file', () {
    const Map<String, String> ownFile = <String, String>{
      'gradle': 'android/gradle/wrapper/gradle-wrapper.properties',
      'agp': 'android/settings.gradle',
      'kotlin': 'android/settings.gradle',
    };

    ownFile.forEach((String kind, String path) {
      test('$kind accepts $path alone', () {
        final ProcessResult r = _runFileGuard(fileGuard, kind, <String>[path]);
        expect(r.exitCode, 0,
            reason: 'stdout: ${r.stdout}\nstderr: ${r.stderr}');
      });
    });

    test('an empty change set passes for every kind', () {
      for (final String kind in _tools) {
        final ProcessResult r =
            _runFileGuard(fileGuard, kind, const <String>[]);
        expect(r.exitCode, 0, reason: 'kind: $kind, stderr: ${r.stderr}');
      }
    });

    // One case per rule the issue spells out. If someone widens an allowlist,
    // the specific protection they removed is named in the failure.
    const Map<String, String> forbidden = <String, String>{
      'lib/main.dart': 'application code',
      'lib/core/app_info.dart': 'the in-app version',
      'test/core/app_info_version_test.dart': 'test code',
      'pubspec.yaml': 'dependency constraints',
      'pubspec.lock': 'the resolved dependency set',
      '.flutter-version': 'the Flutter SDK pin',
      '.java-version': 'the JDK pin',
      'metadata/io.github.thezupzup.linthra.yml': 'F-Droid metadata',
      'fastlane/metadata/android/en-US/changelogs/201999.txt': 'Fastlane files',
      'docs/release-notes/v0.2.1.md': 'release notes',
      'android/key.properties': 'signing configuration',
      'android/app/linthra-release.jks': 'signing material',
      'android/app/build.gradle': 'the app module build logic',
      'LICENSE': 'the license',
      '.github/workflows/ci.yml': 'CI configuration',
      'docs/dependency-updates.md': 'documentation',
      'scripts/check_dependency_update_files.sh': 'the guard itself',
    };

    forbidden.forEach((String path, String why) {
      test('$path is rejected for every automatic toolchain kind — $why', () {
        for (final String kind in _tools) {
          final ProcessResult r =
              _runFileGuard(fileGuard, kind, <String>[ownFile[kind]!, path]);
          expect(r.exitCode, isNot(0),
              reason: 'An automatic $kind update must not change $why.\n'
                  'stdout: ${r.stdout}');
          expect(r.stderr, contains(path),
              reason: 'The rejection should name the offending path.');
        }
      });
    });

    test('Gradle cannot reach the file AGP and Kotlin share, or vice versa',
        () {
      expect(
          _runFileGuard(
                  fileGuard, 'gradle', <String>['android/settings.gradle'])
              .exitCode,
          isNot(0),
          reason: 'A Gradle wrapper bump must not touch the plugin pins.');
      for (final String kind in <String>['agp', 'kotlin']) {
        expect(
            _runFileGuard(fileGuard, kind, <String>[
              'android/gradle/wrapper/gradle-wrapper.properties'
            ]).exitCode,
            isNot(0),
            reason: 'A $kind bump must not touch the Gradle wrapper.');
      }
    });

    test('the earlier updaters keep their own narrower reach', () {
      // Adding three kinds must not have turned the allowlists into one union.
      for (final MapEntry<String, String> pair in <String, String>{
        'dart-packages': 'pubspec.lock',
        'flutter-sdk': '.flutter-version',
      }.entries) {
        expect(
            _runFileGuard(fileGuard, pair.key, <String>[pair.value]).exitCode,
            0,
            reason: '${pair.key} must still accept ${pair.value}.');
        for (final String path in <String>[
          'android/settings.gradle',
          'android/gradle/wrapper/gradle-wrapper.properties',
        ]) {
          expect(_runFileGuard(fileGuard, pair.key, <String>[path]).exitCode,
              isNot(0),
              reason: '${pair.key} must not be able to write $path.');
        }
      }
      for (final String kind in _tools) {
        for (final String path in <String>[
          'pubspec.lock',
          '.flutter-version'
        ]) {
          expect(
              _runFileGuard(fileGuard, kind, <String>[path]).exitCode, isNot(0),
              reason: '$kind must not be able to write $path.');
        }
      }
    });

    test('an unknown kind fails instead of allowing everything', () {
      final ProcessResult r =
          _runFileGuard(fileGuard, 'anything-goes', <String>['lib/main.dart']);
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('unknown --kind'));
    });
  });

  // ---------------------------------------------------------------------------
  // The content guard. This is the part a filename cannot do, tested against
  // the repository's real pin files.
  // ---------------------------------------------------------------------------
  group('the content guard bounds what changed inside the file', () {
    test('a plain AGP bump is accepted', () {
      final _Run r = _runDiffGuard(diffGuard, 'agp', settingsGradle,
          _bumpAgp(settingsGradle, '9999.1.2'));
      expect(r.exitCode, 2, reason: 'sanity: that target crosses a major');

      final _Run ok = _runDiffGuard(diffGuard, 'agp', settingsGradle,
          _bumpAgp(settingsGradle, _bumpPatch(_agpPin(settingsGradle))));
      expect(ok.exitCode, 0, reason: ok.describe());
      expect(ok.stdout, contains('changes nothing else'));
    });

    test('a plain Kotlin bump is accepted', () {
      final _Run ok = _runDiffGuard(diffGuard, 'kotlin', settingsGradle,
          _bumpKotlin(settingsGradle, _bumpPatch(_kotlinPin(settingsGradle))));
      expect(ok.exitCode, 0, reason: ok.describe());
    });

    test('a plain Gradle bump is accepted', () {
      final _Run ok = _runDiffGuard(
          diffGuard,
          'gradle',
          wrapperProperties,
          _bumpGradle(
              wrapperProperties, _bumpPatch(_gradlePin(wrapperProperties))));
      expect(ok.exitCode, 0, reason: ok.describe());
    });

    test('the AGP updater cannot alter the Kotlin pin', () {
      final String after = _bumpKotlin(
        _bumpAgp(settingsGradle, _bumpPatch(_agpPin(settingsGradle))),
        _bumpPatch(_kotlinPin(settingsGradle)),
      );
      final _Run r = _runDiffGuard(diffGuard, 'agp', settingsGradle, after);
      expect(r.exitCode, 2, reason: r.describe());
      expect(r.stderr, contains('Kotlin Gradle plugin'),
          reason: 'The failure must name what was moved that should not have '
              'been — the two pins share android/settings.gradle, so this is '
              'the case a filename allowlist cannot catch.');
    });

    test('the Kotlin updater cannot alter the AGP pin', () {
      final String after = _bumpAgp(
        _bumpKotlin(settingsGradle, _bumpPatch(_kotlinPin(settingsGradle))),
        _bumpPatch(_agpPin(settingsGradle)),
      );
      final _Run r = _runDiffGuard(diffGuard, 'kotlin', settingsGradle, after);
      expect(r.exitCode, 2, reason: r.describe());
      expect(r.stderr, contains('Android Gradle Plugin'));
    });

    test('neither updater may rewrite a comment or unrelated content', () {
      final String bumped =
          _bumpAgp(settingsGradle, _bumpPatch(_agpPin(settingsGradle)));
      for (final String tampered in <String>[
        // A reworded comment.
        bumped.replaceFirst(
            '// The two versions on the next lines', '// Anything goes now'),
        // A deleted comment line.
        bumped.replaceFirst(RegExp(r'^\s*//.*\n', multiLine: true), ''),
        // An extra plugin.
        bumped.replaceFirst(
            'include ":app"', 'include ":app"\ninclude ":evil"'),
        // A whitespace-only change.
        '$bumped\n',
        // A different repository in pluginManagement.
        bumped.replaceFirst('mavenCentral()', 'maven { url "https://evil" }'),
      ]) {
        final _Run r =
            _runDiffGuard(diffGuard, 'agp', settingsGradle, tampered);
        expect(r.exitCode, 2,
            reason: 'An automatic update may rewrite one version string and '
                'nothing else.\n${r.describe()}');
        expect(r.stderr, contains('more than'));
      }
    });

    test('the Gradle updater may not rewrite the other wrapper properties', () {
      final String bumped = _bumpGradle(
          wrapperProperties, _bumpPatch(_gradlePin(wrapperProperties)));
      for (final String tampered in <String>[
        bumped.replaceFirst('distributionPath=', 'distributionPath=x'),
        bumped.replaceFirst('zipStorePath=', 'zipStorePath=x'),
        bumped.replaceFirst('distributionBase=GRADLE_USER_HOME',
            'distributionBase=SOMEWHERE_ELSE'),
        '$bumped\nnetworkTimeout=10000\n',
        // The distribution flavour is not the updater's to change either.
        bumped.replaceFirst('-all.zip', '-bin.zip'),
      ]) {
        final _Run r =
            _runDiffGuard(diffGuard, 'gradle', wrapperProperties, tampered);
        expect(r.exitCode, 2, reason: r.describe());
      }
    });

    test('a downgrade is refused by the guard as well as by the checker', () {
      final String older = _bumpAgp(settingsGradle, '9.0.0');
      final _Run r = _runDiffGuard(diffGuard, 'agp', older, settingsGradle);
      expect(r.exitCode, 0, reason: 'sanity: forwards is fine');

      final _Run back = _runDiffGuard(diffGuard, 'agp', settingsGradle, older);
      expect(back.exitCode, 2, reason: back.describe());
      expect(back.stderr, contains('downgrade'));
    });

    test('crossing a major is refused by the guard', () {
      for (final MapEntry<String, String> pair in <String, String>{
        'agp': _bumpAgp(settingsGradle, '10.0.0'),
        'kotlin': _bumpKotlin(settingsGradle, '3.0.0'),
      }.entries) {
        final _Run r =
            _runDiffGuard(diffGuard, pair.key, settingsGradle, pair.value);
        expect(r.exitCode, 2, reason: r.describe());
        expect(r.stderr, contains('major'));
      }
      final _Run gradle = _runDiffGuard(diffGuard, 'gradle', wrapperProperties,
          _bumpGradle(wrapperProperties, '10.0.0'));
      expect(gradle.exitCode, 2, reason: gradle.describe());
    });

    test('a prerelease target is refused by the guard', () {
      final _Run r = _runDiffGuard(diffGuard, 'kotlin', settingsGradle,
          _bumpKotlin(settingsGradle, '2.9.0-RC2'));
      expect(r.exitCode, 2, reason: r.describe());
    });

    test('a file with no recognisable pin is refused, not guessed at', () {
      final _Run r = _runDiffGuard(
          diffGuard, 'agp', 'plugins {\n}\n', 'plugins {\n  // nothing\n}\n');
      expect(r.exitCode, 2, reason: r.describe());
      expect(r.stderr, contains('refusing to guess'));
    });

    test('an ambiguous file with two matching pins is refused', () {
      final String doubled = settingsGradle.replaceFirstMapped(
        _agpRe,
        (Match m) => '${m[0]}\n'
            '    id "com.android.application" version "8.0.0" apply false',
      );
      final _Run r = _runDiffGuard(diffGuard, 'agp', doubled, doubled);
      expect(r.exitCode, 2, reason: r.describe());
      expect(r.stderr, contains('ambiguous'));
    });
  });

  // ---------------------------------------------------------------------------
  // The writer.
  // ---------------------------------------------------------------------------
  group('the writer moves one version and refuses the rest', () {
    test('it writes the pin and leaves the rest of the file byte-identical',
        () {
      for (final String tool in _tools) {
        final _Sandbox sandbox = _Sandbox(root);
        try {
          final String before = sandbox.pinFileText(tool);
          final String current = sandbox.pin(tool);
          final String target = _bumpPatch(current);
          final _Run write = _run(writer, <String>[
            '--tool',
            tool,
            '--version',
            target,
            '--repo-root',
            sandbox.path,
          ]);
          expect(write.exitCode, 0, reason: write.describe());
          expect(sandbox.pin(tool), target);

          // The strongest statement available: putting the old version back
          // reproduces the previous file exactly.
          final _Run guard =
              _runDiffGuard(diffGuard, tool, before, sandbox.pinFileText(tool));
          expect(guard.exitCode, 0, reason: '$tool: ${guard.describe()}');
        } finally {
          sandbox.dispose();
        }
      }
    });

    test('an automatic AGP write leaves the Kotlin pin alone, and vice versa',
        () {
      for (final MapEntry<String, String> pair in <String, String>{
        'agp': 'kotlin',
        'kotlin': 'agp',
      }.entries) {
        final _Sandbox sandbox = _Sandbox(root);
        try {
          final String otherBefore = sandbox.pin(pair.value);
          final _Run write = _run(writer, <String>[
            '--tool',
            pair.key,
            '--version',
            _bumpPatch(sandbox.pin(pair.key)),
            '--repo-root',
            sandbox.path,
          ]);
          expect(write.exitCode, 0, reason: write.describe());
          expect(sandbox.pin(pair.value), otherBefore,
              reason: '${pair.key} moved ${pair.value} in the shared file.');
        } finally {
          sandbox.dispose();
        }
      }
    });

    test('rerunning with the same version is refused, so reruns are quiet', () {
      final _Sandbox sandbox = _Sandbox(root);
      try {
        final _Run write = _run(writer, <String>[
          '--tool',
          'kotlin',
          '--version',
          sandbox.pin('kotlin'),
          '--repo-root',
          sandbox.path,
        ]);
        expect(write.exitCode, 2, reason: write.describe());
        expect(write.stderr, contains('already pinned'));
      } finally {
        sandbox.dispose();
      }
    });

    test('a downgrade, a major and a malformed version are all refused', () {
      const Map<String, String> refusals = <String, String>{
        '9.0.0': 'downgrade',
        '10.0.0': 'major',
        '9.99': 'MAJOR.MINOR.PATCH',
        '9.99.0-rc1': 'MAJOR.MINOR.PATCH',
      };
      refusals.forEach((String version, String expected) {
        final _Sandbox sandbox = _Sandbox(root);
        try {
          final _Run write = _run(writer, <String>[
            '--tool',
            'agp',
            '--version',
            version,
            '--repo-root',
            sandbox.path,
          ]);
          expect(write.exitCode, 2, reason: write.describe());
          expect(write.stderr, contains(expected));
          expect(sandbox.pinFileText('agp'),
              _read(root, p.join('android', 'settings.gradle')),
              reason: 'A refused write must leave the file untouched.');
        } finally {
          sandbox.dispose();
        }
      });
    });
  });

  // ---------------------------------------------------------------------------
  // End to end, against a real git repository.
  // ---------------------------------------------------------------------------
  group('an update branch, checked the way CI checks it', () {
    test('the guards accept a clean single-tool update and reject the rest',
        () {
      for (final String tool in _tools) {
        final _GitSandbox sandbox = _GitSandbox(root);
        try {
          final _Run write = _run(writer, <String>[
            '--tool',
            tool,
            '--version',
            _bumpPatch(sandbox.pin(tool)),
            '--repo-root',
            sandbox.path,
          ]);
          expect(write.exitCode, 0, reason: write.describe());

          expect(sandbox.fileGuard(fileGuard, tool).exitCode, 0,
              reason: '$tool: the file guard rejected its own pin file.');
          final _Run content = sandbox.contentGuard(diffGuard, tool);
          expect(content.exitCode, 0, reason: '$tool: ${content.describe()}');
        } finally {
          sandbox.dispose();
        }
      }
    });

    test('an update that also touches app, release or signing files is caught',
        () {
      for (final String extra in <String>[
        'lib/main.dart',
        'pubspec.yaml',
        'pubspec.lock',
        '.flutter-version',
        '.java-version',
        'metadata/io.github.thezupzup.linthra.yml',
        'fastlane/metadata/android/en-US/changelogs/201999.txt',
        'docs/release-notes/v0.2.1.md',
        'android/key.properties',
        'LICENSE',
        '.github/workflows/ci.yml',
      ]) {
        final _GitSandbox sandbox = _GitSandbox(root);
        try {
          _run(writer, <String>[
            '--tool',
            'agp',
            '--version',
            _bumpPatch(sandbox.pin('agp')),
            '--repo-root',
            sandbox.path,
          ]);
          sandbox.touch(extra);

          expect(sandbox.fileGuard(fileGuard, 'agp').exitCode, isNot(0),
              reason: 'The file guard let $extra ride along on an AGP update.');
          final _Run content = sandbox.contentGuard(diffGuard, 'agp');
          expect(content.exitCode, isNot(0),
              reason: 'The content guard let $extra ride along.\n'
                  '${content.describe()}');
          expect(content.stderr, contains(extra));
        } finally {
          sandbox.dispose();
        }
      }
    });

    test('an AGP branch that also moves Kotlin is caught by the content guard',
        () {
      // The case the whole content guard exists for: the file allowlist is
      // *satisfied* here, because only android/settings.gradle changed.
      final _GitSandbox sandbox = _GitSandbox(root);
      try {
        _run(writer, <String>[
          '--tool',
          'agp',
          '--version',
          _bumpPatch(sandbox.pin('agp')),
          '--repo-root',
          sandbox.path,
        ]);
        _run(writer, <String>[
          '--tool',
          'kotlin',
          '--version',
          _bumpPatch(sandbox.pin('kotlin')),
          '--repo-root',
          sandbox.path,
        ]);

        expect(sandbox.fileGuard(fileGuard, 'agp').exitCode, 0,
            reason: 'Only settings.gradle changed, so the filename allowlist '
                'is happy — which is exactly the blind spot.');
        final _Run content = sandbox.contentGuard(diffGuard, 'agp');
        expect(content.exitCode, isNot(0), reason: content.describe());
        expect(content.stderr, contains('Kotlin Gradle plugin'));
      } finally {
        sandbox.dispose();
      }
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
      expect(workflow, contains('scripts/check_android_toolchain_update.py'),
          reason: 'The version comparison must not live in YAML, where it '
              'cannot be tested offline.');
    });

    test('it uses the three toolchain branches, exactly named', () {
      expect(workflow, contains(r'UPDATE_BRANCH: toolchain/${{ matrix.tool }}'),
          reason: 'Each tool needs its own reusable branch.');
      expect(workflow.contains('UPDATE_BRANCH: deps/'), isFalse,
          reason: 'A deps/ branch would inherit the Dart updater\'s '
              'lockfile-only allowlist.');
      expect(workflow.contains('toolchain/flutter-sdk'), isFalse,
          reason: 'This updater must not publish onto the SDK updater\'s '
              'branch.');
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

    test('it never migrates anything', () {
      // No SDK, no Gradle, no analyzer, no formatter, no code generation: this
      // workflow has no way to "fix" the repo even if it wanted to.
      for (final String forbidden in <String>[
        'setup-flutter',
        'setup-java',
        'dart format',
        'gradlew',
        'codex',
        'build_runner',
      ]) {
        expect(workflow.contains(forbidden), isFalse,
            reason: 'The toolchain updater must not run `$forbidden`. A bump '
                'that breaks the build stays red for a human.');
      }
    });
  });

  group('the draft PR job', () {
    late final String job = _jobSection(workflow, 'toolchain-pr');

    test('it fans out over the tools that have an in-major update', () {
      expect(job, contains('fromJSON(needs.check.outputs.pr_tools)'));
      expect(job, contains("needs.check.outputs.pr_tools != '[]'"),
          reason: 'A week with nothing to publish must not start this job.');
    });

    test('it proposes the newest release on the pinned major, never the newest',
        () {
      expect(job, contains('latest_in_current_major'),
          reason: 'The PR target must come from the current major line.');
      expect(job.contains(r'results)[matrix.tool].latest }}'), isFalse,
          reason: 'The overall newest release must never become the PR target '
              '— that is how a major would sneak into a pin.');
    });

    test('it refuses a target that is not on the pinned major', () {
      expect(job, contains(r'"${TARGET%%.*}" != "${CURRENT%%.*}"'),
          reason: 'A last-line check that the target shares the pinned major, '
              'in case the job inputs were tampered with.');
    });

    test('it publishes with the dedicated token so the PR runs normal CI', () {
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

    test('a run with nothing to publish never reaches the token check', () {
      // The requirement is a pair: fail loudly when publishing is needed, and
      // never fail a quiet week for want of a secret.
      final String check = _jobSection(workflow, 'check');
      expect(check.contains('DEPENDENCY_UPDATE_TOKEN'), isFalse,
          reason: 'The detection job must not require the publication token; '
              'a week with no update must not fail.');
      final String issueJob = _jobSection(workflow, 'major-issue');
      expect(issueJob.contains('DEPENDENCY_UPDATE_TOKEN'), isFalse,
          reason: 'A major files an issue, which needs no CI and no token.');
    });

    test('the PR is a draft against main', () {
      expect(job, contains('gh pr create'));
      expect(job, contains('--draft'));
      expect(job, contains('--base main'));
    });

    test('it reuses one PR per tool instead of opening duplicates every week',
        () {
      expect(job, contains('--head "\$UPDATE_BRANCH"'),
          reason: 'The existing-PR lookup has to be scoped to this tool\'s '
              'branch, or the three tools would fight over one PR.');
      expect(job, contains('--state open --json number'));
      expect(job, contains('gh pr edit'));
    });

    test('a rerun with the same target pushes nothing at all', () {
      expect(job, contains('branch_matches_target'));
      expect(job, contains('already proposes'),
          reason: 'Repeated runs must be idempotent: same target, no new '
              'commit, no force-push.');
    });

    test('it refuses to force-push over commits it did not write', () {
      expect(job, contains('--force-with-lease'),
          reason: 'A plain force push could drop a concurrent update.');
      expect(job, contains('foreign'));
      expect(job, contains(r'"$author" == "github-actions[bot]"'),
          reason: 'Ownership is decided by author *and* subject, so a human '
              'commit on the branch is always foreign.');
      expect(job, contains(r'"$subject_line" == "$subject_prefix"*'),
          reason: 'The subject prefix is per tool, so a Kotlin commit on the '
              'AGP branch is foreign too.');
    });

    test('it will not rewind its own branch to an older version', () {
      expect(job, contains('Refusing to rewind the open PR'));
    });

    test('it re-checks its own blast radius before committing', () {
      expect(job, contains(r'check_dependency_update_files.sh --kind "$TOOL"'),
          reason: 'Which files moved, checked before a commit exists.');
      expect(job,
          contains(r'check_toolchain_pin_diff.py --kind "$TOOL" --base HEAD'),
          reason: 'What changed inside them, checked before a commit exists — '
              'this is the half a filename cannot do.');
    });

    test('it stages one file and never the whole tree', () {
      expect(job, contains(r'git add -- "$PIN_FILE"'));
      expect(job.contains('git add -A'), isFalse);
      expect(job.contains('git add .\n'), isFalse);
    });

    test('the PR body carries everything a reviewer needs', () {
      for (final String required in <String>[
        'Currently pinned',
        'Proposed',
        'Source',
        'confirmed',
        'Prereleases',
        'may be red',
        'Flutter compatibility',
        'F-Droid',
        'reproducib',
        'auto-merges',
        '#362',
      ]) {
        expect(job, contains(required),
            reason: 'The PR body must mention "$required".');
      }
    });
  });

  group('the major upgrade job', () {
    late final String job = _jobSection(workflow, 'major-issue');

    test('it fans out over the tools that have a newer major', () {
      expect(job, contains('fromJSON(needs.check.outputs.issue_tools)'));
      expect(job, contains("needs.check.outputs.issue_tools != '[]'"));
    });

    test('it files an issue and opens no PR', () {
      expect(job, contains('gh issue create'));
      expect(job, contains('gh issue edit'));
      expect(job.contains('gh pr create'), isFalse,
          reason: 'A major release must never produce a pin-bump PR.');
    });

    test('it changes no repository file, and cannot', () {
      for (final String forbidden in <String>[
        'git commit',
        'git push',
        'git checkout',
        'actions/checkout',
        'set_android_toolchain_pin',
      ]) {
        expect(job.contains(forbidden), isFalse,
            reason: 'The major path runs `$forbidden`. A major update must '
                'change nothing in the repository (#362). It does not even '
                'check the repository out.');
      }
    });

    test('it needs no publication token, only permission to file an issue', () {
      expect(job, contains('issues: write'));
      expect(job, contains('contents: read'));
      expect(job.contains('DEPENDENCY_UPDATE_TOKEN'), isFalse);
    });

    test('it updates the open issue instead of refiling every week', () {
      expect(job, contains('select(.title == env.TITLE)'),
          reason: 'The weekly run must find its own issue by title and edit '
              'it, or the maintainer gets a duplicate every Monday.');
      expect(job, contains(r'title="$LABEL ${major}.x is available'),
          reason: 'The title has to be stable for a whole major line, and '
              'distinct per tool, or the three would collide.');
    });

    test('the issue body says what a maintainer needs to decide', () {
      for (final String required in <String>[
        'Currently pinned',
        'Newest stable',
        'Newest stable on the pinned major',
        'Source',
        'stays manual',
        'Flutter compatibility',
        'F-Droid',
        'reproduc',
        '#362',
      ]) {
        expect(job, contains(required),
            reason: 'The issue body must mention "$required".');
      }
    });

    test('an AGP major warns about the legacy variant/versionCode behaviour',
        () {
      expect(job, contains(r'"$TOOL" == "agp"'),
          reason: 'The AGP major issue needs its own warning.');
      for (final String required in <String>[
        'applicationVariants',
        'versionCode',
        'F-Droid',
      ]) {
        expect(job, contains(required),
            reason: 'The AGP major warning must mention "$required": Linthra '
                'still builds per-ABI version codes from the legacy variant '
                'API, and published version codes can never be reused.');
      }
    });

    test('it says a newer major does not block the in-major update', () {
      expect(job, contains('tracked separately'),
          reason: 'The issue should make clear that the ordinary draft PR for '
              'the pinned major line still happens.');
    });
  });

  // ---------------------------------------------------------------------------
  // The boundary is re-checked on the PR itself, and the fixer stays away.
  // ---------------------------------------------------------------------------
  group('the boundary is re-checked on the PR itself', () {
    test('ci.yml matches the three automatic branches exactly', () {
      for (final String branch in <String>[
        'toolchain/gradle',
        'toolchain/agp',
        'toolchain/kotlin',
      ]) {
        expect(ci, contains("github.head_ref == '$branch'"),
            reason: 'CI must guard $branch against the real PR diff.');
      }
      expect(ci.contains("startsWith(github.head_ref, 'toolchain/')"), isFalse,
          reason: 'A prefix match would hold every future human toolchain/* PR '
              'to the pin-only rule, and could not tell which of the three '
              'pins the PR is allowed to move. #373 fixed exactly this for the '
              'Flutter SDK branch; do not reintroduce it.');
    });

    test('ci.yml runs both guards, the same two the updater ran', () {
      expect(
          ci,
          contains(
              r'./scripts/check_dependency_update_files.sh --kind "$kind"'));
      expect(ci, contains('scripts/check_toolchain_pin_diff.py'));
      expect(ci, contains(r'--kind "$kind" --base "$BASE_SHA" --head HEAD'),
          reason: 'The content guard must run against the PR\'s real diff, not '
              'against the working tree.');
    });

    test('the guard kind is derived from the branch, so it cannot be widened',
        () {
      expect(ci, contains(r'kind="${HEAD_REF#toolchain/}"'),
          reason: 'toolchain/agp must be checked as an AGP update and nothing '
              'else — the branch name is what decides which pin may move.');
    });

    test('the earlier guards still run on their own branches', () {
      expect(ci, contains("startsWith(github.head_ref, 'deps/')"));
      expect(ci, contains("github.head_ref == 'toolchain/flutter-sdk'"));
      expect(ci, contains('--kind dart-packages'));
      expect(ci, contains('--kind flutter-sdk'));
    });

    test('CI runs on every PR, so a toolchain PR is never unchecked', () {
      expect(ci, contains('pull_request:'));
      expect(ci.contains('pull_request:\n    branches'), isFalse);
    });
  });

  group('the CI fixer leaves the toolchain branches alone', () {
    test('the fix job still skips toolchain/ alongside dependabot/ and deps/',
        () {
      // Regression cover for #373's behaviour now that three more branches
      // live under toolchain/.
      for (final String prefix in <String>[
        'dependabot/',
        'deps/',
        'toolchain/',
      ]) {
        expect(fixer, contains('"\$head_branch" == $prefix*'),
            reason: 'A toolchain update that breaks CI must stay broken — the '
                'red is the signal. Missing: $prefix');
      }
    });

    test('the publish job restates the skip where the push happens', () {
      expect(
          fixer,
          contains(
              "!startsWith(needs.fix.outputs.target_branch, 'toolchain/')"),
          reason: 'The last gate before a commit is pushed must also refuse '
              'toolchain/ branches.');
    });

    test('the fixer may not touch a toolchain pin in any PR', () {
      // Not just on toolchain/ branches: the agent must never repair CI by
      // moving a build-tool version, wherever it is working.
      for (final String protected in <String>[
        r'\.flutter-version$',
        r'\.java-version$',
        r'android/settings\.gradle$',
        r'android/gradle/wrapper/gradle-wrapper\.properties$',
      ]) {
        expect(fixer, contains(protected),
            reason: 'The protected-path guard must keep $protected out of '
                'every agent patch.');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Documentation.
  // ---------------------------------------------------------------------------
  group('the documentation describes what actually happens', () {
    test('it no longer claims the Android toolchain is unautomated', () {
      expect(
          docs.contains(
              'The rest of the toolchain — Gradle, AGP, Kotlin and the JDK — is not automated'),
          isFalse,
          reason: 'docs/dependency-updates.md still says Gradle, AGP and '
              'Kotlin are handled by hand.');
    });

    test('it documents the pieces a maintainer needs', () {
      for (final String required in <String>[
        'android-toolchain-updates.yml',
        'check_android_toolchain_update.py',
        'check_toolchain_pin_diff.py',
        'set_android_toolchain_pin.py',
        'toolchain/gradle',
        'toolchain/agp',
        'toolchain/kotlin',
        'services.gradle.org/versions/all',
        'maven-metadata.xml',
        'DEPENDENCY_UPDATE_TOKEN',
        'applicationVariants',
        'F-Droid',
      ]) {
        expect(docs, contains(required),
            reason: 'docs/dependency-updates.md must mention "$required".');
      }
    });

    test('it describes all five phases of #362', () {
      for (final String required in <String>[
        '#363',
        '#364',
        '#370',
        '#373',
        '#362',
      ]) {
        expect(docs, contains(required),
            reason: 'docs/dependency-updates.md must reference $required so '
                'the five phases are all accounted for.');
      }
    });

    test('it still documents the earlier updaters', () {
      for (final String required in <String>[
        'pubspec.lock',
        '.flutter-version',
        'flutter-sdk-updates.yml',
        'dart-dependency-updates.yml',
        'dependabot.yml',
      ]) {
        expect(docs, contains(required),
            reason: 'Phase 5 must not have dropped the earlier phases from '
                'the documentation. Missing: $required');
      }
    });
  });
}

// -----------------------------------------------------------------------------
// Fixtures and helpers.
// -----------------------------------------------------------------------------

const List<String> _tools = <String>['gradle', 'agp', 'kotlin'];

/// The group/artifact each Maven-backed tool's metadata must declare.
const Map<String, List<String>> _mavenCoordinates = <String, List<String>>{
  'agp': <String>['com.android.tools.build', 'gradle'],
  'kotlin': <String>['org.jetbrains.kotlin', 'kotlin-gradle-plugin'],
};

/// A release entry shaped like Gradle's own release index.
Map<String, dynamic> _gradleEntry(
  String version, {
  bool isFinal = true,
  bool snapshot = false,
  bool nightly = false,
  bool releaseNightly = false,
  bool activeRc = false,
  bool broken = false,
  String rcFor = '',
  String milestoneFor = '',
  String? downloadUrl,
}) =>
    <String, dynamic>{
      'version': version,
      'buildTime': '20260101000000+0000',
      'commitId': 'commit-$version',
      'current': false,
      'snapshot': snapshot,
      'nightly': nightly,
      'releaseNightly': releaseNightly,
      'activeRc': activeRc,
      'rcFor': rcFor,
      'milestoneFor': milestoneFor,
      'broken': broken,
      'downloadUrl': downloadUrl ??
          'https://services.gradle.org/distributions/gradle-$version-bin.zip',
      'checksumUrl':
          'https://services.gradle.org/distributions/gradle-$version-bin.zip.sha256',
      'released': true,
      'final': isFinal,
    };

String _gradleIndex(
  List<String> finalVersions, {
  List<Map<String, dynamic>> extra = const <Map<String, dynamic>>[],
}) =>
    const JsonEncoder.withIndent('  ').convert(<Map<String, dynamic>>[
      for (final String version in finalVersions) _gradleEntry(version),
      ...extra,
    ]);

String _mavenMetadata(
  String groupId,
  String artifactId,
  List<String> versions, {
  String? latest,
  String? release,
}) =>
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<metadata>\n'
    '  <groupId>$groupId</groupId>\n'
    '  <artifactId>$artifactId</artifactId>\n'
    '  <versioning>\n'
    '    <latest>${latest ?? versions.last}</latest>\n'
    '    <release>${release ?? versions.last}</release>\n'
    '    <versions>\n'
    '${versions.map((String v) => '      <version>$v</version>').join('\n')}\n'
    '    </versions>\n'
    '  </versioning>\n'
    '</metadata>\n';

/// The index text a tool would fetch, holding exactly [versions] as releases.
String _indexFor(String tool, List<String> versions) {
  if (tool == 'gradle') return _gradleIndex(versions);
  final List<String> coordinates = _mavenCoordinates[tool]!;
  return _mavenMetadata(coordinates[0], coordinates[1], versions);
}

String _writeGradleIndex(Directory dir, List<String> versions) {
  final File file = File(p.join(dir.path, 'gradle-versions.json'))
    ..writeAsStringSync(_gradleIndex(versions));
  return file.path;
}

/// Runs the checker for one tool against a synthesised index. No network.
_Tool _check(
  String checker, {
  required String tool,
  required String current,
  required List<String> versions,
}) =>
    _runWithIndex(checker, tool, current, _indexFor(tool, versions)).tool(tool);

_Run _runWithIndex(String checker, String tool, String current, String index) {
  final Directory tmp = Directory.systemTemp.createTempSync('toolchain-index');
  try {
    final File file = File(p.join(tmp.path, 'index'))..writeAsStringSync(index);
    return _run(checker, <String>[
      '--tool',
      tool,
      '--current',
      current,
      '--versions-file',
      file.path,
      '--json',
    ]);
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

_Run _run(String script, List<String> args) {
  final ProcessResult r = Process.runSync(
    'python3',
    <String>[script, ...args],
    stdoutEncoding: const SystemEncoding(),
    stderrEncoding: const SystemEncoding(),
  );
  return _Run(r.exitCode, r.stdout.toString(), r.stderr.toString());
}

ProcessResult _runFileGuard(String script, String kind, List<String> paths) =>
    Process.runSync(
      'bash',
      <String>[script, '--kind', kind, ...paths],
      stdoutEncoding: const SystemEncoding(),
      stderrEncoding: const SystemEncoding(),
    );

/// Runs the content guard over two in-memory versions of a pin file.
_Run _runDiffGuard(String script, String kind, String before, String after) {
  final Directory tmp = Directory.systemTemp.createTempSync('toolchain-diff');
  try {
    final File beforeFile = File(p.join(tmp.path, 'before'))
      ..writeAsStringSync(before);
    final File afterFile = File(p.join(tmp.path, 'after'))
      ..writeAsStringSync(after);
    return _run(script, <String>[
      '--kind',
      kind,
      '--before-file',
      beforeFile.path,
      '--after-file',
      afterFile.path,
    ]);
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

// Pin readers and rewriters used to build fixtures out of the repository's real
// files. They are deliberately independent of scripts/toolchain_pins.py — a
// test that reused the implementation could not catch the implementation being
// wrong.
final RegExp _agpRe =
    RegExp(r'(id\s+"com\.android\.application"\s+version\s+")([^"]+)(")');
final RegExp _kotlinRe =
    RegExp(r'(id\s+"org\.jetbrains\.kotlin\.android"\s+version\s+")([^"]+)(")');
final RegExp _gradleRe =
    RegExp(r'(distributionUrl=\S*?/gradle-)([^-]+)(-(?:all|bin)\.zip)');

String _agpPin(String text) => _agpRe.firstMatch(text)!.group(2)!;
String _kotlinPin(String text) => _kotlinRe.firstMatch(text)!.group(2)!;
String _gradlePin(String text) => _gradleRe.firstMatch(text)!.group(2)!;

String _bumpAgp(String text, String version) =>
    text.replaceFirstMapped(_agpRe, (Match m) => '${m[1]}$version${m[3]}');
String _bumpKotlin(String text, String version) =>
    text.replaceFirstMapped(_kotlinRe, (Match m) => '${m[1]}$version${m[3]}');
String _bumpGradle(String text, String version) =>
    text.replaceFirstMapped(_gradleRe, (Match m) => '${m[1]}$version${m[3]}');

/// `1.2.3` -> `1.2.4`. Keeps fixtures on the pinned major without hardcoding
/// a version number that would go stale the moment a pin moves.
String _bumpPatch(String version) {
  final List<String> parts = version.split('.');
  return '${parts[0]}.${parts[1]}.${int.parse(parts[2]) + 1}';
}

/// A throwaway copy of the repository's pin files, so a write test can run the
/// real writer without touching the checkout.
class _Sandbox {
  _Sandbox(String root)
      : _dir = Directory.systemTemp.createTempSync('toolchain-sandbox') {
    Directory(p.join(path, 'android', 'gradle', 'wrapper'))
        .createSync(recursive: true);
    for (final String relative in <String>[
      p.join('android', 'settings.gradle'),
      p.join('android', 'gradle', 'wrapper', 'gradle-wrapper.properties'),
    ]) {
      File(p.join(path, relative))
          .writeAsStringSync(File(p.join(root, relative)).readAsStringSync());
    }
  }

  final Directory _dir;

  String get path => _dir.path;

  String pinFileText(String tool) => File(p.join(
          path,
          tool == 'gradle'
              ? p.join(
                  'android', 'gradle', 'wrapper', 'gradle-wrapper.properties')
              : p.join('android', 'settings.gradle')))
      .readAsStringSync();

  String pin(String tool) {
    final String text = pinFileText(tool);
    switch (tool) {
      case 'gradle':
        return _gradlePin(text);
      case 'agp':
        return _agpPin(text);
      default:
        return _kotlinPin(text);
    }
  }

  void dispose() => _dir.deleteSync(recursive: true);
}

/// A sandbox that is also a git repository, so the guards can be run the way
/// CI runs them: against a real diff.
class _GitSandbox extends _Sandbox {
  _GitSandbox(super.root) {
    _git(<String>['init', '-q', '.']);
    _git(<String>['add', '-A']);
    _git(<String>[
      '-c',
      'user.email=guardrails@example.invalid',
      '-c',
      'user.name=guardrails',
      'commit',
      '-qm',
      'fixture',
    ]);
  }

  ProcessResult _git(List<String> args) => Process.runSync(
        'git',
        <String>['-C', path, ...args],
        stdoutEncoding: const SystemEncoding(),
        stderrEncoding: const SystemEncoding(),
      );

  /// Creates (or appends to) a file the automatic update has no business in.
  void touch(String relative) {
    final File file = File(p.join(path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('# added by a guardrail test\n',
        mode: FileMode.append);
  }

  ProcessResult fileGuard(String script, String kind) {
    final ProcessResult diff = _git(<String>['diff', '--name-only', 'HEAD']);
    final List<String> paths = diff.stdout
        .toString()
        .split('\n')
        .where((String line) => line.trim().isNotEmpty)
        .toList();
    // Untracked files never show up in `git diff`, so add them first — the
    // updater's own pipeline runs against an index, not a bare working tree.
    final ProcessResult untracked =
        _git(<String>['ls-files', '--others', '--exclude-standard']);
    paths.addAll(untracked.stdout
        .toString()
        .split('\n')
        .where((String line) => line.trim().isNotEmpty));
    return Process.runSync(
      'bash',
      <String>[script, '--kind', kind, ...paths],
      stdoutEncoding: const SystemEncoding(),
      stderrEncoding: const SystemEncoding(),
    );
  }

  _Run contentGuard(String script, String kind) {
    _git(<String>['add', '-A']);
    return _run(script, <String>[
      '--kind',
      kind,
      '--base',
      'HEAD',
      '--repo-root',
      path,
    ]);
  }
}

class _Run {
  _Run(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;

  _Tool tool(String name) {
    if (exitCode != 0) return _Tool(exitCode, stdout, stderr, null);
    final Map<String, dynamic> parsed =
        jsonDecode(stdout) as Map<String, dynamic>;
    return _Tool(
        exitCode, stdout, stderr, parsed[name] as Map<String, dynamic>?);
  }

  String describe() => 'exit: $exitCode\nstdout:\n$stdout\nstderr:\n$stderr';
}

class _Tool extends _Run {
  _Tool(super.exitCode, super.stdout, super.stderr, this._result);

  final Map<String, dynamic>? _result;

  String get status => value('status');

  String value(String key) => (_result?[key] ?? '').toString();
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
