import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/app_info.dart';

/// Guards against version drift between the two places a version string lives:
/// `pubspec.yaml` (the single source of truth, which also drives Android's
/// `versionName`/`versionCode` via Flutter) and [AppInfo.version] (what the
/// Settings/About screen shows and what is sent to Jellyfin). Before this test
/// existed the app shipped `alpha.9` while still displaying `alpha.1`.
void main() {
  // `version: x.y.z(-suffix)(+buildNumber)` — capture the SemVer part only;
  // the `+versionCode` is Android-internal and intentionally not in AppInfo.
  final versionLine = RegExp(r'^version:\s*([^\s+]+)', multiLine: true);

  ({String name, int? code}) readPubspecVersion() {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match =
        RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml has no `version:` line');
    final raw = match!.group(1)!;
    final plus = raw.indexOf('+');
    final name = plus == -1 ? raw : raw.substring(0, plus);
    final code = plus == -1 ? null : int.tryParse(raw.substring(plus + 1));
    return (name: name, code: code);
  }

  test('AppInfo.version matches the versionName in pubspec.yaml', () {
    final pubspec = readPubspecVersion();
    expect(
      AppInfo.version,
      pubspec.name,
      reason: 'AppInfo.version (${AppInfo.version}) drifted from pubspec.yaml '
          '(${pubspec.name}). Bump both in the same commit — see '
          'docs/release-process.md §3.',
    );
  });

  test('pubspec.yaml carries an integer Android versionCode', () {
    final pubspec = readPubspecVersion();
    expect(
      pubspec.code,
      isNotNull,
      reason: 'pubspec.yaml `version:` must end in `+<versionCode>` so Android '
          'gets a monotonic build number.',
    );
    expect(pubspec.code, greaterThan(0));
  });

  test('AppInfo.version is a SemVer string without a build suffix', () {
    // No `+buildNumber` should leak into the user-facing version.
    expect(AppInfo.version, isNot(contains('+')));
    expect(versionLine.hasMatch('version: ${AppInfo.version}'), isTrue);
  });
}
