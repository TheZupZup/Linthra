import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/app_info.dart';
import 'package:linthra/core/diagnostics/app_diagnostics.dart';

import '../../tool/version_from_tag.dart';

/// Guards the version strategy described in docs/release-process.md §1:
///
/// * `pubspec.yaml`'s `version: <name>+<code>` is the single source of truth and
///   is kept in lockstep with the release tag. A plain `flutter build` — local,
///   CI release, and F-Droid alike — takes the version from there.
/// * [AppInfo.version] mirrors `pubspec.yaml`'s `versionName` via a `const`
///   ([AppInfo] reads no override in tests, since `flutter test` passes no
///   dart-define), and the `+versionCode` must be the canonical encoding of that
///   name (tool/version_from_tag.dart), so the tag, `pubspec.yaml`, and the
///   F-Droid build can never disagree.
///
/// Before this guard existed the app shipped `alpha.9` while still displaying
/// `alpha.1`; the drift tests keep the in-app version and the encoded
/// versionCode honest against `pubspec.yaml`.
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
        reason: 'pubspec.yaml `version:` must end in `+<versionCode>` so '
            'Android builds get a monotonic build number.',
      );
      expect(pubspec.code, greaterThan(0));
    });

    test('versionCode is the canonical encoding of the versionName', () {
      // pubspec.yaml is now in lockstep with the release tag, so its
      // versionCode must be exactly what tool/version_from_tag.dart encodes for
      // the versionName. This keeps the tag, pubspec.yaml, and the F-Droid build
      // (which reads versionName/versionCode straight from pubspec.yaml) in
      // agreement — see docs/release-process.md §1 & §3.
      final ({String name, int? code}) pubspec = readPubspecVersion();
      expect(
        pubspec.code,
        versionFromTag(pubspec.name).code,
        reason:
            'pubspec.yaml versionCode (${pubspec.code}) is not the canonical '
            'encoding of its versionName (${pubspec.name}); '
            'tool/version_from_tag.dart encodes that as '
            '${versionFromTag(pubspec.name).code}. Use that exact value so the '
            'tag, pubspec.yaml, and F-Droid agree. Preview it with '
            '`dart run tool/version_from_tag.dart ${pubspec.name}`.',
      );
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

  group('AppInfo.releaseChannel', () {
    test('a stable versionName (no suffix) reads "Stable"', () {
      expect(AppInfo.channelForVersion('0.1.8'), 'Stable');
      expect(AppInfo.channelForVersion('1.2.3'), 'Stable');
    });

    test('a pre-release versionName reads its tier', () {
      expect(AppInfo.channelForVersion('0.1.8-alpha.2'), 'Alpha');
      expect(AppInfo.channelForVersion('0.1.8-beta.1'), 'Beta');
      expect(AppInfo.channelForVersion('0.1.8-rc.1'), 'Release candidate');
    });

    test('the shipped 0.1.8 build resolves to a stable channel', () {
      // 0.1.8 is cut as a stable release, so Settings → About must read
      // "Stable" — not the old hardcoded "Alpha". This is intentionally coupled
      // to pubspec.yaml's version (like the drift tests above); cutting a
      // pre-release here would flip it to that tier.
      expect(AppInfo.releaseChannel, 'Stable');
      expect(
        AppInfo.releaseChannel,
        AppInfo.channelForVersion(AppInfo.version),
      );
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
