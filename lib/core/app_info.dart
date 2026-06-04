/// Static, build-time app metadata.
abstract final class AppInfo {
  static const String name = 'Linthra';
  static const String tagline = 'Your music, beautifully yours.';

  /// The `versionName` shown in-app, mirroring the `x.y.z(-suffix)` part of
  /// `pubspec.yaml`'s `version` (the `+versionCode` is Android-only and not
  /// shown here).
  ///
  /// `pubspec.yaml` is the single source of truth for the version and is kept in
  /// lockstep with the release tag (see docs/release-process.md §1), so this
  /// constant must match its `versionName`. A plain `flutter build` — local, CI
  /// release, and F-Droid alike — supplies the version from `pubspec.yaml`, so
  /// the in-app version always matches the released APK/AAB without any
  /// build-time injection. `test/core/app_info_version_test.dart` fails CI if
  /// this constant ever drifts from `pubspec.yaml`, so bump both together.
  static const String _devVersionName = '0.1.0-alpha.40';

  /// Optional build-time override for the in-app `versionName`, read from
  /// `--dart-define=LINTHRA_VERSION_NAME=...`. Normally **empty** — `pubspec.yaml`
  /// (mirrored by [_devVersionName]) is the source of truth and supplies the
  /// version for every standard build. Retained as an escape hatch so a one-off
  /// build can stamp a different in-app version without editing `pubspec.yaml`;
  /// when empty, [version] falls back to [_devVersionName].
  static const String _definedVersionName =
      String.fromEnvironment('LINTHRA_VERSION_NAME');

  /// The effective app `versionName` shown in Settings/About, embedded in the
  /// diagnostics / "Report a bug" output, and sent to Jellyfin as the client
  /// version. Uses the optional override when present, else the `pubspec.yaml`
  /// value — the same value Android's build metadata carries.
  static String get version =>
      resolveVersion(_definedVersionName, _devVersionName);

  /// Pure selection rule behind [version]: prefer the release-injected
  /// [defined] value, falling back to [devFallback] when it is empty (no
  /// dart-define). Exposed so the override/fallback behavior is unit-testable
  /// without recompiling the suite with a dart-define.
  static String resolveVersion(String defined, String devFallback) =>
      defined.isEmpty ? devFallback : defined;
}
