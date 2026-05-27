import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/app_info.dart';
import 'package:linthra/core/diagnostics/app_diagnostics.dart';

/// Guards the version strategy described in docs/release-process.md §1:
///
/// * On a **tagged release build**, the version comes from the Git tag, injected
///   via `--dart-define=LINTHRA_VERSION_NAME=...` (see tool/version_from_tag.dart),
///   so the in-app version always matches the released APK/AAB.
/// * On **local/dev and CI-test builds** (no dart-define), [AppInfo.version]
///   falls back to a `const` mirror of `pubspec.yaml`'s `versionName`. This is
///   the value the suite below sees, since `flutter test` passes no dart-define.
///
/// Before this guard existed the app shipped `alpha.9` while still displaying
/// `alpha.1`; the drift test keeps the dev fallback honest against pubspec.
void main() {
  // `version: x.y.z(-suffix)(+buildNumber)` — capture the SemVer part only;
  // the `+versionCode` is Android-internal and intentionally not in AppInfo.
  final RegExp versionLine = RegExp(r'^version:\s*([^\s+]+)', multiLine: true);

  ({String name, int? code}) readPubspecVersion() {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final RegExpMatch? match =
        RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml has no `version:` line');
    final String raw = match!.group(1)!;
    final int plus = raw.indexOf('+');
    final String name = plus == -1 ? raw : raw.substring(0, plus);
    final int? code = plus == -1 ? null : int.tryParse(raw.substring(plus + 1));
    return (name: name, code: code);
  }

  group('AppInfo.version dev fallback', () {
    test('matches the versionName in pubspec.yaml (no dart-define in tests)',
        () {
      final ({String name, int? code}) pubspec = readPubspecVersion();
      expect(
        AppInfo.version,
        pubspec.name,
        reason: 'AppInfo.version (${AppInfo.version}) drifted from '
            'pubspec.yaml (${pubspec.name}). Bump both in the same commit — '
            'see docs/release-process.md §1.',
      );
    });

    test('pubspec.yaml carries an integer Android versionCode', () {
      final ({String name, int? code}) pubspec = readPubspecVersion();
      expect(
        pubspec.code,
        isNotNull,
        reason: 'pubspec.yaml `version:` must end in `+<versionCode>` so local '
            'Android builds get a monotonic build number.',
      );
      expect(pubspec.code, greaterThan(0));
    });

    test('is a SemVer string without a build suffix', () {
      // No `+buildNumber` should leak into the user-facing version.
      expect(AppInfo.version, isNot(contains('+')));
      expect(versionLine.hasMatch('version: ${AppInfo.version}'), isTrue);
    });
  });

  group('AppInfo.resolveVersion', () {
    test('prefers the release-injected version when present', () {
      expect(
        AppInfo.resolveVersion('0.1.0-alpha.16', '0.1.0-alpha.15'),
        '0.1.0-alpha.16',
      );
    });

    test('falls back to the dev version when no override is supplied', () {
      expect(AppInfo.resolveVersion('', '0.1.0-alpha.15'), '0.1.0-alpha.15');
    });
  });

  test('diagnostics report carries the effective app version', () {
    // Settings ▸ Diagnostics and "Report a bug" both render the version through
    // AppDiagnostics.report(appVersion: AppInfo.version); confirm the effective
    // version flows into that output.
    final String report =
        AppDiagnostics.report(AppDiagnosticsData(appVersion: AppInfo.version));
    expect(report, contains('App version: ${AppInfo.version}'));
  });
}
