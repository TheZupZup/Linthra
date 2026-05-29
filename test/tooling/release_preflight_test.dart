import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../tool/version_from_tag.dart';

/// Specifies `scripts/release_preflight.sh` — the pure-bash twin of
/// `tool/version_from_tag.dart` that the GitHub release workflow runs against
/// every pushed tag (see docs/release-process.md §3 step 9 and
/// .github/workflows/android-release-build.yml).
///
/// The two encodings must agree forever, so this suite shells out to the
/// script for a corpus of tags and asserts the printed
/// `LINTHRA_VERSION_NAME` / `LINTHRA_VERSION_CODE` lines match what the Dart
/// encoder produces. It also exercises the mismatch and malformed-tag flows
/// the workflow relies on for "Version mismatch: release was not built."
void main() {
  final String repoRoot = _findRepoRoot();
  final String script = p.join(repoRoot, 'scripts', 'release_preflight.sh');

  setUpAll(() {
    if (!File(script).existsSync()) {
      fail('Preflight script not found at $script');
    }
  });

  group('release_preflight.sh — encoding matches version_from_tag.dart', () {
    // A representative slice of the corpus from version_from_tag_test.dart:
    // alpha (the user's two worked examples), beta, rc, and stable. If the
    // Dart encoding changes, this catches the drift immediately.
    const List<String> tags = <String>[
      'v0.1.0-alpha.32',
      'v0.1.0-alpha.36',
      'v0.1.0-beta.1',
      'v0.1.0-rc.1',
      'v0.1.0',
      'v1.2.3',
    ];

    for (final String tag in tags) {
      test('$tag → same versionName/versionCode as versionFromTag', () async {
        // We give the script a fixture pubspec/app-info that *matches* the
        // tag, so the encoding is the only thing under test.
        final TagVersion expected = versionFromTag(tag);
        final Directory tmp =
            await Directory.systemTemp.createTemp('preflight_ok_');
        addTearDown(() async => tmp.delete(recursive: true));
        _writePubspec(tmp, expected.name, expected.code);
        _writeAppInfo(tmp, expected.name);

        final ProcessResult r = _runPreflight(
          script,
          tag,
          pubspec: p.join(tmp.path, 'pubspec.yaml'),
          appInfo: p.join(tmp.path, 'app_info.dart'),
        );
        expect(r.exitCode, 0,
            reason:
                'expected success.\nstdout:\n${r.stdout}\nstderr:\n${r.stderr}');
        final Map<String, String> kv = _parseKeyValues(r.stdout as String);
        expect(kv['LINTHRA_VERSION_NAME'], expected.name);
        expect(kv['LINTHRA_VERSION_CODE'], '${expected.code}');
        expect(r.stdout, contains('OK: $tag matches pubspec.yaml version'));
      });
    }
  });

  group('release_preflight.sh — mismatch and malformed flows', () {
    test('exits non-zero and shows the exact-fix wording on pubspec drift',
        () async {
      final Directory tmp =
          await Directory.systemTemp.createTemp('preflight_drift_');
      addTearDown(() async => tmp.delete(recursive: true));
      // Tag the workflow used in the original failure: v0.1.0-alpha.35 was
      // pushed while pubspec.yaml still read 0.1.0-alpha.34+100034.
      _writePubspec(tmp, '0.1.0-alpha.34', 100034);

      final ProcessResult r = _runPreflight(
        script,
        'v0.1.0-alpha.35',
        pubspec: p.join(tmp.path, 'pubspec.yaml'),
        noAppInfo: true,
      );
      expect(r.exitCode, isNot(0));
      final String stderr = r.stderr as String;
      expect(
          stderr,
          contains(
              'Release tag v0.1.0-alpha.35 expects pubspec.yaml version 0.1.0-alpha.35+100035'));
      expect(stderr,
          contains('Actual pubspec.yaml version is 0.1.0-alpha.34+100034'));
      expect(stderr, contains('Do not move this tag.'));
      expect(
          stderr,
          contains(
              'Bump pubspec.yaml in a PR, merge it, then create the next release tag from main.'));
    });

    test('exits non-zero on a malformed tag with a usage hint', () async {
      final Directory tmp =
          await Directory.systemTemp.createTemp('preflight_bad_');
      addTearDown(() async => tmp.delete(recursive: true));
      _writePubspec(tmp, '0.1.0-alpha.36', 100036);

      final ProcessResult r = _runPreflight(
        script,
        'v1.2',
        pubspec: p.join(tmp.path, 'pubspec.yaml'),
        noAppInfo: true,
      );
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('Malformed release tag "v1.2"'));
      expect(r.stderr, contains('v0.1.0-alpha.36'));
    });

    test('rejects out-of-range fields the same way as versionFromTag',
        () async {
      final Directory tmp =
          await Directory.systemTemp.createTemp('preflight_oor_');
      addTearDown(() async => tmp.delete(recursive: true));
      _writePubspec(tmp, '0.1.0-alpha.36', 100036);

      final ProcessResult r = _runPreflight(
        script,
        'v0.100.0',
        pubspec: p.join(tmp.path, 'pubspec.yaml'),
        noAppInfo: true,
      );
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('Minor version 100'));
    });

    test('exits non-zero on AppInfo drift even if pubspec matches', () async {
      final Directory tmp =
          await Directory.systemTemp.createTemp('preflight_appinfo_');
      addTearDown(() async => tmp.delete(recursive: true));
      _writePubspec(tmp, '0.1.0-alpha.36', 100036);
      // app_info.dart says an older version — pubspec is fine, AppInfo drifted.
      _writeAppInfo(tmp, '0.1.0-alpha.35');

      final ProcessResult r = _runPreflight(
        script,
        'v0.1.0-alpha.36',
        pubspec: p.join(tmp.path, 'pubspec.yaml'),
        appInfo: p.join(tmp.path, 'app_info.dart'),
      );
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('AppInfo._devVersionName = 0.1.0-alpha.36'));
      expect(r.stderr,
          contains('Actual AppInfo._devVersionName is 0.1.0-alpha.35'));
    });

    test('--no-app-info skips the AppInfo check', () async {
      final Directory tmp =
          await Directory.systemTemp.createTemp('preflight_skipappinfo_');
      addTearDown(() async => tmp.delete(recursive: true));
      _writePubspec(tmp, '0.1.0-alpha.36', 100036);
      // No app_info.dart written; with --no-app-info the script must not care.

      final ProcessResult r = _runPreflight(
        script,
        'v0.1.0-alpha.36',
        pubspec: p.join(tmp.path, 'pubspec.yaml'),
        noAppInfo: true,
      );
      expect(r.exitCode, 0,
          reason: 'stdout:\n${r.stdout}\nstderr:\n${r.stderr}');
    });
  });

  group('release_preflight.sh — argument handling', () {
    test('rejects missing tag with usage hint', () async {
      final ProcessResult r = Process.runSync(script, <String>[]);
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('missing tag argument'));
      expect(r.stderr, contains('Usage:'));
    });

    test('--help prints usage and exits 0', () async {
      final ProcessResult r = Process.runSync(script, <String>['--help']);
      expect(r.exitCode, 0);
      expect(r.stdout, contains('Usage:'));
      expect(r.stdout, contains('--pubspec'));
      expect(r.stdout, contains('--app-info'));
    });
  });
}

