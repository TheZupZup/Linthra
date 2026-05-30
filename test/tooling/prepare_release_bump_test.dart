import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../tool/version_from_tag.dart';

/// Specifies `scripts/prepare_release_bump.py` — the Python helper the
/// `.github/workflows/prepare-release-bump.yml` workflow calls to update
/// pubspec.yaml, lib/core/app_info.dart, the Fastlane changelog, and the
/// F-Droid metadata's `CurrentVersion`/`CurrentVersionCode`.
///
/// The script has to agree forever with `tool/version_from_tag.dart` and
/// `scripts/release_preflight.sh`, so this suite shells out to it against a
/// fixture repo and asserts the file edits and the safety rails.
void main() {
  final String repoRoot = _findRepoRoot();
  final String script = p.join(repoRoot, 'scripts', 'prepare_release_bump.py');

  setUpAll(() {
    if (!File(script).existsSync()) {
      fail('Prepare-release script not found at $script');
    }
    final ProcessResult which =
        Process.runSync('python3', <String>['--version']);
    if (which.exitCode != 0) {
      fail(
          'python3 is not on PATH; the prepare-release-bump script requires it.');
    }
  });

  group('prepare_release_bump.py — encoding matches version_from_tag.dart', () {
    // Same representative slice as release_preflight_test.dart, plus the user's
    // worked example. If the Dart encoding ever changes, this catches the drift.
    const List<String> tags = <String>[
      'v0.1.0-alpha.16',
      'v0.1.0-alpha.37',
      'v0.1.0-beta.1',
      'v0.1.0-rc.1',
      'v0.1.0',
      'v1.2.3',
    ];

    for (final String tag in tags) {
      test('$tag bumps pubspec.yaml to the canonical version+code', () async {
        final TagVersion expected = versionFromTag(tag);
        final Directory tmp = await _fixtureRepo(
          pubspecVersion: '0.1.0-alpha.1',
          pubspecCode: 100001,
          appInfoVersion: '0.1.0-alpha.1',
        );
        addTearDown(() async => tmp.delete(recursive: true));

        final ProcessResult r =
            _runScript(script, expected.name, repoRoot: tmp.path);
        expect(r.exitCode, 0,
            reason: 'stdout:\n${r.stdout}\nstderr:\n${r.stderr}');
        expect(
          File(p.join(tmp.path, 'pubspec.yaml')).readAsStringSync(),
          contains('version: ${expected.name}+${expected.code}'),
        );
        // Idempotent: a re-run is a no-op.
        final ProcessResult again =
            _runScript(script, expected.name, repoRoot: tmp.path);
        expect(again.exitCode, 0);
        expect(again.stdout, contains('No files changed'));
      });
    }

    test('alpha.37 -> 100037 (worked example)', () async {
      final TagVersion v = versionFromTag('v0.1.0-alpha.37');
      expect(v.name, '0.1.0-alpha.37');
      expect(v.code, 100037);
    });
  });

  group('prepare_release_bump.py — file edits', () {
    test('updates pubspec.yaml without collapsing surrounding blank lines',
        () async {
      final Directory tmp = await _fixtureRepo(
        pubspecBody: 'name: linthra\n'
            '# A comment.\n'
            'version: 0.1.0-alpha.36+100036\n'
            '\n'
            'environment:\n'
            '  sdk: ">=3.6.0 <4.0.0"\n',
        appInfoVersion: '0.1.0-alpha.36',
      );
      addTearDown(() async => tmp.delete(recursive: true));

      final ProcessResult r =
          _runScript(script, '0.1.0-alpha.37', repoRoot: tmp.path);
      expect(r.exitCode, 0,
          reason: 'stdout:\n${r.stdout}\nstderr:\n${r.stderr}');
      final String after =
          File(p.join(tmp.path, 'pubspec.yaml')).readAsStringSync();
      expect(after, contains('version: 0.1.0-alpha.37+100037'));
      // The blank line between `version:` and `environment:` must survive.
      expect(after, contains('100037\n\nenvironment:'));
    });

    test('updates AppInfo._devVersionName exactly once', () async {
      final Directory tmp = await _fixtureRepo(
        pubspecVersion: '0.1.0-alpha.36',
        pubspecCode: 100036,
        appInfoVersion: '0.1.0-alpha.36',
      );
      addTearDown(() async => tmp.delete(recursive: true));

      final ProcessResult r =
          _runScript(script, '0.1.0-alpha.37', repoRoot: tmp.path);
      expect(r.exitCode, 0,
          reason: 'stdout:\n${r.stdout}\nstderr:\n${r.stderr}');
      final String after =
          File(p.join(tmp.path, 'lib', 'core', 'app_info.dart'))
              .readAsStringSync();
      expect(after, contains("_devVersionName = '0.1.0-alpha.37'"));
      expect(after, isNot(contains("'0.1.0-alpha.36'")));
    });

    test('fails clearly when app_info.dart cannot be updated safely', () async {
      final Directory tmp = await _fixtureRepo(
        pubspecVersion: '0.1.0-alpha.36',
        pubspecCode: 100036,
        appInfoBody:
            'abstract final class AppInfo {\n  // _devVersionName intentionally missing.\n}\n',
      );
      addTearDown(() async => tmp.delete(recursive: true));

      final ProcessResult r =
          _runScript(script, '0.1.0-alpha.37', repoRoot: tmp.path);
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains("Could not find `_devVersionName"));
      expect(r.stderr, contains("Refusing to guess"));
    });

    test('creates the Fastlane changelog with a maintenance default', () async {
      final Directory tmp = await _fixtureRepo(
        pubspecVersion: '0.1.0-alpha.36',
        pubspecCode: 100036,
        appInfoVersion: '0.1.0-alpha.36',
      );
      addTearDown(() async => tmp.delete(recursive: true));

      final ProcessResult r =
          _runScript(script, '0.1.0-alpha.37', repoRoot: tmp.path);
      expect(r.exitCode, 0,
          reason: 'stdout:\n${r.stdout}\nstderr:\n${r.stderr}');
      final String changelog = File(p.join(
        tmp.path,
        'fastlane',
        'metadata',
        'android',
        'en-US',
        'changelogs',
        '100037.txt',
      )).readAsStringSync();
      expect(changelog, contains('Linthra 0.1.0-alpha.37'));
      expect(changelog, contains('Still an alpha'));
    });

    test('honors a custom --changelog body', () async {
      final Directory tmp = await _fixtureRepo(
        pubspecVersion: '0.1.0-alpha.36',
        pubspecCode: 100036,
        appInfoVersion: '0.1.0-alpha.36',
      );
      addTearDown(() async => tmp.delete(recursive: true));

      final ProcessResult r = _runScript(
        script,
        '0.1.0-alpha.37',
        repoRoot: tmp.path,
        extraArgs: <String>['--changelog', 'Hand-written notes.'],
      );
      expect(r.exitCode, 0,
          reason: 'stdout:\n${r.stdout}\nstderr:\n${r.stderr}');
      final String changelog = File(p.join(
        tmp.path,
        'fastlane',
        'metadata',
        'android',
        'en-US',
        'changelogs',
        '100037.txt',
      )).readAsStringSync();
      expect(changelog.trim(), 'Hand-written notes.');
    });

    test('refuses to overwrite an existing changelog without --force-changelog',
        () async {
      final Directory tmp = await _fixtureRepo(
        pubspecVersion: '0.1.0-alpha.36',
        pubspecCode: 100036,
        appInfoVersion: '0.1.0-alpha.36',
      );
      addTearDown(() async => tmp.delete(recursive: true));
      final File changelog = File(p.join(
        tmp.path,
        'fastlane',
        'metadata',
        'android',
        'en-US',
        'changelogs',
        '100037.txt',
      ));
      changelog.parent.createSync(recursive: true);
      changelog.writeAsStringSync('hand-edited content\n');

      final ProcessResult r = _runScript(
        script,
        '0.1.0-alpha.37',
        repoRoot: tmp.path,
        extraArgs: <String>['--changelog', 'overwrite please'],
      );
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('Changelog already exists'));
      expect(r.stderr, contains('--force-changelog'));
      // File must NOT be modified.
      expect(changelog.readAsStringSync(), 'hand-edited content\n');
    });

    test('--force-changelog overwrites an existing changelog', () async {
      final Directory tmp = await _fixtureRepo(
        pubspecVersion: '0.1.0-alpha.36',
        pubspecCode: 100036,
        appInfoVersion: '0.1.0-alpha.36',
      );
      addTearDown(() async => tmp.delete(recursive: true));
      final File changelog = File(p.join(
        tmp.path,
        'fastlane',
        'metadata',
        'android',
        'en-US',
        'changelogs',
        '100037.txt',
      ));
      changelog.parent.createSync(recursive: true);
      changelog.writeAsStringSync('old\n');

      final ProcessResult r = _runScript(
        script,
        '0.1.0-alpha.37',
        repoRoot: tmp.path,
        extraArgs: <String>['--changelog', 'new content', '--force-changelog'],
      );
      expect(r.exitCode, 0,
          reason: 'stdout:\n${r.stdout}\nstderr:\n${r.stderr}');
      expect(changelog.readAsStringSync().trim(), 'new content');
    });

    test('updates F-Droid CurrentVersion / CurrentVersionCode when present',
        () async {
      final Directory tmp = await _fixtureRepo(
        pubspecVersion: '0.1.0-alpha.36',
        pubspecCode: 100036,
        appInfoVersion: '0.1.0-alpha.36',
        fdroidBody: 'Name: Linthra\n'
            'CurrentVersion: 0.1.0-alpha.36\n'
            'CurrentVersionCode: 100036\n'
            'Builds:\n'
            '  - versionName: 0.1.0-alpha.30\n'
            '    versionCode: 100030\n',
      );
      addTearDown(() async => tmp.delete(recursive: true));

      final ProcessResult r =
          _runScript(script, '0.1.0-alpha.37', repoRoot: tmp.path);
      expect(r.exitCode, 0,
          reason: 'stdout:\n${r.stdout}\nstderr:\n${r.stderr}');
      final String after =
          File(p.join(tmp.path, 'metadata', 'io.github.thezupzup.linthra.yml'))
              .readAsStringSync();
      expect(after, contains('CurrentVersion: 0.1.0-alpha.37'));
      expect(after, contains('CurrentVersionCode: 100037'));
      // Builds block left untouched.
      expect(after, contains('versionName: 0.1.0-alpha.30'));
      expect(after, contains('versionCode: 100030'));
    });

    test('does nothing for F-Droid metadata when the file is absent', () async {
      final Directory tmp = await _fixtureRepo(
        pubspecVersion: '0.1.0-alpha.36',
        pubspecCode: 100036,
        appInfoVersion: '0.1.0-alpha.36',
      );
      addTearDown(() async => tmp.delete(recursive: true));
      final File fdroid =
          File(p.join(tmp.path, 'metadata', 'io.github.thezupzup.linthra.yml'));
      expect(fdroid.existsSync(), isFalse);

      final ProcessResult r =
          _runScript(script, '0.1.0-alpha.37', repoRoot: tmp.path);
      expect(r.exitCode, 0,
          reason: 'stdout:\n${r.stdout}\nstderr:\n${r.stderr}');
      expect(fdroid.existsSync(), isFalse);
    });
  });

  group('prepare_release_bump.py — input validation', () {
    test('rejects a leading v', () async {
      final Directory tmp = await _fixtureRepo(
        pubspecVersion: '0.1.0-alpha.36',
        pubspecCode: 100036,
        appInfoVersion: '0.1.0-alpha.36',
      );
      addTearDown(() async => tmp.delete(recursive: true));

      final ProcessResult r =
          _runScript(script, 'v0.1.0-alpha.37', repoRoot: tmp.path);
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('must not start with "v"'));
    });

    test('rejects a "+versionCode" suffix', () async {
      final Directory tmp = await _fixtureRepo(
        pubspecVersion: '0.1.0-alpha.36',
        pubspecCode: 100036,
        appInfoVersion: '0.1.0-alpha.36',
      );
      addTearDown(() async => tmp.delete(recursive: true));

      final ProcessResult r =
          _runScript(script, '0.1.0-alpha.37+100037', repoRoot: tmp.path);
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('"+versionCode"'));
    });

    test('rejects a malformed version', () async {
      final Directory tmp = await _fixtureRepo(
        pubspecVersion: '0.1.0-alpha.36',
        pubspecCode: 100036,
        appInfoVersion: '0.1.0-alpha.36',
      );
      addTearDown(() async => tmp.delete(recursive: true));

      final ProcessResult r = _runScript(script, '1.2', repoRoot: tmp.path);
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('Malformed release tag'));
    });

    test('rejects an unknown pre-release tier', () async {
      final Directory tmp = await _fixtureRepo(
        pubspecVersion: '0.1.0-alpha.36',
        pubspecCode: 100036,
        appInfoVersion: '0.1.0-alpha.36',
      );
      addTearDown(() async => tmp.delete(recursive: true));

      final ProcessResult r =
          _runScript(script, '1.2.3-preview.1', repoRoot: tmp.path);
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('Malformed release tag'));
    });

    test('rejects fields that overflow the encoding', () async {
      final Directory tmp = await _fixtureRepo(
        pubspecVersion: '0.1.0-alpha.36',
        pubspecCode: 100036,
        appInfoVersion: '0.1.0-alpha.36',
      );
      addTearDown(() async => tmp.delete(recursive: true));

      final ProcessResult r = _runScript(script, '0.100.0', repoRoot: tmp.path);
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('Minor version 100'));
    });
  });
}

