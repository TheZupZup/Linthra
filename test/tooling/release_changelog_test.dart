import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Release guardrail: the Fastlane changelog for the *current* release version
/// must exist and be non-empty.
///
/// F-Droid names each changelog file by its Android `versionCode`
/// (`fastlane/metadata/android/en-US/changelogs/<code>.txt`) and shows it as the
/// release's "What's New". The `Prepare release bump` workflow / its local twin
/// `scripts/prepare_release_bump.py` always create this file, so the only way to
/// reach `main` without it is a hand-edited bump that forgot it — exactly what
/// this test catches, on every PR, before a tag is ever cut.
///
/// It reads `pubspec.yaml` (the single source of truth for `<name>+<code>`; see
/// docs/release-process.md §1) and only checks that the matching changelog
/// exists — it does not assert anything about the body, so refining the wording
/// in a PR stays friction-free. Sibling coverage:
/// test/core/app_info_version_test.dart pins that the `versionCode` is the
/// canonical encoding of the `versionName`; test/tooling/prepare_release_bump_test.dart
/// pins how the bump script writes the changelog.
void main() {
  final String root = _repoRoot();

  test('a Fastlane changelog exists for the current pubspec versionCode', () {
    final int code = _pubspecVersionCode(p.join(root, 'pubspec.yaml'));
    final File changelog = File(p.join(
      root,
      'fastlane',
      'metadata',
      'android',
      'en-US',
      'changelogs',
      '$code.txt',
    ));

    expect(
      changelog.existsSync(),
      isTrue,
      reason: 'No Fastlane changelog for the current release versionCode '
          '($code). Add fastlane/metadata/android/en-US/changelogs/$code.txt — '
          'the `Prepare release bump` workflow / scripts/prepare_release_bump.py '
          'do this automatically. See docs/release-process.md §3.',
    );
    expect(
      changelog.readAsStringSync().trim(),
      isNotEmpty,
      reason: 'fastlane/metadata/android/en-US/changelogs/$code.txt is empty; '
          'F-Droid shows this as the release "What\'s New". Add a short, '
          'factual note.',
    );
  });
}

/// Reads `pubspec.yaml`'s `version: <name>+<code>` and returns `<code>`.
int _pubspecVersionCode(String pubspecPath) {
  final String text = File(pubspecPath).readAsStringSync();
  final RegExpMatch? match =
      RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(text);
  if (match == null) {
    fail('pubspec.yaml has no `version:` line');
  }
  final String raw = match.group(1)!;
  final int plus = raw.indexOf('+');
  if (plus < 0) {
    fail('pubspec.yaml version "$raw" must be `<versionName>+<versionCode>`.');
  }
  final int? code = int.tryParse(raw.substring(plus + 1));
  if (code == null) {
    fail('pubspec.yaml versionCode in "$raw" is not an integer.');
  }
  return code;
}

/// Walks up from the current directory to the repo root (the directory that has
/// both `pubspec.yaml` and the `fastlane/` metadata tree).
String _repoRoot() {
  Directory d = Directory.current;
  while (true) {
    if (File(p.join(d.path, 'pubspec.yaml')).existsSync() &&
        Directory(p.join(d.path, 'fastlane')).existsSync()) {
      return d.path;
    }
    final Directory parent = d.parent;
    if (parent.path == d.path) {
      fail('Could not find repo root from ${Directory.current.path}');
    }
    d = parent;
  }
}
