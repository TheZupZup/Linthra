/// Static, build-time app metadata.
abstract final class AppInfo {
  static const String name = 'Linthra';
  static const String tagline = 'Your music, beautifully yours.';

  /// App `versionName`, mirroring the `x.y.z(-suffix)` part of `pubspec.yaml`'s
  /// `version` (the `+versionCode` is Android-only and not shown here). Used for
  /// the Settings/About display and sent (informationally) to Jellyfin as the
  /// client version in the auth header so the server can label this device.
  ///
  /// `pubspec.yaml` is the single source of truth; this constant must match it.
  /// `test/core/app_info_version_test.dart` fails CI if the two ever drift, so
  /// bump both in the same commit (see docs/release-process.md §3).
  static const String version = '0.1.0-alpha.9';
}