ProcessResult _runScript(
  String script,
  String version, {
  required String repoRoot,
  List<String> extraArgs = const <String>[],
}) {
  return Process.runSync('python3', <String>[
    script,
    version,
    '--repo-root',
    repoRoot,
    ...extraArgs,
  ]);
}

/// Builds a temporary directory laid out like the Linthra repo, enough for the
/// script to walk: pubspec.yaml, lib/core/app_info.dart, and (optionally) the
/// F-Droid metadata file. Pre-existing Fastlane changelogs are NOT created so
/// each test starts from a clean slate.
Future<Directory> _fixtureRepo({
  String? pubspecVersion,
  int? pubspecCode,
  String? pubspecBody,
  String? appInfoVersion,
  String? appInfoBody,
  String? fdroidBody,
}) async {
  final Directory dir =
      await Directory.systemTemp.createTemp('prepare_release_bump_');
  Directory(p.join(dir.path, 'lib', 'core')).createSync(recursive: true);
  Directory(p.join(
    dir.path,
    'fastlane',
    'metadata',
    'android',
    'en-US',
    'changelogs',
  )).createSync(recursive: true);

  final String pubspec =
      pubspecBody ?? 'name: linthra\nversion: $pubspecVersion+$pubspecCode\n';
  File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync(pubspec);

  final String appInfo = appInfoBody ??
      'abstract final class AppInfo {\n'
          "  static const String _devVersionName = '$appInfoVersion';\n"
          '}\n';
  File(p.join(dir.path, 'lib', 'core', 'app_info.dart'))
      .writeAsStringSync(appInfo);

  if (fdroidBody != null) {
    Directory(p.join(dir.path, 'metadata')).createSync(recursive: true);
    File(p.join(dir.path, 'metadata', 'io.github.thezupzup.linthra.yml'))
        .writeAsStringSync(fdroidBody);
  }
  return dir;
}

String _findRepoRoot() {
  Directory d = Directory.current;
  while (true) {
    if (File(p.join(d.path, 'pubspec.yaml')).existsSync() &&
        Directory(p.join(d.path, 'scripts')).existsSync()) {
      return d.path;
    }
    final Directory parent = d.parent;
    if (parent.path == d.path) {
      fail('Could not find repo root from ${Directory.current.path}');
    }
    d = parent;
  }
}
