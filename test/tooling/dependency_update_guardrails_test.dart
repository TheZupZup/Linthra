import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Guardrails for the automatic Dart/Flutter package updater (issue #362).
///
/// The updater is allowed to do exactly one thing: re-resolve the dependency
/// graph with the pinned Flutter SDK and rewrite `pubspec.lock`. Everything
/// else about it is a safety boundary —
///
///   * it resolves with the SDK from `.flutter-version`, because the
///     reproducible F-Droid build resolves from the committed lockfile;
///   * it never edits the constraints in `pubspec.yaml`, so no direct
///     dependency can cross a major version;
///   * it never touches application code, tests, the app version, F-Droid
///     metadata, Fastlane files, release notes, signing material or licenses;
///   * it never merges, and the PR it opens runs the normal CI;
///   * the Flutter CI fixer leaves its branches alone, so an update that needs
///     application changes stays red for a human.
///
/// Those boundaries are the whole value of the updater, so they are tests
/// rather than review notes. This suite reads files and shells out to the
/// offline guard script; it never resolves dependencies or touches the network.
///
/// Sibling coverage: test/tooling/toolchain_pins_test.dart pins the toolchain
/// versions, test/tooling/fdroid_release_guardrails_test.dart pins the release
/// plumbing (including that `pubspec.lock` stays tracked at all).
void main() {
  final String root = _repoRoot();

  final String guardScript =
      p.join(root, 'scripts', 'check_dependency_update_files.sh');
  late final String updater =
      _read(root, p.join('scripts', 'update_dart_dependencies.sh'));
  late final String workflow = _read(
      root, p.join('.github', 'workflows', 'dart-dependency-updates.yml'));
  late final String ci = _read(root, p.join('.github', 'workflows', 'ci.yml'));
  late final String fixer =
      _read(root, p.join('.github', 'workflows', 'flutter-ci-fixer.yml'));

  group('the allowlist guard admits only the lockfile', () {
    test('pubspec.lock alone passes', () {
      final ProcessResult r = _runGuard(guardScript, <String>['pubspec.lock']);
      expect(r.exitCode, 0, reason: 'stdout: ${r.stdout}\nstderr: ${r.stderr}');
    });

    test('an empty change set passes', () {
      final ProcessResult r = _runGuard(guardScript, const <String>[]);
      expect(r.exitCode, 0, reason: 'stdout: ${r.stdout}\nstderr: ${r.stderr}');
    });

    // One case per rule the issue spells out. If someone widens the allowlist,
    // the specific protection they removed is named in the failure.
    const Map<String, String> forbidden = <String, String>{
      'pubspec.yaml': 'dependency constraints (would allow a major upgrade)',
      'lib/main.dart': 'application code',
      'lib/core/app_info.dart': 'the in-app version',
      'test/core/app_info_version_test.dart': 'test code',
      'metadata/io.github.thezupzup.linthra.yml': 'F-Droid metadata',
      'fastlane/metadata/android/en-US/changelogs/201999.txt': 'Fastlane files',
      'docs/release-notes/v0.2.1.md': 'release notes',
      'android/key.properties': 'signing configuration',
      'android/app/linthra-release.jks': 'signing material',
      'LICENSE': 'the license',
      '.flutter-version': 'the Flutter pin',
      '.github/workflows/ci.yml': 'CI configuration',
      'scripts/check_dependency_update_files.sh': 'the guard itself',
    };

    forbidden.forEach((String path, String why) {
      test('$path is rejected — $why', () {
        final ProcessResult r =
            _runGuard(guardScript, <String>['pubspec.lock', path]);
        expect(r.exitCode, isNot(0),
            reason: 'An automatic dependency update must not change $why.\n'
                'stdout: ${r.stdout}');
        expect(r.stderr, contains(path),
            reason: 'The rejection should name the offending path.');
      });
    });
  });

  group('the updater resolves the way the lockfile requires', () {
    test('it runs plain `flutter pub upgrade`', () {
      expect(updater, contains('flutter pub upgrade'),
          reason: 'The updater must re-resolve inside the existing '
              'constraints with `flutter pub upgrade`.');
    });

    test('it never passes --major-versions or --tighten', () {
      // Both rewrite pubspec.yaml. `--major-versions` additionally has no
      // negated form: `--major-versions=false` fails with
      // 'Flag option "--major-versions" should not be given a value.' (exit 64),
      // so "upgrade but not majors" is plain `pub upgrade`, not a flag.
      for (final String flag in <String>['--major-versions', '--tighten']) {
        for (final String line in updater.split('\n')) {
          if (line.trimLeft().startsWith('#')) continue;
          expect(line.contains(flag), isFalse,
              reason: 'scripts/update_dart_dependencies.sh runs $flag in:\n'
                  '  $line\n'
                  'That flag edits the constraints in pubspec.yaml, which an '
                  'automatic update must never do.');
        }
      }
    });

    test('it refuses to resolve with an SDK other than the pinned one', () {
      expect(updater, contains('.flutter-version'),
          reason: 'The updater must read the pinned Flutter version.');
      expect(updater, contains(r'if [ "$actual" != "$required" ]; then'),
          reason: 'The updater must compare the Flutter on PATH against '
              '.flutter-version and stop when they differ — a lockfile '
              'resolved with a different SDK breaks the F-Droid build.');
    });

    test('it re-checks the result with --enforce-lockfile', () {
      expect(updater, contains('flutter pub get --enforce-lockfile'),
          reason: 'The generated lockfile must satisfy the same check ci.yml '
              'runs before it can become a PR.');
    });

    test('it pipes the changed files through the allowlist guard', () {
      expect(updater, contains('check_dependency_update_files.sh'),
          reason: 'The updater must verify its own blast radius before '
              'anything is committed.');
    });

    test('it commits nothing itself', () {
      for (final String forbidden in <String>[
        'git commit',
        'git push',
        'gh pr create',
      ]) {
        expect(updater.contains(forbidden), isFalse,
            reason: 'scripts/update_dart_dependencies.sh runs `$forbidden`. '
                'The script only prepares and validates the lockfile; '
                'publishing belongs to the workflow.');
      }
    });
  });

  group('the update workflow stays inside its boundaries', () {
    test('it runs on a schedule and can be dispatched by hand', () {
      expect(workflow, contains('schedule:'));
      expect(workflow, contains('cron:'));
      expect(workflow, contains('workflow_dispatch:'));
    });

    test('it delegates resolution to the shared script', () {
      expect(workflow, contains('./scripts/update_dart_dependencies.sh'),
          reason: 'The workflow and the local twin must run the same code.');
    });

    test('it installs Flutter through the pinned setup action', () {
      expect(workflow, contains('uses: ./.github/actions/setup-flutter'),
          reason: 'Resolution has to use the pinned SDK.');
    });

    test('its own GITHUB_TOKEN is read-only', () {
      expect(workflow, contains('permissions:\n  contents: read'),
          reason: 'Writes must go through the dedicated publication token, '
              'not an elevated GITHUB_TOKEN.');
    });

    test('it publishes with a dedicated token so the PR runs normal CI', () {
      // A push or PR made with GITHUB_TOKEN does not trigger workflows, and an
      // update PR that runs no checks is a broken updater (#362).
      expect(workflow, contains(r'secrets.DEPENDENCY_UPDATE_TOKEN'),
          reason: 'The PR must be created with a token that retriggers CI.');
      expect(workflow.contains('GH_TOKEN: \${{ github.token }}'), isFalse,
          reason: 'github.token cannot retrigger CI on the PR it opens.');
    });

    test('the PR is a draft against main', () {
      expect(workflow, contains('gh pr create'));
      expect(workflow, contains('--draft'),
          reason: 'Update PRs open as drafts for review.');
      expect(workflow, contains('--base main'));
    });

    test('it reuses one branch instead of opening duplicates', () {
      expect(workflow, contains('UPDATE_BRANCH: deps/dart-packages'));
      expect(workflow, contains('--state open --json number'),
          reason: 'The workflow must look for an existing open PR on the '
              'update branch and edit it rather than open another.');
    });

    test('it refuses to force-push over commits it did not write', () {
      expect(workflow, contains('--force-with-lease'),
          reason: 'A plain force push could drop a concurrent update.');
      expect(workflow, contains('foreign='),
          reason: 'The workflow must detect commits on the update branch that '
              'it did not author and stop instead of overwriting them.');
    });

    test('it never merges anything', () {
      for (final String forbidden in <String>[
        'gh pr merge',
        '--auto',
        '--admin',
        '--squash',
        '--rebase',
      ]) {
        expect(workflow.contains(forbidden), isFalse,
            reason: 'The update workflow contains `$forbidden`. Nothing may '
                'ever merge into main automatically (#362).');
      }
    });

    test('a failing check does not block the PR from opening', () {
      // The red PR is the deliverable when an update needs application
      // changes, so format/analyze/test are reported, not gated on.
      expect('continue-on-error: true'.allMatches(workflow).length, 3,
          reason: 'dart format, flutter analyze and flutter test must each run '
              'without failing the job, so the update still reaches a human.');
    });
  });

  group('the boundary is re-checked on the PR itself', () {
    test('ci.yml guards deps/ PRs with the same script', () {
      expect(ci, contains("startsWith(github.head_ref, 'deps/')"),
          reason: 'CI must run the lockfile-only guard on update PRs.');
      expect(ci, contains('./scripts/check_dependency_update_files.sh'),
          reason:
              'The PR-side guard must be the same script the updater uses.');
    });

    test('CI runs on every PR, so an update PR is never unchecked', () {
      expect(ci, contains('pull_request:'));
      expect(ci.contains('pull_request:\n    branches'), isFalse,
          reason: 'A branch filter on pull_request would let an update PR '
              'merge without the normal checks.');
    });
  });

  group('the CI fixer leaves dependency updates alone', () {
    test('the fix job skips deps/ branches alongside dependabot/', () {
      // Matched per prefix rather than as one literal line, so extending the
      // condition for another updater's namespace (toolchain/, covered by
      // test/tooling/flutter_sdk_update_guardrails_test.dart) cannot silently
      // drop one of the prefixes already protected here.
      for (final String prefix in <String>['dependabot/', 'deps/']) {
        expect(
          fixer,
          contains('"\$head_branch" == $prefix*'),
          reason: 'A dependency update that breaks CI must stay broken — the '
              'red is the signal. The skip has to happen while resolving the '
              'run, before any repair is generated. Missing: $prefix',
        );
      }
    });

    test('the publish job restates the skip where the push happens', () {
      expect(
        fixer,
        contains("!startsWith(needs.fix.outputs.target_branch, 'dependabot/')"),
      );
      expect(
        fixer,
        contains("!startsWith(needs.fix.outputs.target_branch, 'deps/')"),
        reason: 'The last gate before a commit is pushed must also refuse '
            'dependency update branches.',
      );
    });
  });

  group('a Linux FFI plugin is a reviewed decision (#681)', () {
    // An FFI plugin's native code is built into the Linux bundle by CMake,
    // with whatever the build machine happens to have: jni's, for one, links
    // the host's JVM wherever a JDK is installed, which CI runners have and
    // the Flatpak builder does not. A lockfile refresh that brings one in is
    // refused by the updater (it rewrites generated_plugins.cmake), and a
    // human PR that brings one in has to say so here, after deciding what the
    // desktop build and the Flatpak should do with it.
    const Set<String> reviewed = <String>{};

    test('generated_plugins.cmake lists only reviewed FFI plugins', () {
      final String cmake =
          _read(root, p.join('linux', 'flutter', 'generated_plugins.cmake'));
      final RegExpMatch? list =
          RegExp(r'list\(APPEND FLUTTER_FFI_PLUGIN_LIST([^)]*)\)')
              .firstMatch(cmake);
      expect(list, isNotNull,
          reason: 'generated_plugins.cmake no longer has an FFI plugin list');
      final Set<String> ffi = <String>{
        for (final String name in list!.group(1)!.split(RegExp(r'\s+')))
          if (name.isNotEmpty) name,
      };

      expect(ffi.difference(reviewed), isEmpty,
          reason: 'a new Linux FFI plugin needs a human review of what it '
              'builds into the desktop bundle and the Flatpak '
              '(docs/dependency-updates.md, "Held back on purpose")');
    });
  });

  group('a native build hook is a reviewed decision (#681)', () {
    // A package with a `hook/build.dart` runs it on every build, and the hook
    // may fetch or compile native code of its own. sqlite3 3.x, which drift
    // 2.32 needs, downloads a precompiled SQLite from GitHub unless told
    // otherwise. The Flatpak builds with the network off and F-Droid builds
    // from source, and a lockfile refresh that brings a hook in changes
    // nothing but pubspec.lock, so none of the updater's file guards see it.
    // It fails here instead, and a human PR that brings one in names it here,
    // after deciding what the builds do with it.
    const Map<String, String> reviewed = <String, String>{
      // path_provider_foundation's Objective-C runtime: its hook builds only
      // for iOS and macOS, and returns at once for Android and Linux.
      'objective_c': 'no-op outside iOS/macOS',
    };

    test('no resolved package ships a build hook nobody reviewed', () {
      final File config =
          File(p.join(root, '.dart_tool', 'package_config.json'));
      expect(config.existsSync(), isTrue,
          reason: 'package_config.json is missing: run flutter pub get');
      final Object? packages = (jsonDecode(config.readAsStringSync())
          as Map<String, dynamic>)['packages'];
      final Set<String> hooked = <String>{
        for (final Object? package in packages! as List<Object?>)
          if (package is Map<String, dynamic> &&
              _shipsBuildHook(config, package))
            package['name']! as String,
      };

      expect(hooked.difference(reviewed.keys.toSet()), isEmpty,
          reason: 'a package with a native build hook needs a human review '
              'of what it builds or downloads, for the F-Droid build and the '
              'Flatpak (docs/dependency-updates.md, "Held back on purpose")');
    });
  });

  group('pub is not left to Dependabot', () {
    test('.github/dependabot.yml declares no pub ecosystem', () {
      final String dependabot =
          _read(root, p.join('.github', 'dependabot.yml'));
      expect(dependabot.contains('package-ecosystem: "pub"'), isFalse,
          reason: 'Dependabot cannot meet Linthra\'s pub requirements: it '
              'resolves with its own Dart SDK and installs no Flutter, and '
              'every pub versioning-strategy it offers (widen / increase / '
              'increase-if-necessary) rewrites the constraints in '
              'pubspec.yaml. Dart packages are handled by '
              '.github/workflows/dart-dependency-updates.yml.');
    });
  });
}

ProcessResult _runGuard(String script, List<String> paths) => Process.runSync(
      'bash',
      <String>[script, ...paths],
      stdoutEncoding: const SystemEncoding(),
      stderrEncoding: const SystemEncoding(),
    );

/// Whether [package], an entry of the resolved [config], has a native build
/// hook. Its root is a directory URI, absolute or relative to [config].
bool _shipsBuildHook(File config, Map<String, dynamic> package) {
  final String rootUri = package['rootUri']! as String;
  final Uri dir =
      config.uri.resolve(rootUri.endsWith('/') ? rootUri : '$rootUri/');
  return File.fromUri(dir.resolve('hook/build.dart')).existsSync();
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