ProcessResult _runPreflight(
  String script,
  String tag, {
  required String pubspec,
  String? appInfo,
  bool noAppInfo = false,
}) {
  final List<String> args = <String>[tag, '--pubspec', pubspec];
  if (noAppInfo) {
    args.add('--no-app-info');
  } else if (appInfo != null) {
    args.addAll(<String>['--app-info', appInfo]);
  }
  return Process.runSync(script, args);
}

Map<String, String> _parseKeyValues(String text) {
  final Map<String, String> out = <String, String>{};
  for (final String line in const LineSplitter().convert(text)) {
    final int eq = line.indexOf('=');
    if (eq <= 0) continue;
    final String key = line.substring(0, eq);
    if (!key.startsWith('LINTHRA_VERSION_')) continue;
    out[key] = line.substring(eq + 1);
  }
  return out;
}

void _writePubspec(Directory dir, String name, int code) {
  File(p.join(dir.path, 'pubspec.yaml'))
      .writeAsStringSync('name: linthra\nversion: $name+$code\n');
}

void _writeAppInfo(Directory dir, String name) {
  File(p.join(dir.path, 'app_info.dart')).writeAsStringSync(
    "abstract final class AppInfo {\n"
    "  static const String _devVersionName = '$name';\n"
    "}\n",
  );
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
